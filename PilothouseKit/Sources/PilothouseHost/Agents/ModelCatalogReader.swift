import Foundation
import PilothouseKit

/// Asks the agent CLIs which models they offer, without a model call:
/// Claude Code answers the stream-json `initialize` control request, Codex
/// `model/list` on a short-lived `codex app-server` (D-102).
public enum ModelCatalogReader {
    public static func claude(executable: String, environment: [String: String], timeout: Double = 20) async -> [ModelOption]? {
        guard let process = try? ChildProcess.spawn(
            executable: executable,
            arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"],
            environment: environment,
            workingDirectory: NSHomeDirectory()
        ) else { return nil }
        defer { Task { await process.terminate(grace: 1) } }
        let request: JSONValue = ["type": "control_request", "request_id": "pilothouse-models", "request": ["subtype": "initialize"]]
        try? await process.write(JSONRPC.line(request))
        let output = process.stdout.lines()
        return try? await withTimeout(seconds: timeout, onTimeout: { await process.terminate(grace: 0) }) {
            for await line in output {
                guard let message = try? JSONValue.parse(Data(line.utf8)),
                      message["type"]?.stringValue == "control_response",
                      message["response"]?["request_id"]?.stringValue == "pilothouse-models"
                else { continue }
                return parseClaude(message["response"]?["response"] ?? .null)
            }
            return nil
        }
    }

    /// `models` of Claude Code's `initialize` response. The `default` entry
    /// only marks which model runs when none is chosen.
    public static func parseClaude(_ response: JSONValue) -> [ModelOption]? {
        guard let entries = response["models"]?.arrayValue else { return nil }
        let defaultModel = entries.first { $0["value"]?.stringValue == "default" }?["resolvedModel"]?.stringValue
        var markedDefault = false
        return entries.compactMap { entry -> ModelOption? in
            guard let value = entry["value"]?.stringValue, value != "default" else { return nil }
            let resolved = entry["resolvedModel"]?.stringValue
            let isDefault = !markedDefault && resolved != nil && resolved == defaultModel
            if isDefault { markedDefault = true }
            let efforts = entry["supportsEffort"]?.boolValue == true
                ? (entry["supportedEffortLevels"]?.arrayValue ?? []).compactMap(\.stringValue) : []
            return ModelOption(
                id: value,
                displayName: entry["displayName"]?.stringValue ?? value,
                description: entry["description"]?.stringValue,
                resolvedModel: resolved,
                effortLevels: efforts,
                isDefault: isDefault
            )
        }
    }

    public static func codex(executable: String, environment: [String: String], timeout: Double = 15) async -> [ModelOption]? {
        guard let process = try? ChildProcess.spawn(
            executable: executable, arguments: ["app-server"], environment: environment,
            workingDirectory: NSHomeDirectory()
        ) else { return nil }
        defer { Task { await process.terminate(grace: 1) } }
        let lines = [
            JSONRPC.request(id: 1, method: "initialize", params: ["clientInfo": ["name": "pilothouse", "title": "Remote Code", "version": "1.1"], "capabilities": nil]),
            JSONRPC.notification(method: "initialized"),
            JSONRPC.request(id: 2, method: "model/list", params: ["includeHidden": false]),
        ]
        for line in lines { try? await process.write(line) }
        let output = process.stdout.lines()
        return try? await withTimeout(seconds: timeout, onTimeout: { await process.terminate(grace: 0) }) {
            for await line in output {
                guard let message = JSONRPC.parse(line), message["id"]?.intValue == 2 else { continue }
                return message["result"].flatMap(parseCodex)
            }
            return nil
        }
    }

    /// `data` of Codex's `model/list` result; hidden models are left out.
    public static func parseCodex(_ result: JSONValue) -> [ModelOption]? {
        guard let entries = result["data"]?.arrayValue else { return nil }
        return entries.compactMap { entry -> ModelOption? in
            guard entry["hidden"]?.boolValue != true, let id = entry["model"]?.stringValue ?? entry["id"]?.stringValue else { return nil }
            return ModelOption(
                id: id,
                displayName: entry["displayName"]?.stringValue ?? id,
                description: entry["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                resolvedModel: id,
                effortLevels: (entry["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap { $0["reasoningEffort"]?.stringValue },
                defaultEffort: entry["defaultReasoningEffort"]?.stringValue,
                isDefault: entry["isDefault"]?.boolValue == true
            )
        }
    }
}
