import Foundation
import RemoteCodeKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// IPv4 addresses of the Mac's active interfaces.
public enum NetworkInterfaces {
    public struct Interface: Sendable, Hashable {
        public var name: String
        public var address: String
    }

    /// Up, non-loopback IPv4 interfaces, `en*` first. Link-local addresses are skipped.
    public static func ipv4() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0,
                let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(MemoryLayout<sockaddr_in>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !text.hasPrefix("169.254.") else { continue }
            result.append(Interface(name: String(cString: entry.pointee.ifa_name), address: text))
        }
        return result.sorted { lhs, rhs in
            let lhsPreferred = lhs.name.hasPrefix("en")
            let rhsPreferred = rhs.name.hasPrefix("en")
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.name < rhs.name
        }
    }

    /// LAN addresses (Tailscale's CGNAT range excluded; it is reported separately).
    public static func localAddresses() -> [String] {
        var seen = Set<String>()
        return ipv4().map(\.address).filter { HostAddress.classify($0) == .local && seen.insert($0).inserted }
    }
}

/// Detects Tailscale through its CLI (prompt §7.1).
public enum TailscaleProbe {
    public static let appCLIPath = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    public static func cliCandidates(path: String?) -> [String] {
        var candidates = [appCLIPath]
        for directory in (path ?? "").split(separator: ":") {
            candidates.append("\(directory)/tailscale")
        }
        candidates += ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/usr/bin/tailscale"]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    public static func locateCLI(path: String?) -> String? {
        cliCandidates(path: path).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `tailscale status --json` and interprets it.
    public static func status(environment: [String: String]) async -> TailscaleStatus {
        guard let cli = locateCLI(path: environment["PATH"]) else {
            return FileManager.default.fileExists(atPath: "/Applications/Tailscale.app")
                ? TailscaleStatus(installed: true, running: false, backendState: "NoCLI")
                : .notInstalled
        }
        guard
            let output = try? await ChildProcess.runToCompletion(
                executable: cli, arguments: ["status", "--json"], environment: environment, timeout: 8
            ),
            !output.stdout.isEmpty
        else {
            return TailscaleStatus(installed: true, running: false, backendState: "Unavailable")
        }
        return parse(output.stdout)
    }

    /// Parses `tailscale status --json` (stable fields only).
    public static func parse(_ data: Data) -> TailscaleStatus {
        guard let value = try? JSONValue.parse(data) else {
            return TailscaleStatus(installed: true, running: false, backendState: "Unavailable")
        }
        let backend = value["BackendState"]?.stringValue
        let running = backend == "Running"
        let ips = (value["Self"]?["TailscaleIPs"]?.arrayValue ?? []).compactMap(\.stringValue)
        var dnsName = value["Self"]?["DNSName"]?.stringValue
        if dnsName?.hasSuffix(".") == true { dnsName?.removeLast() }
        if dnsName?.isEmpty == true { dnsName = nil }
        let tailnet = value["CurrentTailnet"]?["Name"]?.stringValue
        let magicDNSEnabled = value["CurrentTailnet"]?["MagicDNSEnabled"]?.boolValue
            ?? (value["MagicDNSSuffix"]?.stringValue.map { !$0.isEmpty } ?? false)
        return TailscaleStatus(
            installed: true,
            running: running,
            backendState: backend,
            ipv4: ips.first { !$0.contains(":") },
            ipv6: ips.first { $0.contains(":") },
            magicDNSName: magicDNSEnabled ? dnsName : nil,
            tailnetName: tailnet,
            magicDNSEnabled: magicDNSEnabled
        )
    }
}
