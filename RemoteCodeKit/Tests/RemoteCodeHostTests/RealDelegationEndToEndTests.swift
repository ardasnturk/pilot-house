import Foundation
import RemoteCodeKit
import Testing
@testable import RemoteCodeHost

/// Real Claude Code delegating to real Codex through `delegate_to_agent`, with
/// every approval answered by the "phone".
///
///     REMOTECODE_E2E_CLAUDE=$(command -v claude) REMOTECODE_E2E_CODEX=$(command -v codex) \
///       swift test --filter RealDelegationEndToEndTests
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["REMOTECODE_E2E_CLAUDE"] != nil
        && ProcessInfo.processInfo.environment["REMOTECODE_E2E_CODEX"] != nil),
    .timeLimit(.minutes(8))
)
struct RealDelegationEndToEndTests {
    @Test func claudeHandsATaskToCodex() async throws {
        let environment = ProcessInfo.processInfo.environment
        let claude = try #require(environment["REMOTECODE_E2E_CLAUDE"])
        let codex = try #require(environment["REMOTECODE_E2E_CODEX"])
        let home = try TemporaryHome()
        defer { home.remove() }
        let project = try home.makeDirectory("project")

        let runtime = try HostRuntime(
            configuration: HostConfiguration(
                homeDirectory: home.path,
                dataDirectory: home.url.appendingPathComponent("Library/Pilothouse"),
                delegationAgents: [.codex]
            ),
            identity: .generate(),
            serverVersion: "e2e",
            status: TestStatusProvider(),
            macName: { "E2E Mac" },
            agentLauncher: { kind in
                switch kind {
                case .claude: CLIClaudeLauncher(executable: claude, environment: environment, apiKey: nil)
                case .codex: CodexLauncher(executable: codex, environment: environment)
                default: throw ErrorPayload(code: .agentNotInstalled, message: "not installed")
                }
            }
        )
        await runtime.start()

        let connector = RealClaudeEndToEndTests.LoopbackConnector(endpoint: runtime.endpoint)
        let phone = IdentityKeyPair.generate()
        let device = DeviceInfo(name: "E2E iPhone", platform: "iOS", appVersion: "1.0")
        let payload = await runtime.makePairingPayload(macName: "E2E Mac", localAddresses: ["127.0.0.1"], tailscale: .notInstalled, port: 47823)
        let mac = try await MacClient.pair(payload: payload, identity: phone, device: device, connector: connector)
        let client = MacClient(mac: mac, identity: phone, device: device, connector: connector)
        await client.start()
        for await state in client.states where state.isConnected { break }
        let pushes = client.pushes

        guard case .sessionStarted(let started) = try await client.request(
            .startSession(StartSession(cwd: "~/project", model: environment["REMOTECODE_E2E_MODEL"] ?? "sonnet")),
            timeout: 60
        ) else {
            Issue.record("Expected sessionStarted")
            return
        }
        let sessionId = started.session.id
        _ = try await client.request(.subscribe(Subscribe(sessionId: sessionId, fromSeq: 1)))
        _ = try await client.request(.sendMessage(SendMessage(
            sessionId: sessionId,
            text: "Use the delegate_to_agent tool with agent codex. Ask Codex to create a file named codex.txt containing exactly: written by codex. Do not create the file yourself. Afterwards tell me in one sentence what Codex reported."
        )), timeout: 60)

        var approved: [String] = []
        var threadEvents: [EventPayload] = []
        var mainResult: SessionEvent.TurnResult?
        for await message in pushes {
            switch message {
            case .permissionRequest(let request) where request.sessionId == sessionId:
                approved.append(request.tool)
                _ = try await client.request(.permissionResponse(PermissionResponse(requestId: request.id, allow: true)))
            case .event(let payload) where payload.sessionId == sessionId && payload.ephemeral != true:
                if payload.thread != nil {
                    threadEvents.append(payload)
                } else if case .result(let turn) = payload.payload {
                    mainResult = turn
                }
            default:
                break
            }
            if mainResult != nil { break }
        }

        #expect(approved.contains(ClaudeCommand.delegationToolFullName))
        #expect(approved.contains("Bash") || approved.contains("Edit"), "Codex's own actions are approved on the phone too")
        let contents = try String(contentsOf: project.appendingPathComponent("codex.txt"), encoding: .utf8)
        #expect(contents.contains("written by codex"))
        #expect(!threadEvents.isEmpty)
        #expect(Set(threadEvents.compactMap(\.thread)).count == 1)
        #expect(threadEvents.contains { if case .assistantMessage = $0.payload { true } else { false } })
        #expect(mainResult?.isError == false)

        await client.stop()
        await runtime.shutdown()
    }
}
