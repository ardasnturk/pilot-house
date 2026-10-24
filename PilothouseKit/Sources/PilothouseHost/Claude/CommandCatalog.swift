import Foundation
import PilothouseKit

/// Builds the `/` menu of a Claude session (D-098): the names come from the
/// CLI's `system/init` (`slash_commands`, `skills`, `plugins`); descriptions
/// and sources are read from the files Claude Code loads them from.
///
/// Lookup order mirrors Claude Code's precedence: project (`<cwd>/.claude`),
/// personal (`~/.claude`), then plugins; anything not found on disk is built in.
public enum CommandCatalogBuilder {
    public static let maximumDescriptionLength = 280

    public static func build(
        slashCommands: [String], skills: [String], plugins: [String: String], cwd: String, home: String
    ) -> [CommandInfo] {
        let skillSet = Set(skills)
        var seen = Set<String>()
        var result: [CommandInfo] = []
        // Names starting with "_" are Claude Code internals, not meant for users.
        for name in slashCommands + skills where !name.hasPrefix("_") && seen.insert(name).inserted {
            let kind: CommandInfo.Kind = skillSet.contains(name) ? .skill : .command
            result.append(entry(name: name, kind: kind, plugins: plugins, cwd: cwd, home: home))
        }
        return result.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func entry(name: String, kind: CommandInfo.Kind, plugins: [String: String], cwd: String, home: String) -> CommandInfo {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        let pluginName = parts.count == 2 ? parts[0] : nil
        let shortName = parts.last ?? name
        var candidates: [(CommandInfo.Source, String?, URL)] = []
        if pluginName == nil {
            candidates.append((.project, nil, file(kind, shortName, in: URL(fileURLWithPath: cwd).appendingPathComponent(".claude"))))
            candidates.append((.personal, nil, file(kind, shortName, in: URL(fileURLWithPath: home).appendingPathComponent(".claude"))))
        }
        let pluginFolders = pluginName.flatMap { plugin in plugins[plugin].map { [(plugin, $0)] } }
            ?? plugins.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        for (plugin, path) in pluginFolders where path.hasPrefix("/") {
            candidates.append((.plugin, plugin, file(kind, shortName, in: URL(fileURLWithPath: path))))
        }
        for (source, plugin, url) in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return CommandInfo(name: name, kind: kind, source: source, description: description(from: text), plugin: plugin)
        }
        return CommandInfo(
            name: name, kind: kind, source: pluginName == nil ? .builtin : .plugin,
            description: kind == .command ? builtinDescriptions[name] : nil, plugin: pluginName
        )
    }

    /// What Claude Code would load, found on disk: project and personal skills
    /// and commands, enabled plugins, and the built-in commands. Used so the
    /// `/` menu works before the CLI's first `system/init` (a chat without
    /// messages yet), and to pick up files added since.
    public struct Discovery: Sendable, Equatable {
        public var skills: [String] = []
        public var commands: [String] = []
        /// Plugin name → install folder.
        public var plugins: [String: String] = [:]
    }

    public static func discover(cwd: String, home: String) -> Discovery {
        var found = Discovery()
        let fileManager = FileManager.default
        func scan(_ base: URL, prefix: String) {
            let skills = base.appendingPathComponent("skills")
            for name in (try? fileManager.contentsOfDirectory(atPath: skills.path)) ?? []
            where fileManager.fileExists(atPath: skills.appendingPathComponent("\(name)/SKILL.md").path) {
                found.skills.append(prefix + name)
            }
            let commands = base.appendingPathComponent("commands")
            for entry in (try? fileManager.contentsOfDirectory(atPath: commands.path)) ?? [] {
                if entry.hasSuffix(".md") {
                    found.commands.append(prefix + String(entry.dropLast(3)))
                } else if prefix.isEmpty {
                    // A sub-folder namespaces its commands: commands/git/push.md → /git:push.
                    let folder = commands.appendingPathComponent(entry)
                    for file in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where file.hasSuffix(".md") {
                        found.commands.append("\(entry):\(file.dropLast(3))")
                    }
                }
            }
        }
        let claudeHome = URL(fileURLWithPath: home).appendingPathComponent(".claude")
        if cwd != home {
            scan(URL(fileURLWithPath: cwd).appendingPathComponent(".claude"), prefix: "")
        }
        scan(claudeHome, prefix: "")
        for (name, path) in enabledPlugins(claudeHome: claudeHome) {
            found.plugins[name] = path
            scan(URL(fileURLWithPath: path), prefix: "\(name):")
        }
        found.commands += builtinDescriptions.keys
        return found
    }

    /// `enabledPlugins` of `~/.claude/settings.json` mapped to their install
    /// folders from `plugins/installed_plugins.json` (format version 2).
    static func enabledPlugins(claudeHome: URL) -> [String: String] {
        func json(_ path: String) -> JSONValue? {
            (try? Data(contentsOf: claudeHome.appendingPathComponent(path))).flatMap { try? JSONValue.parse($0) }
        }
        guard
            let enabled = json("settings.json")?["enabledPlugins"]?.objectValue,
            let installed = json("plugins/installed_plugins.json")?["plugins"]?.objectValue
        else { return [:] }
        var result: [String: String] = [:]
        for (id, flag) in enabled where flag.boolValue == true {
            guard let path = installed[id]?.arrayValue?.first?["installPath"]?.stringValue else { continue }
            let name = id.split(separator: "@").first.map(String.init) ?? id
            result[name] = path
        }
        return result
    }

    private static func file(_ kind: CommandInfo.Kind, _ name: String, in base: URL) -> URL {
        switch kind {
        case .skill: base.appendingPathComponent("skills/\(name)/SKILL.md")
        case .command: base.appendingPathComponent("commands/\(name).md")
        }
    }

    /// `description:` from YAML front matter (plain, quoted or a `>`/`|` block),
    /// else the first line of text.
    static func description(from markdown: String) -> String? {
        var lines = markdown.components(separatedBy: .newlines)[...]
        var body = lines
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines = lines.dropFirst()
            let end = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "---" } ?? lines.endIndex
            let front = lines[lines.startIndex..<end]
            body = end < lines.endIndex ? lines[(end + 1)...] : []
            if let index = front.firstIndex(where: { $0.hasPrefix("description:") }) {
                var value = front[index].dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                if value.isEmpty || value == ">" || value == "|" || value == ">-" || value == "|-" {
                    value = front[(index + 1)...].prefix { $0.hasPrefix(" ") || $0.hasPrefix("\t") }
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .joined(separator: " ")
                }
                return clip(unquote(value))
            }
        }
        let first = body.lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<!--") }
        return first.flatMap { clip($0) }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func clip(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > maximumDescriptionLength ? String(trimmed.prefix(maximumDescriptionLength - 1)) + "…" : trimmed
    }

    /// Short descriptions of Claude Code's built-in commands that work headless.
    static let builtinDescriptions: [String: String] = [
        "compact": "Summarise the conversation to free up context",
        "context": "Show what is using the context window",
        "cost": "Show the cost of this session",
        "init": "Write a CLAUDE.md for this project",
        "review": "Review a pull request",
        "pr-comments": "Show the comments of a pull request",
        "security-review": "Review the pending changes for security issues",
        "release-notes": "Show Claude Code's release notes",
        "clear": "Start over with an empty conversation",
        "model": "Switch the model",
        "memory": "Edit memory files",
        "todos": "Show the current task list",
    ]
}
