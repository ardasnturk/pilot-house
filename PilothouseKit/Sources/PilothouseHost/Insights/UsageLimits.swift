import Foundation
import PilothouseKit

/// Parses the usage limits the agent CLIs report (D-097).
public enum UsageLimitParser {
    /// Claude Code `rate_limit_event`: account-wide five-hour and seven-day
    /// windows (`unifiedWindows`), not per model.
    public static func claude(_ value: JSONValue, at date: Date = Date()) -> UsageLimits? {
        guard value["type"]?.stringValue == "rate_limit_event", let info = value["rate_limit_info"] else { return nil }
        let limited = info["status"]?.stringValue.map { $0 != "allowed" } ?? false
        let limitedType = info["rateLimitType"]?.stringValue
        var windows: [LimitWindow] = []
        let durations = ["five_hour": 300, "seven_day": 10_080, "seven_day_opus": 10_080, "seven_day_sonnet": 10_080]
        for (key, window) in (info["unifiedWindows"]?.objectValue ?? [:]).sorted(by: { (durations[$0.key] ?? 0) < (durations[$1.key] ?? 0) }) {
            windows.append(LimitWindow(
                key: key,
                durationMinutes: durations[key],
                usedPercent: min(100, max(0, (window["utilization"]?.doubleValue ?? 0) * 100)),
                resetsAt: window["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
                model: key.hasPrefix("seven_day_") ? String(key.dropFirst("seven_day_".count)) : nil,
                isLimited: limited && limitedType == key
            ))
        }
        if windows.isEmpty, let type = limitedType {
            // Older CLIs only name the window that applies.
            windows.append(LimitWindow(
                key: type, durationMinutes: durations[type], usedPercent: limited ? 100 : 0,
                resetsAt: info["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }, isLimited: limited
            ))
        }
        return UsageLimits(agent: .claude, windows: windows, observedAt: date, source: .lastTurn)
    }

    /// Codex `account/rateLimits/read` result or `account/rateLimits/updated` params.
    public static func codex(_ value: JSONValue, at date: Date = Date(), source: UsageLimits.Source = .live) -> UsageLimits? {
        var snapshots: [JSONValue] = []
        if let buckets = value["rateLimitsByLimitId"]?.objectValue, !buckets.isEmpty {
            snapshots = buckets.keys.sorted().compactMap { buckets[$0] }
        } else if let single = value["rateLimits"], !single.isNull {
            snapshots = [single]
        }
        guard !snapshots.isEmpty else { return nil }
        var windows: [LimitWindow] = []
        var plan: String?
        for snapshot in snapshots {
            plan = plan ?? snapshot["planType"]?.stringValue
            let model = snapshot["normalModelSlug"]?.stringValue ?? snapshot["limitName"]?.stringValue
            let reached = snapshot["rateLimitReachedType"]?.stringValue
            for key in ["primary", "secondary"] {
                guard let window = snapshot[key], !window.isNull else { continue }
                let used = window["usedPercent"]?.doubleValue ?? 0
                windows.append(LimitWindow(
                    key: key,
                    durationMinutes: window["windowDurationMins"]?.intValue,
                    usedPercent: min(100, max(0, used)),
                    resetsAt: window["resetsAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
                    model: snapshots.count > 1 ? model : nil,
                    isLimited: used >= 100 || (reached != nil && reached == key)
                ))
            }
        }
        return UsageLimits(agent: .codex, windows: windows, observedAt: date, source: source, plan: plan)
    }
}

/// Last known limits per agent, kept across restarts in `usage-limits.json`.
public actor UsageLimitStore {
    private let url: URL
    private var limits: [AgentKind: UsageLimits] = [:]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let stored = try? PilothouseJSON.decode([UsageLimits].self, from: data) {
            limits = Dictionary(stored.map { ($0.agent, $0) }, uniquingKeysWith: { $1 })
        }
    }

    public func update(_ value: UsageLimits) {
        guard !value.windows.isEmpty else { return }
        limits[value.agent] = value
        if let data = try? PilothouseJSON.encode(Array(limits.values)) {
            try? PrivateFiles.writeAtomically(data, to: url)
        }
    }

    public func limits(for agent: AgentKind) -> UsageLimits? { limits[agent] }

    /// Every agent in `agents`, with an `unavailable` entry for those without data.
    public func all(for agents: [AgentKind]) -> [UsageLimits] {
        agents.map { agent in
            limits[agent] ?? UsageLimits(agent: agent, windows: [], observedAt: nil, source: agent == .gemini ? .unavailable : .lastTurn)
        }
    }
}

/// Reads Codex limits without a model call: a short-lived `codex app-server`,
/// `initialize`, then `account/rateLimits/read`.
public enum CodexLimitReader {
    public static func read(executable: String, environment: [String: String], timeout: Double = 15) async -> UsageLimits? {
        guard let process = try? ChildProcess.spawn(
            executable: executable, arguments: ["app-server"], environment: environment,
            workingDirectory: NSHomeDirectory()
        ) else { return nil }
        defer { Task { await process.terminate(grace: 1) } }
        let lines = [
            JSONRPC.request(id: 1, method: "initialize", params: ["clientInfo": ["name": "pilothouse", "title": "Remote Code", "version": "1.0"], "capabilities": nil]),
            JSONRPC.notification(method: "initialized"),
            JSONRPC.request(id: 2, method: "account/rateLimits/read", params: ["excludeResetCreditDetails": true]),
        ]
        for line in lines { try? await process.write(line) }
        let output = process.stdout.lines()
        return try? await withTimeout(seconds: timeout, onTimeout: { await process.terminate(grace: 0) }) {
            for await line in output {
                guard let message = JSONRPC.parse(line), message["id"]?.intValue == 2 else { continue }
                return message["result"].flatMap { codex($0) }
            }
            return nil
        }
    }

    private static func codex(_ result: JSONValue) -> UsageLimits? {
        UsageLimitParser.codex(result)
    }
}
