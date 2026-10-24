import Foundation
import PilothouseKit
import Testing
@testable import PilothouseHost

@Suite struct CommandCatalogTests {
    @Test func sourcesAndDescriptionsComeFromDisk() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.write("app/.claude/skills/swiftui-review/SKILL.md", "---\nname: swiftui-review\ndescription: \"Check SwiftUI views\"\n---\n# Body")
        try home.write(".claude/skills/swiftui-review/SKILL.md", "---\ndescription: personal copy, shadowed by the project\n---")
        try home.write(".claude/commands/deploy.md", "---\nallowed-tools: Bash\ndescription: >\n  Build and deploy\n  to staging\n---\nRun the deploy script.")
        try home.write(".claude/commands/notes.md", "# Notes\n\nSummarise my notes for today.")
        try home.write("plugins/figma/skills/figma-use/SKILL.md", "---\ndescription: Read Figma designs\n---")
        let catalog = CommandCatalogBuilder.build(
            slashCommands: ["review", "deploy", "notes", "swiftui-review", "figma:figma-use", "compact"],
            skills: ["swiftui-review", "figma:figma-use", "pdf"],
            plugins: ["figma": home.path + "/plugins/figma"],
            cwd: home.path + "/app", home: home.path
        )
        let byName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0) })
        #expect(catalog.map(\.name) == ["compact", "deploy", "figma:figma-use", "notes", "pdf", "review", "swiftui-review"])
        #expect(byName["swiftui-review"] == CommandInfo(name: "swiftui-review", kind: .skill, source: .project, description: "Check SwiftUI views"))
        #expect(byName["deploy"]?.source == .personal)
        #expect(byName["deploy"]?.description == "Build and deploy to staging")
        #expect(byName["notes"]?.description == "Summarise my notes for today.")
        #expect(byName["figma:figma-use"] == CommandInfo(name: "figma:figma-use", kind: .skill, source: .plugin, description: "Read Figma designs", plugin: "figma"))
        #expect(byName["pdf"]?.kind == .skill)
        #expect(byName["pdf"]?.source == .builtin)
        #expect(byName["review"]?.source == .builtin)
        #expect(byName["review"]?.description == "Review a pull request")
    }

    @Test func initLineCarriesSkillsAndPlugins() {
        var normalizer = StreamJSONNormalizer()
        let events = normalizer.consume(line: #"{"type":"system","subtype":"init","session_id":"s","slash_commands":["review","pdf"],"skills":["pdf"],"plugins":[{"name":"figma","path":"/p/figma"},{"name":"telemetry","path":"builtin"}]}"#)
        guard case .sessionInfo(let info)? = events.first else {
            Issue.record("Expected sessionInfo")
            return
        }
        #expect(info.skills == ["pdf"])
        #expect(info.plugins == ["figma": "/p/figma"])
    }
}

/// The real `/` menu of this Mac, from a captured `system/init` line.
///
///     PILOTHOUSE_REAL_INIT=/path/to/init.json swift test --filter RealCommandCatalogTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PILOTHOUSE_REAL_INIT"] != nil))
struct RealCommandCatalogTests {
    @Test func describesTheRealSkills() throws {
        let path = try #require(ProcessInfo.processInfo.environment["PILOTHOUSE_REAL_INIT"])
        var normalizer = StreamJSONNormalizer()
        let line = try String(contentsOfFile: path, encoding: .utf8)
        guard case .sessionInfo(let info)? = normalizer.consume(line: line).first else {
            Issue.record("Expected sessionInfo")
            return
        }
        let catalog = CommandCatalogBuilder.build(
            slashCommands: info.slashCommands, skills: info.skills ?? [], plugins: info.plugins ?? [:],
            cwd: info.cwd ?? NSHomeDirectory(), home: NSHomeDirectory()
        )
        let skills = catalog.filter { $0.kind == .skill }
        let described = catalog.filter { $0.description != nil }
        print("catalog: \(catalog.count) entries, \(skills.count) skills, \(described.count) with descriptions")
        print("by source:", Dictionary(grouping: catalog, by: \.source.rawValue).mapValues(\.count))
        for item in catalog.filter({ $0.description == nil }).prefix(12) { print("  no description:", item.kind.rawValue, item.name) }
        #expect(described.count * 2 > catalog.count)
    }
}
