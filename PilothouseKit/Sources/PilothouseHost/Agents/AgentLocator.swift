import Foundation
import PilothouseKit

/// Finds agent CLIs on the Mac and reports their version and sign-in state.
public enum AgentLocator {
    /// Well-known install locations (native installers, Homebrew, npm).
    public static func fallbackPaths(for name: String, home: String) -> [String] {
        [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
        ]
    }

    /// Order: login shell `command -v` → `PATH` of the captured environment →
    /// well-known locations (same as `ClaudeLocator`).
    public static func locate(_ name: String, environment: [String: String], home: String = NSHomeDirectory()) async -> String? {
        let shell = environment["SHELL"] ?? "/bin/zsh"
        if let output = try? await ChildProcess.runToCompletion(
            executable: shell,
            arguments: ["-l", "-c", "command -v \(name)"],
            environment: environment,
            workingDirectory: home,
            timeout: 10
        ), output.status?.isSuccess == true {
            let candidate = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init) ?? ""
            if candidate.hasPrefix("/"), ClaudeLocator.isExecutable(candidate) { return candidate }
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if ClaudeLocator.isExecutable(candidate) { return candidate }
        }
        return fallbackPaths(for: name, home: home).first(where: ClaudeLocator.isExecutable)
    }

    /// First line of `<cli> --version`, e.g. `codex-cli 0.162.1`.
    public static func version(executable: String, environment: [String: String]) async -> String? {
        await ClaudeLocator.version(executable: executable, environment: environment)
            .map { $0.split(separator: "\n").first.map(String.init) ?? $0 }
    }

    /// `codex login status` exits 0 only when signed in.
    static func codexLoggedIn(executable: String, environment: [String: String]) async -> Bool? {
        guard let output = try? await ChildProcess.runToCompletion(
            executable: executable, arguments: ["login", "status"], environment: environment, timeout: 15
        ), let status = output.status else { return nil }
        return status.isSuccess
    }

    /// Gemini has no status command; an API key or a chosen auth type is the best hint.
    static func geminiLoggedIn(environment: [String: String], home: String) -> Bool? {
        if environment["GEMINI_API_KEY"]?.isEmpty == false || environment["GOOGLE_API_KEY"]?.isEmpty == false { return true }
        let settings = URL(fileURLWithPath: home).appendingPathComponent(".gemini/settings.json")
        guard let data = try? Data(contentsOf: settings), let value = try? JSONValue.parse(data) else { return false }
        let selected = value["security"]?["auth"]?["selectedType"]?.stringValue ?? value["selectedAuthType"]?.stringValue
        return selected == nil ? false : nil
    }

    /// Status of every known agent; `claude` reuses the existing Claude status.
    public static func statuses(
        claude: ClaudeCLIStatus, environment: [String: String], delegation: Set<AgentKind>, home: String = NSHomeDirectory()
    ) async -> [AgentStatus] {
        async let claudeModels: [ModelOption]? = claude.path != nil && claude.loggedIn != false
            ? ModelCatalogReader.claude(executable: claude.path!, environment: environment) : nil
        var result: [AgentStatus] = []
        for kind in AgentKind.known where kind != .claude {
            guard let path = await locate(kind.executableName, environment: environment, home: home) else {
                result.append(AgentStatus(kind: kind, installed: false))
                continue
            }
            let version = await version(executable: path, environment: environment)
            let loggedIn: Bool? = switch kind {
            case .codex: await codexLoggedIn(executable: path, environment: environment)
            case .gemini: geminiLoggedIn(environment: environment, home: home)
            default: nil
            }
            let models = kind == .codex && loggedIn != false
                ? await ModelCatalogReader.codex(executable: path, environment: environment) : nil
            result.append(AgentStatus(
                kind: kind, installed: true, path: path, version: version, loggedIn: loggedIn,
                models: models?.map(\.id) ?? [],
                delegationEnabled: delegation.contains(kind) && loggedIn != false,
                modelOptions: models
            ))
        }
        var claudeOptions = await claudeModels
        if let effort = claudeDefaultEffort(home: home) {
            claudeOptions = claudeOptions?.map { option in
                var option = option
                if option.effortLevels.contains(effort) { option.defaultEffort = effort }
                return option
            }
        }
        result.insert(AgentStatus(
            kind: .claude, installed: claude.installed, path: claude.path, version: claude.version, loggedIn: claude.loggedIn,
            models: claudeOptions?.map(\.id) ?? ["opus", "sonnet", "haiku"], delegationEnabled: false,
            modelOptions: claudeOptions
        ), at: 0)
        return result
    }

    /// `effortLevel` of `~/.claude/settings.json`: what Claude Code uses when no `--effort` is given.
    static func claudeDefaultEffort(home: String) -> String? {
        let url = URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url), let value = try? JSONValue.parse(data) else { return nil }
        return value["effortLevel"]?.stringValue
    }
}

/// Launches `codex app-server` for one session.
public struct CodexLauncher: AgentLauncher {
    public var executable: String
    public var environment: [String: String]

    public init(executable: String, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    public func launch(_ options: ClaudeLaunchOptions) async throws -> ChildProcess {
        var environment = environment
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        return try ChildProcess.spawn(
            executable: executable,
            arguments: ["app-server"],
            environment: environment,
            workingDirectory: options.workingDirectory
        )
    }

    public func makeAdapter(for options: ClaudeLaunchOptions) -> any AgentAdapter {
        CodexAdapter(options: .init(
            workingDirectory: options.workingDirectory,
            model: options.model,
            permissionMode: options.permissionMode,
            threadId: options.resume ? options.agentSessionId : nil,
            effort: options.effort
        ))
    }
}
