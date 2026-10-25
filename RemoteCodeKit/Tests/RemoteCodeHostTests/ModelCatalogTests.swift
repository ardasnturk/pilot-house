import Foundation
import RemoteCodeKit
import Testing
@testable import RemoteCodeHost

@Suite struct ModelCatalogTests {
    @Test func claudeInitializeModels() throws {
        let response = try JSONValue.parse(#"""
        {"models":[
          {"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","supportsEffort":true,"supportedEffortLevels":["low","high"]},
          {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5","description":"Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},
          {"value":"haiku","resolvedModel":"claude-haiku-5-5","displayName":"Haiku 5.5","supportsEffort":true,"supportedEffortLevels":["low","high"]},
          {"value":"claude-haiku-4-5-20251001","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5"}
        ]}
        """#)
        let models = try #require(ModelCatalogReader.parseClaude(response))
        #expect(models.map(\.id) == ["opus", "haiku", "claude-haiku-4-5-20251001"])
        #expect(models[0] == ModelOption(
            id: "opus", displayName: "Opus 5.5", description: "Best for everyday, complex tasks",
            resolvedModel: "claude-opus-5-5", effortLevels: ["low", "medium", "high", "xhigh", "max"], isDefault: true
        ))
        #expect(models[2].effortLevels.isEmpty)
        #expect(!models[1].isDefault)

        let status = AgentStatus(kind: .claude, installed: true, modelOptions: models)
        #expect(status.modelOption(for: "claude-haiku-5-5")?.displayName == "Haiku 5.5")
        #expect(status.modelOption(for: nil)?.id == "opus")
        #expect(status.effortLevels(for: "claude-haiku-4-5-20251001").isEmpty)
    }

    @Test func codexModelList() throws {
        let result = try JSONValue.parse(#"""
        {"data":[
          {"id":"gpt-6-astra","model":"gpt-6-astra","displayName":"GPT-6 Astra","description":"Frontier","hidden":false,"isDefault":true,
           "defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"low","description":""},{"reasoningEffort":"medium","description":""},{"reasoningEffort":"high","description":""}]},
          {"id":"secret","model":"secret","displayName":"Hidden","description":"","hidden":true,"isDefault":false,"defaultReasoningEffort":"low","supportedReasoningEfforts":[]}
        ],"nextCursor":null}
        """#)
        let models = try #require(ModelCatalogReader.parseCodex(result))
        #expect(models == [ModelOption(
            id: "gpt-6-astra", displayName: "GPT-6 Astra", description: "Frontier", resolvedModel: "gpt-6-astra",
            effortLevels: ["low", "medium", "high"], defaultEffort: "medium", isDefault: true
        )])
    }
}

/// Asks the CLIs installed on this Mac.
///
///     REMOTECODE_REAL_MODELS=1 swift test --filter RealModelCatalogTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REMOTECODE_REAL_MODELS"] != nil))
struct RealModelCatalogTests {
    @Test func realCLIsListTheirModels() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let claude = await AgentLocator.locate("claude", environment: environment) {
            let models = try #require(await ModelCatalogReader.claude(executable: claude, environment: environment))
            print("Claude:", models.map { "\($0.id)=\($0.displayName) \($0.effortLevels)\($0.isDefault ? " default" : "")" })
            #expect(!models.isEmpty)
        }
        if let codex = await AgentLocator.locate("codex", environment: environment) {
            let models = try #require(await ModelCatalogReader.codex(executable: codex, environment: environment))
            print("Codex:", models.map { "\($0.id)=\($0.displayName) \($0.effortLevels) \($0.defaultEffort ?? "-")" })
            #expect(!models.isEmpty)
        }
    }
}
