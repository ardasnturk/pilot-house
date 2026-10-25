import Foundation
import RemoteCodeKit
import Testing
@testable import RemoteCodeHost

/// End-to-end test against the **real** Claude Code CLI (prompt §8):
/// phone client → encrypted channel → Mac host → `claude` → permission prompt
/// over MCP → approved on the "phone" → `hello.txt` is created.
///
/// Opt-in because it needs a signed-in CLI and makes a (small) model call:
///
///     REMOTECODE_E2E_CLAUDE=$(command -v claude) swift test --filter RealClaudeEndToEndTests
///
/// `REMOTECODE_E2E_MODEL` overrides the model (default `haiku`).
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["REMOTECODE_E2E_CLAUDE"] != nil),
    .timeLimit(.minutes(5))
)
struct RealClaudeEndToEndTests {
    struct LoopbackConnector: TransportConnector {
        let endpoint: ServerEndpoint
        func connect(to endpoint: Endpoint, timeout: Double) async throws -> any MessageTransport {
            let (client, server) = InMemoryTransport.makePair()
            let serverEndpoint = self.endpoint
            Task { await serverEndpoint.accept(server) }
            return client
        }
    }

    @Test func createHelloTxtWithApprovalFromThePhone() async throws {
        let environment = ProcessInfo.processInfo.environment
        let claude = try #require(environment["REMOTECODE_E2E_CLAUDE"])
        let model = environment["REMOTECODE_E2E_MODEL"] ?? "haiku"
        let home = try TemporaryHome()
        defer { home.remove() }
        let project = try home.makeDirectory("project")

        let runtime = try HostRuntime(
            configuration: HostConfiguration(
                homeDirectory: home.path,
                dataDirectory: home.url.appendingPathComponent("Library/Pilothouse")
            ),
            identity: .generate(),
            serverVersion: "e2e",
            status: TestStatusProvider(),
            macName: { "E2E Mac" },
            launcher: { CLIClaudeLauncher(executable: claude, environment: environment, apiKey: nil) }
        )
        await runtime.start()

        // Pair a phone and connect, exactly like the iOS app.
        let connector = LoopbackConnector(endpoint: runtime.endpoint)
        let phone = IdentityKeyPair.generate()
        let device = DeviceInfo(name: "E2E iPhone", platform: "iOS", appVersion: "1.0")
        let payload = await runtime.makePairingPayload(macName: "E2E Mac", localAddresses: ["127.0.0.1"], tailscale: .notInstalled, port: 47823)
        let mac = try await MacClient.pair(payload: payload, identity: phone, device: device, connector: connector)
        let client = MacClient(mac: mac, identity: phone, device: device, connector: connector)
        await client.start()
        for await state in client.states where state.isConnected { break }
        let pushes = client.pushes

        guard case .sessionStarted(let started) = try await client.request(
            .startSession(StartSession(cwd: "~/project", model: model, permissionMode: .default)),
            timeout: 60
        ) else {
            Issue.record("Expected sessionStarted")
            return
        }
        let sessionId = started.session.id
        _ = try await client.request(.subscribe(Subscribe(sessionId: sessionId, fromSeq: 1)))
        _ = try await client.request(.sendMessage(SendMessage(
            sessionId: sessionId,
            text: "Create a file named hello.txt in the current folder whose entire content is: Hello from Remote Code. Use the Write tool, do not run any shell commands. Then reply with one short sentence."
        )), timeout: 60)

        var approvedTools: [String] = []
        var events: [SessionEvent] = []
        var result: SessionEvent.TurnResult?
        for await message in pushes {
            switch message {
            case .permissionRequest(let request) where request.sessionId == sessionId:
                approvedTools.append(request.tool)
                _ = try await client.request(.permissionResponse(PermissionResponse(requestId: request.id, allow: true)))
            case .event(let payload) where payload.sessionId == sessionId && payload.ephemeral != true:
                events.append(payload.payload)
                if case .result(let turn) = payload.payload { result = turn }
            default:
                break
            }
            if result != nil { break }
        }

        let file = project.appendingPathComponent("hello.txt")
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents.contains("Hello from Remote Code"))
        #expect(approvedTools.contains("Write"))
        #expect(result?.isError == false)
        #expect(events.contains { if case .sessionInfo = $0 { true } else { false } })
        #expect(events.contains { if case .toolUse(let use) = $0 { use.name == "Write" } else { false } })
        #expect(events.contains { if case .fileEdit(let edit) = $0 { edit.path.hasSuffix("hello.txt") } else { false } })
        #expect(events.contains { if case .permissionDecision(let decision) = $0 { decision.outcome == .allowed } else { false } })
        #expect(events.contains { if case .assistantMessage = $0 { true } else { false } })

        // The conversation survives an interrupt-free restart: resume and ask a follow-up.
        _ = try await client.request(.closeSession(SessionRef(sessionId: sessionId)))
        _ = try await client.request(.resumeSession(SessionRef(sessionId: sessionId)), timeout: 60)
        _ = try await client.request(.sendMessage(SendMessage(
            sessionId: sessionId,
            text: "Without using any tools: what is the exact name of the file you just created? Answer with the file name only."
        )), timeout: 60)
        var followUp = ""
        for await message in pushes {
            if case .event(let payload) = message, payload.sessionId == sessionId {
                if case .assistantMessage(let text) = payload.payload { followUp += text.text }
                if case .result = payload.payload { break }
                if case .systemNotice(let notice) = payload.payload, notice.level == .error {
                    Issue.record("CLI reported: \(notice.text)")
                    break
                }
            }
            if case .permissionRequest(let request) = message {
                _ = try await client.request(.permissionResponse(PermissionResponse(requestId: request.id, allow: false)))
            }
        }
        #expect(followUp.contains("hello.txt"))

        await client.stop()
        await runtime.shutdown()
    }
}
