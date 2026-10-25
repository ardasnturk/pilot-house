import Foundation
import RemoteCodeKit
import Testing
@testable import RemoteCodeHost

@Suite struct TailscaleSetupTests {
    @Test func stages() {
        #expect(TailscaleSetup.stage(of: .notInstalled) == .notInstalled)
        #expect(TailscaleSetup.stage(of: TailscaleStatus(installed: true, running: false, backendState: "NoCLI")) == .installedWithoutCLI)
        #expect(TailscaleSetup.stage(of: TailscaleStatus(installed: true, running: false, backendState: "NeedsLogin")) == .notConnected(backendState: "NeedsLogin"))
        let connected = TailscaleSetup.stage(of: TailscaleStatus(
            installed: true, running: true, backendState: "Running", ipv4: "100.64.0.9", magicDNSName: "mac.tail.ts.net", magicDNSEnabled: true
        ))
        #expect(connected == .connected(ipv4: "100.64.0.9", magicDNSName: "mac.tail.ts.net", magicDNSEnabled: true))
        #expect(connected.isConnected)
    }

    @Test func promptFollowsTheSpecification() {
        let turkish = TailscaleSetup.claudePrompt(languageCode: "tr-TR")
        #expect(turkish.hasPrefix("Bu Mac'te Tailscale'i kurmama ve uzaktan erişim için yapılandırmama yardım et."))
        #expect(turkish.contains("`tailscale status` ve `tailscale ip -4`"))
        #expect(turkish.contains("Sistem ayarlarında gereksiz hiçbir değişiklik yapma."))
        for language in [nil, "en", "de", "fr"] {
            let prompt = TailscaleSetup.claudePrompt(languageCode: language)
            #expect(prompt.contains("tailscale ip -4"))
            #expect(prompt.contains("MagicDNS"))
            #expect(prompt.split(separator: "\n").filter { $0.first?.isNumber == true }.count == 5)
        }
        #expect(TailscaleSetup.claudePrompt(languageCode: "de").hasPrefix("Hilf mir"))
        #expect(TailscaleSetup.claudePrompt(languageCode: "fr").hasPrefix("Help me"))
    }

    @Test func manualGuideCoversBothDevices() {
        let steps = TailscaleSetup.manualSteps
        #expect(steps.map(\.id) == [1, 2, 3, 4, 5])
        #expect(steps.contains { $0.command == "brew install --cask tailscale" })
        #expect(steps.last?.link?.contains("apps.apple.com") == true)
    }
}
