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

/// Which routes the client may use (Settings → Connection).
public enum ConnectionPreference: String, Sendable, Hashable, Codable, CaseIterable {
    /// The local network first, Tailscale when the Mac is not reachable there.
    case automatic
    /// The local network only (the default: Tailscale is opt-in, D-103).
    case localOnly
    case tailscaleOnly
}

/// Orders connection attempts, local network first (D-103):
/// last successful LAN address → Bonjour → LAN IPs → then, if allowed, the
/// last successful Tailscale address → Tailscale IP → MagicDNS.
public enum ConnectionPlanner {
    public static let localTimeout: Double = 4
    public static let remoteTimeout: Double = 10

    public static func candidates(
        for mac: PairedMac,
        bonjour: [Endpoint],
        preference: ConnectionPreference = .automatic
    ) -> [ConnectionCandidate] {
        if mac.isDemo {
            return [ConnectionCandidate(endpoint: .demo, route: .demo, timeout: localTimeout)]
        }
        var result: [ConnectionCandidate] = []
        var seen = Set<Endpoint>()
        func add(_ endpoint: Endpoint, _ route: ConnectionRoute) {
            switch (preference, route) {
            case (.localOnly, .tailscale), (.tailscaleOnly, .local): return
            default: break
            }
            guard seen.insert(endpoint).inserted else { return }
            let timeout = route == .local ? localTimeout : remoteTimeout
            result.append(ConnectionCandidate(endpoint: endpoint, route: route, timeout: timeout))
        }

        let lastRoute: ConnectionRoute? = mac.lastSuccessfulHost.map { HostAddress.classify($0) == .local ? .local : .tailscale }
        func addLastSuccessful(if route: ConnectionRoute) {
            guard let host = mac.lastSuccessfulHost, lastRoute == route else { return }
            add(.hostPort(host: host, port: mac.lastSuccessfulPort ?? mac.port), route)
        }
        addLastSuccessful(if: .local)
        for endpoint in bonjour { add(endpoint, .local) }
        for address in mac.addresses where address.kind == .local {
            add(.hostPort(host: address.host, port: mac.port), .local)
        }
        addLastSuccessful(if: .tailscale)
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
