import RemoteCodeHost
import RemoteCodeKit
import SwiftUI

/// Tailscale setup assistant (prompt §7): detects Tailscale, lets Claude set
/// it up (observable from the phone too), or walks through a manual guide.
struct TailscaleAssistantView: View {
    @Environment(AppController.self) private var controller
    @State private var showManualGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            switch controller.tailscaleStage {
            case .connected(let ipv4, let magicDNSName, let magicDNSEnabled):
                connected(ipv4: ipv4, magicDNSName: magicDNSName, magicDNSEnabled: magicDNSEnabled)
            default:
                setupOptions
            }
            if let sessionId = controller.tailscaleSetupSessionId {
                Divider()
                Text("Claude is setting up Tailscale")
                    .font(.headline)
                Text("You can also follow and approve this session on your iPhone or iPad.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SessionMonitorView(sessionId: sessionId)
            }
            if showManualGuide {
                Divider()
                ManualGuide()
            }
        }
        .padding(24)
        .frame(width: 600)
        .frame(minHeight: 360, alignment: .top)
        .task { await controller.watchTailscale() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remote access with Tailscale").font(.title2.weight(.semibold))
                Text("Reach this Mac from anywhere over your private Tailscale network. Remote Code keeps its own end-to-end encryption on top.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stageDescription: Text {
        switch controller.tailscaleStage {
        case .notInstalled: Text("Tailscale is not installed on this Mac.")
        case .installedWithoutCLI: Text("Tailscale is installed, but its command-line tool was not found. Open Tailscale once, or enable its CLI in Tailscale's settings.")
        case .notConnected(let state): Text("Tailscale is installed but not connected (\(state ?? "—")).")
        case .connected: Text("Connected.")
        }
    }

    private var setupOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                stageDescription
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Button {
                    Task { await controller.startTailscaleSetup() }
                } label: {
                    Label("Set Up with Claude", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!controller.claude.installed || controller.tailscaleSetupSessionId != nil)

                Button {
                    showManualGuide.toggle()
                } label: {
                    if showManualGuide {
                        Text("Hide Manual Steps")
                    } else {
                        Text("Set Up Manually")
                    }
                }
                .controlSize(.large)

                Button {
                    Task { await controller.refreshNetwork() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
            }
            if !controller.claude.installed {
                Text("Install Claude Code first to let Claude do the setup, or follow the manual steps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Claude installs Tailscale from an official source and stops whenever your password or a browser sign-in is needed. Every command needs your approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func connected(ipv4: String?, magicDNSName: String?, magicDNSEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Tailscale is connected", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            if let ipv4 {
                LabeledContent("Tailscale IP") { Text(verbatim: ipv4).textSelection(.enabled).monospaced() }
            }
            if let magicDNSName {
                LabeledContent("MagicDNS name") { Text(verbatim: magicDNSName).textSelection(.enabled).monospaced() }
            } else if !magicDNSEnabled {
                Text("MagicDNS is off. Turn it on in the Tailscale admin console for a stable name (optional).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Paired devices learn this address automatically. On your iPhone or iPad, install Tailscale from the App Store and sign in with the same account — iOS does not let apps do this for you.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Step-by-step manual setup (prompt §7.5).
private struct ManualGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(TailscaleSetup.manualSteps) { step in
                HStack(alignment: .top, spacing: 12) {
                    Text(verbatim: "\(step.id)")
                        .font(.headline)
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedStringKey(step.title)).font(.headline)
                        Text(LocalizedStringKey(step.detail))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let command = step.command {
                            CommandBox(command: command)
                        }
                        if let link = step.link, let url = URL(string: link) {
                            Link(destination: url) {
                                Text(verbatim: link).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }
}
