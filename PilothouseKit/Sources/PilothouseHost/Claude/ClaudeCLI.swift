import Foundation
import PilothouseKit

/// Reads the user's login-shell environment so the CLI sees the same `PATH`
/// (Homebrew, nvm, asdf, …) as in Terminal. GUI apps launched by `launchd` get
/// a minimal environment otherwise.
public enum LoginShellEnvironment {
    private static let beginMarker = "__PILOTHOUSE_ENV_BEGIN__"
    private static let endMarker = "__PILOTHOUSE_ENV_END__"

    /// Runs `$SHELL -ilc` (then `-lc`) and parses `env -0`. Falls back to the
    /// current process environment with common tool directories appended.
    public static func capture(
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        base: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) async -> [String: String] {
        let shellPath = shell.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let script = "printf '%s' '\(beginMarker)'; /usr/bin/env -0; printf '%s' '\(endMarker)'"
        for flags in [["-i", "-l", "-c"], ["-l", "-c"]] {
            guard
                let output = try? await ChildProcess.runToCompletion(
                    executable: shellPath,
                    arguments: flags + [script],
                    environment: minimalEnvironment(base: base, home: home, shell: shellPath),
                    workingDirectory: home,
                    timeout: 10
                ),
                !output.timedOut,
                let parsed = parse(output.stdout), parsed["PATH"] != nil
            else { continue }
            return parsed
        }
        return fallback(base: base, home: home)
    }

    /// Extracts `KEY=value` pairs between the markers of an `env -0` dump.
    static func parse(_ output: Data) -> [String: String]? {
        let text = String(decoding: output, as: UTF8.self)
        guard let begin = text.range(of: beginMarker), let end = text.range(of: endMarker, range: begin.upperBound..<text.endIndex) else {
            return nil
        }
        var result: [String: String] = [:]
        for entry in text[begin.upperBound..<end.lowerBound].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[entry.startIndex..<equals])
            guard !key.isEmpty, !key.contains("\n") else { continue }
            result[key] = String(entry[entry.index(after: equals)...])
        }
        return result.isEmpty ? nil : result
    }

    static func minimalEnvironment(base: [String: String], home: String, shell: String) -> [String: String] {
        var environment: [String: String] = [
            "HOME": home,
            "SHELL": shell,
            "USER": base["USER"] ?? NSUserName(),
            "LOGNAME": base["LOGNAME"] ?? NSUserName(),
            "PATH": base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "dumb",
            "LANG": base["LANG"] ?? "en_US.UTF-8",
        ]
        if let tmp = base["TMPDIR"] { environment["TMPDIR"] = tmp }
        return environment
    }

    static func fallback(base: [String: String], home: String) -> [String: String] {
        var environment = base
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var path = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in extra where !path.contains(directory) { path.append(directory) }
        environment["PATH"] = path.joined(separator: ":")
        environment["HOME"] = home
        return environment
    }
}

/// Finds the official `claude` binary.
public enum ClaudeLocator {
    /// Well-known install locations (native installer, Homebrew, npm).
    public static func fallbackPaths(home: String) -> [String] {
        [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.npm-global/bin/claude",
        ]
    }

