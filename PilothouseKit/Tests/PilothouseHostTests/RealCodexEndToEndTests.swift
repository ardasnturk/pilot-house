import Foundation
import PilothouseKit
import Testing
@testable import PilothouseHost

/// End-to-end test against the **real** Codex CLI: phone client → encrypted
/// channel → Mac host → `codex app-server` → approval request over JSON-RPC →
/// approved on the "phone" → `hello.txt` is created → close + resume.
///
/// Opt-in because it needs a signed-in CLI and makes (small) model calls:
///
///     PILOTHOUSE_E2E_CODEX=$(command -v codex) swift test --filter RealCodexEndToEndTests
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["PILOTHOUSE_E2E_CODEX"] != nil),
    .timeLimit(.minutes(6))
)
struct RealCodexEndToEndTests {
    @Test func createHelloTxtWithApprovalFromThePhone() async throws {
        let environment = ProcessInfo.processInfo.environment
        let codex = try #require(environment["PILOTHOUSE_E2E_CODEX"])
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
            agentLauncher: { kind in
                guard kind == .codex else { throw ErrorPayload(code: .agentNotInstalled, message: "codex only") }
                return CodexLauncher(executable: codex, environment: environment)
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
            .startSession(StartSession(cwd: "~/project", permissionMode: .default, agent: .codex)),
            timeout: 60
        ) else {
            Issue.record("Expected sessionStarted")
            return
        }
        let sessionId = started.session.id
        #expect(started.session.agent == .codex)
        _ = try await client.request(.subscribe(Subscribe(sessionId: sessionId, fromSeq: 1)))
        _ = try await client.request(.sendMessage(SendMessage(
            sessionId: sessionId,
            text: "Create a file named hello.txt in the current folder whose entire content is: Hello from Remote Code. Then reply with one short sentence."
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
                if case .systemNotice(let notice) = payload.payload, notice.level == .error {
                    Issue.record("Codex reported: \(notice.text)")
                }
            default:
                break
            }
            if result != nil { break }
        }

        let contents = try String(contentsOf: project.appendingPathComponent("hello.txt"), encoding: .utf8)
        #expect(contents.contains("Hello from Remote Code"))
        #expect(!approvedTools.isEmpty, "Codex should have asked before writing in read-only mode")
        #expect(result?.isError == false)
        #expect(events.contains { if case .sessionInfo = $0 { true } else { false } })
        #expect(events.contains { if case .permissionDecision(let decision) = $0 { decision.outcome == .allowed } else { false } })
        #expect(events.contains { if case .assistantMessage = $0 { true } else { false } })

        // Close, resume (`thread/resume`) and check that the thread remembers.
        _ = try await client.request(.closeSession(SessionRef(sessionId: sessionId)))
        _ = try await client.request(.resumeSession(SessionRef(sessionId: sessionId)), timeout: 60)
        _ = try await client.request(.sendMessage(SendMessage(
            sessionId: sessionId,
            text: "Without running any commands: what is the exact name of the file you just created? Answer with the file name only."
        )), timeout: 60)
        var followUp = ""
        for await message in pushes {
            if case .event(let payload) = message, payload.sessionId == sessionId {
                if case .assistantMessage(let text) = payload.payload { followUp += text.text }
                if case .result = payload.payload { break }
                if case .systemNotice(let notice) = payload.payload, notice.kind == "resumeFailed" {
                    Issue.record("Resume failed: \(notice.text)")
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
