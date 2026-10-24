import Foundation

/// Where to open a transport to.
public enum Endpoint: Sendable, Hashable, CustomStringConvertible {
    case hostPort(host: String, port: Int)
    /// A Bonjour service instance discovered on the LAN.
    case bonjour(name: String, type: String, domain: String)
    /// The in-process demo server.
    case demo

    public var description: String {
        switch self {
        case .hostPort(let host, let port):
            host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        case .bonjour(let name, _, _): "Bonjour \"\(name)\""
        case .demo: "Demo Mac"
        }
    }
}

/// One connection attempt the client will try.
public struct ConnectionCandidate: Sendable, Hashable {
    public var endpoint: Endpoint
    public var route: ConnectionRoute
    /// Per-attempt connect timeout in seconds.
    public var timeout: Double

    public init(endpoint: Endpoint, route: ConnectionRoute, timeout: Double) {
        self.endpoint = endpoint
        self.route = route
        self.timeout = timeout
    }
}

/// Opens transports. Production: WebSocket over Network.framework.
public protocol TransportConnector: Sendable {
    func connect(to endpoint: Endpoint, timeout: Double) async throws -> any MessageTransport
}

/// Orders connection attempts as the prompt requires (§5.1):
/// last successful address → Bonjour → local IPs → Tailscale IP → MagicDNS.
public enum ConnectionPlanner {
    public static let localTimeout: Double = 4
    public static let remoteTimeout: Double = 10

    public static func candidates(for mac: PairedMac, bonjour: [Endpoint]) -> [ConnectionCandidate] {
        if mac.isDemo {
            return [ConnectionCandidate(endpoint: .demo, route: .demo, timeout: localTimeout)]
        }
        var result: [ConnectionCandidate] = []
        var seen = Set<Endpoint>()
        func add(_ endpoint: Endpoint, _ route: ConnectionRoute) {
            guard seen.insert(endpoint).inserted else { return }
            let timeout = route == .local ? localTimeout : remoteTimeout
            result.append(ConnectionCandidate(endpoint: endpoint, route: route, timeout: timeout))
        }

        if let host = mac.lastSuccessfulHost {
            let port = mac.lastSuccessfulPort ?? mac.port
            add(.hostPort(host: host, port: port), HostAddress.classify(host) == .local ? .local : .tailscale)
        }
        for endpoint in bonjour { add(endpoint, .local) }
        for address in mac.addresses where address.kind == .local {
            add(.hostPort(host: address.host, port: mac.port), .local)
        }
        for address in mac.addresses where address.kind == .tailscale {
            add(.hostPort(host: address.host, port: mac.port), .tailscale)
        }
        for address in mac.addresses where address.kind == .magicDNS {
            add(.hostPort(host: address.host, port: mac.port), .tailscale)
        }
        return result
    }
}

/// Exponential back-off with full jitter, capped.
public struct Backoff: Sendable {
    public var base: Double
    public var cap: Double
    public private(set) var attempt = 0

    public init(base: Double = 1, cap: Double = 30) {
        self.base = base
        self.cap = cap
    }

    /// Delay before the next attempt; grows 1, 2, 4, 8 … up to `cap`, with jitter
    /// in the upper half so retries from many phones do not synchronise.
    public mutating func nextDelay(random: Double = Double.random(in: 0...1)) -> Double {
        let exponential = min(cap, base * pow(2, Double(attempt)))
        attempt += 1
        return exponential / 2 + exponential / 2 * random
    }

    public mutating func reset() {
        attempt = 0
    }
}