    /// Order: login shell `command -v claude` → `PATH` of the captured
    /// environment → well-known locations.
    public static func locate(environment: [String: String], home: String = NSHomeDirectory()) async -> String? {
        let shell = environment["SHELL"] ?? "/bin/zsh"
        if let output = try? await ChildProcess.runToCompletion(
            executable: shell,
            arguments: ["-l", "-c", "command -v claude"],
            environment: environment,
            workingDirectory: home,
            timeout: 10
        ), output.status?.isSuccess == true {
            let candidate = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init) ?? ""
            if candidate.hasPrefix("/"), isExecutable(candidate) { return candidate }
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/claude"
            if isExecutable(candidate) { return candidate }
        }
        return fallbackPaths(home: home).first(where: isExecutable)
    }

    /// `claude --version`, e.g. `2.1.310 (Claude Code)`.
    public static func version(executable: String, environment: [String: String]) async -> String? {
        guard
            let output = try? await ChildProcess.runToCompletion(
                executable: executable, arguments: ["--version"], environment: environment, timeout: 15
            ),
            output.status?.isSuccess == true
        else { return nil }
        let version = output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    /// `claude auth status` → `loggedIn`. Pilothouse only reads this flag; it
    /// never touches the CLI's credentials.
    public static func isLoggedIn(executable: String, environment: [String: String]) async -> Bool? {
        guard
            let output = try? await ChildProcess.runToCompletion(
                executable: executable, arguments: ["auth", "status"], environment: environment, timeout: 15
            ),
            let status = try? JSONValue.parse(output.stdout)
        else { return nil }
        return status["loggedIn"]?.boolValue
    }

    /// Locates the CLI and gathers version and sign-in state.
    public static func status(environment: [String: String], home: String = NSHomeDirectory()) async -> ClaudeCLIStatus {
        guard let path = await locate(environment: environment, home: home) else {
            return ClaudeCLIStatus(installed: false)
        }
        async let version = version(executable: path, environment: environment)
        async let loggedIn = isLoggedIn(executable: path, environment: environment)
        return ClaudeCLIStatus(installed: true, path: path, version: await version, loggedIn: await loggedIn)
    }

    static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

/// Everything needed to start one CLI process for a session.
public struct ClaudeLaunchOptions: Sendable, Equatable {
    public var sessionId: String
    /// `true` → `--resume <id>`; `false` → `--session-id <id>` (new conversation).
    public var resume: Bool
    public var model: String?
    public var permissionMode: PermissionMode
    public var workingDirectory: String
    /// Local permission endpoint, if any.
    public var permissionServer: PermissionServerInfo?
    public var agent: AgentKind
    /// The agent's own conversation ID to resume (Codex thread), if known.
    public var agentSessionId: String?

    public init(
        sessionId: String, resume: Bool, model: String?, permissionMode: PermissionMode, workingDirectory: String,
        permissionServer: PermissionServerInfo?, agent: AgentKind = .claude, agentSessionId: String? = nil
    ) {
        self.sessionId = sessionId
        self.resume = resume
        self.model = model
        self.permissionMode = permissionMode
        self.workingDirectory = workingDirectory
        self.permissionServer = permissionServer
        self.agent = agent
        self.agentSessionId = agentSessionId
    }
}

/// Where the CLI reaches the permission MCP server.
public struct PermissionServerInfo: Sendable, Equatable {
    public var port: Int
    public var token: String

    public init(port: Int, token: String) {
        self.port = port
        self.token = token
    }
}

/// Builds the CLI invocation (docs/DECISIONS.md D-001, D-004).
public enum ClaudeCommand {
    public static let permissionServerName = "pilothouse"
    public static let permissionToolName = "approve_permission"
    public static var permissionToolFullName: String { "mcp__\(permissionServerName)__\(permissionToolName)" }
    public static let delegationToolName = "delegate_to_agent"
    public static var delegationToolFullName: String { "mcp__\(permissionServerName)__\(delegationToolName)" }
    /// Per-request MCP timeout: longer than a delegated sub-agent task may run
    /// (`SessionManager.delegationTimeout`), so Claude waits for its answer.
    public static let mcpTimeoutMilliseconds = 3_660_000

    public static func arguments(for options: ClaudeLaunchOptions) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        arguments += options.resume ? ["--resume", options.sessionId] : ["--session-id", options.sessionId]
        if let model = options.model, !model.isEmpty {
            arguments += ["--model", model]
        }
        arguments += ["--permission-mode", options.permissionMode.rawValue]
        if let server = options.permissionServer {
            arguments += ["--mcp-config", mcpConfiguration(server), "--permission-prompt-tool", permissionToolFullName]
        }
        return arguments
    }

    public static func mcpConfiguration(_ server: PermissionServerInfo) -> String {
        let entry: JSONValue = [
            "type": "http",
            "url": .string("http://127.0.0.1:\(server.port)/mcp"),
            "headers": ["Authorization": .string("Bearer \(server.token)")],
            "timeout": .number(Double(mcpTimeoutMilliseconds)),
        ]
        let config: JSONValue = ["mcpServers": .object([permissionServerName: entry])]
        return config.jsonString()
    }

    /// The child's environment: the login-shell environment, minus anything that
    /// would change how the CLI authenticates or think it is nested, plus the API
    /// key only when API-key mode was explicitly chosen (prompt §4.4).
    public static func environment(base: [String: String], apiKey: String?) -> [String: String] {
        var environment = base
        for key in ["ANTHROPIC_API_KEY", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID"] {
            environment.removeValue(forKey: key)
        }
        if let apiKey, !apiKey.isEmpty {
            environment["ANTHROPIC_API_KEY"] = apiKey
        }
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        return environment
    }

    /// One line of stream-json input carrying a user message.
    public static func userMessageLine(text: String, attachments: [MessageAttachment]) throws -> Data {
        let content: JSONValue
        if attachments.isEmpty {
            content = .string(text)
        } else {
            var blocks: [JSONValue] = attachments.map { attachment in
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": .string(attachment.mediaType),
                        "data": .string(attachment.data.base64EncodedString()),
                    ],
                ]
            }
            if !text.isEmpty {
                blocks.append(["type": "text", "text": .string(text)])
            }
            content = .array(blocks)
        }
        let message: JSONValue = [
            "type": "user",
            "message": ["role": "user", "content": content],
        ]
        return Data((message.jsonString() + "\n").utf8)
    }
}

/// Starts agent CLI processes. Production uses the real CLIs; tests use FakeClaude.
public protocol ClaudeLauncher: Sendable {
    func launch(_ options: ClaudeLaunchOptions) async throws -> ChildProcess
    /// The adapter that speaks the launched process's protocol.
    func makeAdapter(for options: ClaudeLaunchOptions) -> any AgentAdapter
}

public typealias AgentLauncher = ClaudeLauncher

extension ClaudeLauncher {
    public func makeAdapter(for options: ClaudeLaunchOptions) -> any AgentAdapter { ClaudeAdapter() }
}

/// Launches the real CLI found by `ClaudeLocator`.
public struct CLIClaudeLauncher: ClaudeLauncher {
    public var executable: String
    public var environment: [String: String]
    public var apiKey: String?

    public init(executable: String, environment: [String: String], apiKey: String?) {
        self.executable = executable
        self.environment = environment
        self.apiKey = apiKey
    }

    public func launch(_ options: ClaudeLaunchOptions) async throws -> ChildProcess {
        try ChildProcess.spawn(
            executable: executable,
            arguments: ClaudeCommand.arguments(for: options),
            environment: ClaudeCommand.environment(base: environment, apiKey: apiKey),
            workingDirectory: options.workingDirectory
        )
    }
}
