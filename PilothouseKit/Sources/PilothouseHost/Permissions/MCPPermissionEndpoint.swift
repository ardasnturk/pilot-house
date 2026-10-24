import Foundation
import PilothouseKit

/// What the permission tool answers Claude (the documented `PermissionResult`).
public enum PermissionToolResult: Sendable, Equatable {
    case allow(updatedInput: JSONValue)
    case deny(message: String)

    var json: JSONValue {
        switch self {
        case .allow(let input): ["behavior": "allow", "updatedInput": input]
        case .deny(let message): ["behavior": "deny", "message": .string(message)]
        }
    }
}

/// A minimal MCP server (Streamable HTTP, JSON responses only) exposing one
/// tool, `approve_permission`, for `--permission-prompt-tool`
/// (docs/DECISIONS.md D-004).
///
/// Security (SECURITY.md): bearer token per CLI process, requests with an
/// `Origin` header are refused (DNS rebinding), `Host` must be loopback.
public struct MCPPermissionEndpoint: Sendable {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// Maps a bearer token to a session ID.
    public var resolveToken: @Sendable (String) async -> String?
    /// Decides one permission request.
    public var decide: @Sendable (_ sessionId: String, _ toolName: String, _ input: JSONValue, _ toolUseId: String?) async -> PermissionToolResult
    public var serverVersion: String

    public init(
        serverVersion: String = "1.0",
        resolveToken: @escaping @Sendable (String) async -> String?,
        decide: @escaping @Sendable (String, String, JSONValue, String?) async -> PermissionToolResult
    ) {
        self.serverVersion = serverVersion
        self.resolveToken = resolveToken
        self.decide = decide
    }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.path.split(separator: "?").first == "/mcp" else {
            return .text(404, "Not Found")
        }
        if let origin = request.headers["origin"], !origin.isEmpty, origin != "null" {
            return .text(403, "Forbidden")
        }
        if let host = request.headers["host"] {
            let hostname = host.split(separator: ":").first.map(String.init) ?? host
            guard ["127.0.0.1", "localhost", "[::1]"].contains(hostname) else { return .text(403, "Forbidden") }
        }
        guard
            let authorization = request.headers["authorization"],
            authorization.hasPrefix("Bearer "),
            let sessionId = await resolveToken(String(authorization.dropFirst("Bearer ".count)))
        else {
            return .text(401, "Unauthorized")
        }
        switch request.method {
        case "POST":
            break
        case "GET", "DELETE":
            // No server-initiated stream, no MCP session state (spec allows 405).
            return HTTPResponse(status: 405, headers: ["Allow": "POST"], body: Data())
        default:
            return HTTPResponse(status: 405, headers: ["Allow": "POST"], body: Data())
        }

        guard let message = try? JSONValue.parse(request.body) else {
            return .json(200, Self.error(id: .null, code: -32700, message: "Parse error"))
        }
        if let batch = message.arrayValue {
            var responses: [JSONValue] = []
            for item in batch {
                if let response = await handleRPC(item, sessionId: sessionId) { responses.append(response) }
            }
            return responses.isEmpty ? HTTPResponse(status: 202, headers: [:], body: Data()) : .json(200, .array(responses))
        }
        guard let response = await handleRPC(message, sessionId: sessionId) else {
            return HTTPResponse(status: 202, headers: [:], body: Data())
        }
        return .json(200, response)
    }

    /// Returns `nil` for notifications.
    func handleRPC(_ message: JSONValue, sessionId: String) async -> JSONValue? {
        guard let id = message["id"], !id.isNull else { return nil }
        let method = message["method"]?.stringValue ?? ""
        switch method {
        case "initialize":
            let requested = message["params"]?["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : "2025-06-18"
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(ClaudeCommand.permissionServerName), "version": .string(serverVersion)],
                "instructions": "Pilothouse forwards permission prompts to the paired iPhone or iPad.",
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": [Self.toolDefinition]])
        case "tools/call":
            guard message["params"]?["name"]?.stringValue == ClaudeCommand.permissionToolName else {
                return Self.error(id: id, code: -32602, message: "Unknown tool")
            }
            let arguments = message["params"]?["arguments"] ?? [:]
            let toolName = arguments["tool_name"]?.stringValue ?? "Unknown"
            let input = arguments["input"] ?? [:]
            let toolUseId = arguments["tool_use_id"]?.stringValue
            let decision = await decide(sessionId, toolName, input, toolUseId)
            return Self.result(id: id, [
                "content": [["type": "text", "text": .string(decision.json.jsonString())]],
            ])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static let toolDefinition: JSONValue = [
        "name": .string(ClaudeCommand.permissionToolName),
        "description": "Asks the Pilothouse user on their phone whether Claude may use a tool.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "tool_name": ["type": "string"],
                "input": ["type": "object"],
                "tool_use_id": ["type": "string"],
            ],
            "required": ["tool_name", "input"],
        ],
    ]

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
