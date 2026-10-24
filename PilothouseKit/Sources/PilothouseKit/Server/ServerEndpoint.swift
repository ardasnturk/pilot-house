import Foundation

/// Accepts raw transports, runs the responder handshake and serves each
/// authenticated phone with a `ServerConnection`.
///
/// Used by the Mac's WebSocket listener and by the in-process demo server.
public actor ServerEndpoint {
    private let identity: IdentityKeyPair
    private let macName: @Sendable () -> String
    private let authorizer: any PeerAuthorizer
    private let service: any HostService
    private let log = PilothouseLog("ServerEndpoint")
    private var connections: [ObjectIdentifier: ServerConnection] = [:]

    public init(
        identity: IdentityKeyPair,
        macName: @escaping @Sendable () -> String,
        authorizer: any PeerAuthorizer,
        service: any HostService
    ) {
        self.identity = identity
        self.macName = macName
        self.authorizer = authorizer
        self.service = service
    }

    /// Handles one incoming transport until it disconnects.
    public func accept(_ transport: any MessageTransport) async {
        let authorizer = self.authorizer
        let peer: AuthenticatedPeer
        do {
            peer = try await SecureHandshake.respond(
                over: transport,
                identity: identity,
                macName: macName()
            ) { publicKey, hello in
                await authorizer.authorize(publicKey: publicKey, hello: hello)
            }
        } catch {
            log.info("Handshake with \(transport.peerDescription) failed: \(error)")
            return
        }

        let connection = ServerConnection(peer: peer, service: service)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        await authorizer.peerConnected(deviceId: peer.deviceId, hello: peer.hello)
        log.info("\(peer.hello.deviceName) connected from \(transport.peerDescription)")
        await connection.run()
        connections.removeValue(forKey: key)
        await authorizer.peerDisconnected(deviceId: peer.deviceId)
    }

    /// Number of currently connected phones.
    public var connectionCount: Int { connections.count }

    /// Device IDs with at least one open connection.
    public var connectedDeviceIds: Set<String> {
        Set(connections.values.map(\.client.deviceId))
    }

    /// Immediately drops every connection of `deviceId` (used after revocation).
    public func disconnect(deviceId: String, reason: ErrorPayload) async {
        for connection in connections.values where connection.client.deviceId == deviceId {
            await connection.close(reason: reason)
        }
    }

    /// Closes every connection (app shutdown).
    public func disconnectAll(reason: ErrorPayload? = nil) async {
        for connection in connections.values {
            await connection.close(reason: reason)
        }
    }
}
