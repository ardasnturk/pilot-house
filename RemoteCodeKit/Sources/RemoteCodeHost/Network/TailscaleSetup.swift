import Foundation
import RemoteCodeKit

/// Tailscale setup assistant logic (prompt §7), independent of the UI.
public enum TailscaleSetup {
    /// Where the Mac stands on the way to remote access.
    public enum Stage: Sendable, Equatable {
        case notInstalled
        /// Installed but the CLI cannot be found (App Store build without CLI).
        case installedWithoutCLI
        /// Installed, but logged out, stopped or still starting.
        case notConnected(backendState: String?)
        /// Connected; MagicDNS may be off.
        case connected(ipv4: String?, magicDNSName: String?, magicDNSEnabled: Bool)

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    public static func stage(of status: TailscaleStatus) -> Stage {
        guard status.installed else { return .notInstalled }
        if status.backendState == "NoCLI" { return .installedWithoutCLI }
        guard status.running else { return .notConnected(backendState: status.backendState) }
        return .connected(ipv4: status.ipv4, magicDNSName: status.magicDNSName, magicDNSEnabled: status.magicDNSEnabled)
    }

    /// The instruction Claude receives when the user clicks "Set up with Claude"
    /// (prompt §7.2), in the user's language when available (EN/TR/DE).
    public static func claudePrompt(languageCode: String?) -> String {
        switch languageCode?.prefix(2) {
        case "tr": turkishPrompt
        case "de": germanPrompt
        default: englishPrompt
        }
    }

    static let turkishPrompt = """
        Bu Mac'te Tailscale'i kurmama ve uzaktan erişim için yapılandırmama yardım et.
        1. Tailscale kurulu mu kontrol et. Değilse resmi kaynaktan (Homebrew cask "tailscale"
           veya tailscale.com'daki resmi paket) kur. Hangi yolu seçtiğini açıkla.
        2. Yönetici şifresi veya tarayıcıda giriş gerektiren adımlarda dur ve bana tam olarak
           ne yapmam gerektiğini söyle.
        3. Giriş tamamlandıktan sonra `tailscale status` ve `tailscale ip -4` ile bağlantıyı doğrula.
        4. MagicDNS açık mı kontrol et ve Mac'in MagicDNS adını yaz.
        5. Sistem ayarlarında gereksiz hiçbir değişiklik yapma. Sonunda yaptıklarının kısa bir özetini ver.
        """

    static let englishPrompt = """
        Help me install Tailscale on this Mac and set it up for remote access.
        1. Check whether Tailscale is installed. If not, install it from an official source (the Homebrew
           cask "tailscale" or the official package from tailscale.com). Explain which route you chose.
        2. For any step that needs an administrator password or a sign-in in the browser, stop and tell me
           exactly what I need to do.
        3. After I have signed in, verify the connection with `tailscale status` and `tailscale ip -4`.
        4. Check whether MagicDNS is enabled and write down this Mac's MagicDNS name.
        5. Do not make any unnecessary changes to system settings. Finish with a short summary of what you did.
        """

    static let germanPrompt = """
        Hilf mir, Tailscale auf diesem Mac zu installieren und für den Fernzugriff einzurichten.
        1. Prüfe, ob Tailscale installiert ist. Falls nicht, installiere es aus einer offiziellen Quelle
           (Homebrew-Cask "tailscale" oder das offizielle Paket von tailscale.com). Erkläre, welchen Weg du wählst.
        2. Halte bei Schritten an, die ein Administratorpasswort oder eine Anmeldung im Browser erfordern,
           und sag mir genau, was ich tun muss.
        3. Prüfe nach der Anmeldung die Verbindung mit `tailscale status` und `tailscale ip -4`.
        4. Prüfe, ob MagicDNS aktiviert ist, und notiere den MagicDNS-Namen dieses Macs.
        5. Nimm keine unnötigen Änderungen an den Systemeinstellungen vor. Gib am Ende eine kurze Zusammenfassung.
        """

    /// One step of the manual guide (prompt §7.5).
    public struct ManualStep: Sendable, Hashable, Identifiable {
        public var id: Int
        public var title: String
        public var detail: String
        public var command: String?
        public var link: String?
    }

    /// Manual setup steps in English; the Mac app localises titles and details by key.
    public static let manualSteps: [ManualStep] = [
        ManualStep(
            id: 1,
            title: "Install Tailscale",
            detail: "Download Tailscale for macOS from tailscale.com, or install it with Homebrew.",
            command: "brew install --cask tailscale",
            link: "https://tailscale.com/download/mac"
        ),
        ManualStep(
            id: 2,
            title: "Open Tailscale and sign in",
            detail: "Start Tailscale from Applications, allow its VPN configuration when macOS asks, then log in from its menu bar icon.",
            command: nil,
            link: nil
        ),
        ManualStep(
            id: 3,
            title: "Turn on MagicDNS (recommended)",
            detail: "In the Tailscale admin console under DNS, enable MagicDNS so your Mac gets a stable name.",
            command: nil,
            link: "https://login.tailscale.com/admin/dns"
        ),
        ManualStep(
            id: 4,
            title: "Check the connection",
            detail: "Remote Code detects Tailscale automatically. You can also check it in Terminal.",
            command: "tailscale status && tailscale ip -4",
            link: nil
        ),
        ManualStep(
            id: 5,
            title: "Install Tailscale on your iPhone or iPad",
            detail: "Get Tailscale from the App Store and sign in with the same account. iOS does not allow apps to do this for you.",
            command: nil,
            link: "https://apps.apple.com/app/tailscale/id1470499037"
        ),
    ]
}
