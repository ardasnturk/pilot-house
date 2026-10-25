import Foundation

/// Serves one authenticated phone: decodes requests, calls the `HostService`,
/// streams subscribed session events and forwards host notifications.
public actor ServerConnection {
    /// Messages whose `ts` is further than this from the Mac's clock are dropped.
    public static let maximumMessageAge: TimeInterval = 600

    public nonisolated let client: ClientContext
    private let channel: SecureChannel
    private let service: any HostService
    private let log = RemoteCodeLog("ServerConnection")
    private var subscriptions: [String: Task<Void, Never>] = [:]
    private var notificationTask: Task<Void, Never>?
    private var didHello = false
    private var isClosed = false

    public init(peer: AuthenticatedPeer, service: any HostService) {
        channel = peer.channel
        self.service = service
        client = ClientContext(
            deviceId: peer.deviceId,
            deviceName: peer.hello.deviceName,
            platform: peer.hello.platform,
            appVersion: peer.hello.appVersion
        )
    }

    /// Processes messages until the connection ends.
    public func run() async {
        defer { cleanUp() }
        while !isClosed {
            let data: Data
            do {
                data = try await channel.receive()
            } catch {
                log.info("Connection to \(client.deviceName) ended: \(error)")
                break
            }
            await handle(data)
        }
        await channel.close()
    }

    /// Sends a final error (if any) and closes the connection.
    public func close(reason: ErrorPayload? = nil) async {
        guard !isClosed else { return }
        if let reason { send(.error(reason)) }
        isClosed = true
        cleanUp()
        await channel.close()
    }

    // MARK: Request handling

    private func handle(_ data: Data) async {
        let envelope: ClientEnvelope
        do {
            envelope = try RemoteCodeJSON.decode(ClientEnvelope.self, from: data)
        } catch let error as ProtocolError {
            let code: ErrorCode = if case .unsupportedVersion = error { .protocolMismatch } else { .unknownMessage }
            send(.error(ErrorPayload(code: code, message: error.description)), re: EnvelopeInspector.messageId(of: data))
            return
        } catch {
            send(
                .error(ErrorPayload(code: .invalidRequest, message: "Could not decode message: \(error)")),
                re: EnvelopeInspector.messageId(of: data)
            )
            return
        }

        guard abs(envelope.ts.timeIntervalSinceNow) <= Self.maximumMessageAge else {
            send(.error(ErrorPayload(code: .clockSkew, message: "Message timestamp is outside the accepted window.")), re: envelope.id)
            return
        }

        if case .hello(let hello) = envelope.message {
            await handleHello(hello, id: envelope.id)
            return
        }
        guard didHello else {
            send(.error(ErrorPayload(code: .invalidRequest, message: "Send hello first.")), re: envelope.id)
            return
        }

        do {
            let response = try await respond(to: envelope.message)
            if let response { send(response, re: envelope.id) }
        } catch let error as ErrorPayload {
            send(.error(error), re: envelope.id)
        } catch {
            send(.error(ErrorPayload(code: .internalError, message: String(describing: error))), re: envelope.id)
        }
    }

    private func handleHello(_ hello: Hello, id: String) async {
        guard hello.protocolVersion == RemoteCodeProtocol.version else {
            send(
                .error(ErrorPayload(
                    code: .protocolMismatch,
                    message: "The Mac speaks protocol version \(RemoteCodeProtocol.version) but this app speaks \(hello.protocolVersion). Please update."
                )),
                re: id
            )
            return
        }
        didHello = true
        let ack = await service.helloAck(for: client)
        send(.helloAck(ack), re: id)
        startNotifications()
    }

    /// Returns the response message, or `nil` when the request answers itself.
    private func respond(to message: ClientMessage) async throws -> ServerMessage? {
        switch message {
        case .hello:
            return nil
        case .macStatus:
            return .macStatus(await service.macStatus())
        case .listDirectory(let request):
            return .directoryListing(try await service.listDirectory(request))
        case .createDirectory(let request):
            return .directoryListing(try await service.createDirectory(request))
        case .getWeeklySummary(let request):
            return .weeklySummary(try await service.weeklySummary(request))
        case .getUsageLimits:
            return .usageLimits(UsageLimitsPayload(agents: await service.usageLimits()))
        case .listCommands(let ref):
            return .commandCatalog(CommandCatalog(commands: try await service.listCommands(sessionId: ref.sessionId)))
        case .listSessions:
            return .sessionList(SessionList(sessions: await service.listSessions()))
        case .startSession(let request):
            return .sessionStarted(SessionPayload(session: try await service.startSession(request, from: client)))
        case .resumeSession(let ref):
            return .sessionStarted(SessionPayload(session: try await service.resumeSession(id: ref.sessionId)))
        case .updateSessionSettings(let request):
            return .sessionUpdated(SessionPayload(session: try await service.updateSessionSettings(request)))
        case .sendMessage(let request):
            try await service.sendMessage(request, from: client)
            return .ok
        case .interrupt(let ref):
            try await service.interrupt(sessionId: ref.sessionId)
            return .ok
        case .closeSession(let ref):
            try await service.closeSession(id: ref.sessionId)
            return .ok
        case .deleteSession(let ref):
            subscriptions.removeValue(forKey: ref.sessionId)?.cancel()
            try await service.deleteSession(id: ref.sessionId)
            return .ok
        case .subscribe(let request):
            let stream = try await service.subscribe(sessionId: request.sessionId, fromSeq: max(1, request.fromSeq))
            startSubscription(sessionId: request.sessionId, stream: stream)
            return .ok
        case .unsubscribe(let ref):
            subscriptions.removeValue(forKey: ref.sessionId)?.cancel()
            return .ok
        case .permissionResponse(let response):
            try await service.respondToPermission(response, from: client)
            return .ok
        }
    }

    // MARK: Streams

    private func startSubscription(sessionId: String, stream: AsyncStream<SequencedEvent>) {
        subscriptions.removeValue(forKey: sessionId)?.cancel()
        subscriptions[sessionId] = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.send(.event(EventPayload(sessionId: sessionId, event: event)))
            }
        }
    }

    private func startNotifications() {
        guard notificationTask == nil else { return }
        let service = self.service
        notificationTask = Task { [weak self] in
            let stream = await service.notifications()
            for await notification in stream {
                guard let self else { return }
                await self.forward(notification)
            }
        }
    }

    private func forward(_ notification: HostNotification) async {
        switch notification {
        case .sessionStarted(let session): send(.sessionStarted(SessionPayload(session: session)))
        case .sessionUpdated(let session): send(.sessionUpdated(SessionPayload(session: session)))
        case .sessionDeleted(let id): send(.sessionDeleted(SessionRef(sessionId: id)))
        case .sessionEnded(let ended): send(.sessionEnded(ended))
        case .permissionRequest(let request): send(.permissionRequest(request))
        case .permissionResolved(let resolved): send(.permissionResolved(resolved))
        case .macStatus(let status): send(.macStatus(status))
        case .disconnectDevice(let deviceId, let reason):
            if deviceId == client.deviceId { await close(reason: reason) }
        }
    }

    // MARK: Sending

    private func send(_ message: ServerMessage, re: String? = nil) {
        guard !isClosed else { return }
        do {
            let data = try RemoteCodeJSON.encode(ServerEnvelope(re: re, message: message))
            try channel.send(data)
        } catch {
            log.error("Failed to send \(message.typeName): \(error)")
        }
    }

    private func cleanUp() {
        notificationTask?.cancel()
        notificationTask = nil
        for task in subscriptions.values { task.cancel() }
        subscriptions.removeAll()
    }
}
