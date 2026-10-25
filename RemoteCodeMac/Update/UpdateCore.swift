import Foundation

// Pure, dependency-free parts of the updater: version comparison, GitHub
// release parsing and `.sha256` file parsing. Kept free of AppKit and of the
// network so it can be checked in isolation (see AppUpdater.swift).

/// A dotted numeric version such as `1.10.0`, compared component by component.
/// A leading `v` and any pre-release / build suffix (`-beta.1`, `+42`) are ignored.
struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let components: [Int]

    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let suffix = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[..<suffix])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        components = numbers
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    /// Missing components count as zero, so `1.2 == 1.2.0`.
    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

/// A published release that carries a Mac DMG.
struct Release: Equatable, Sendable, Identifiable {
    var id: String { tagName }
    let version: SemanticVersion
    let tagName: String
    let name: String
    /// Markdown body of the GitHub release (release notes).
    let notes: String
    let pageURL: URL
    let dmgName: String
    let dmgURL: URL
    let dmgSize: Int?
    let checksumURL: URL
    let publishedAt: Date?
}

enum ReleaseParseError: Error, Equatable {
    case malformed
    case draftOrPrerelease
    case invalidVersion(String)
    case missingAsset(String)
}

enum ReleaseParser {
    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int?
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
        let published_at: String?
        let assets: [Asset]
    }

    /// Parses the JSON of `GET /repos/{owner}/{repo}/releases/latest`.
    /// Drafts and pre-releases are rejected; the release must carry
    /// `RemoteCode-<version>.dmg` and `RemoteCode-<version>.dmg.sha256`.
    static func parse(_ data: Data, appName: String = "RemoteCode") throws -> Release {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ReleaseParseError.malformed
        }
        if payload.draft == true || payload.prerelease == true { throw ReleaseParseError.draftOrPrerelease }
        guard let version = SemanticVersion(payload.tag_name) else {
            throw ReleaseParseError.invalidVersion(payload.tag_name)
        }
        let versionText = versionString(fromTag: payload.tag_name)
        let dmgName = "\(appName)-\(versionText).dmg"
        let checksumName = dmgName + ".sha256"
        // Prefer the exact name; accept any single `<appName>-*.dmg` as a fallback.
        let dmg = payload.assets.first { $0.name == dmgName }
            ?? payload.assets.first { $0.name.hasPrefix(appName + "-") && $0.name.hasSuffix(".dmg") }
        guard let dmg else { throw ReleaseParseError.missingAsset(dmgName) }
        guard let checksum = payload.assets.first(where: { $0.name == dmg.name + ".sha256" })
            ?? payload.assets.first(where: { $0.name == checksumName }) else {
            throw ReleaseParseError.missingAsset(dmg.name + ".sha256")
        }
        let formatter = ISO8601DateFormatter()
        return Release(
            version: version,
            tagName: payload.tag_name,
            name: payload.name.flatMap { $0.isEmpty ? nil : $0 } ?? payload.tag_name,
            notes: payload.body ?? "",
            pageURL: payload.html_url,
            dmgName: dmg.name,
            dmgURL: dmg.browser_download_url,
            dmgSize: dmg.size,
            checksumURL: checksum.browser_download_url,
            publishedAt: payload.published_at.flatMap { formatter.date(from: $0) }
        )
    }

    /// `v1.2.3` → `1.2.3`.
    static func versionString(fromTag tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        return text
    }
}

enum ChecksumFile {
    /// Extracts the lowercase SHA-256 hex digest from a `shasum -a 256` line
    /// (`<hex>  RemoteCode-1.0.1.dmg` or `<hex>  dist/RemoteCode-1.0.1.dmg`).
    /// When `fileName` is given and several lines exist, the line naming that
    /// file (by last path component) wins.
    static func digest(from text: String, fileName: String? = nil) -> String? {
        var candidates: [(digest: String, name: String?)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = fields.first else { continue }
            let hex = first.lowercased()
            guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { continue }
            var name = fields.dropFirst().joined(separator: " ")
            if name.hasPrefix("*") { name.removeFirst() } // binary-mode marker
            candidates.append((hex, name.isEmpty ? nil : name))
        }
        if let fileName, candidates.count > 1,
           let match = candidates.first(where: { ($0.name as NSString?)?.lastPathComponent == fileName }) {
            return match.digest
        }
        return candidates.first?.digest
    }
}
