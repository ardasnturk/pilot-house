import SwiftUI

/// The one manual step on iOS for remote access (prompt §7.4).
struct TailscaleGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("At home, Pilothouse talks to your Mac over Wi-Fi. To reach it from anywhere, both devices join your private Tailscale network.")
                }
                Section {
                    GuideStep(number: 1, title: "On your Mac", detail: "Open the Pilothouse menu → Tailscale → “Set Up with Claude”. Claude installs and checks Tailscale for you; you only sign in.")
                    GuideStep(number: 2, title: "On this device", detail: "Install Tailscale from the App Store and sign in with the same account.")
                    Link(destination: URL(string: "https://apps.apple.com/app/tailscale/id1470499037") ?? URL(fileURLWithPath: "/")) {
                        Label("Get Tailscale on the App Store", systemImage: "arrow.down.app")
                    }
                    GuideStep(number: 3, title: "Done", detail: "Pilothouse learns your Mac's Tailscale address automatically and uses it whenever the local network is not available.")
                } header: {
                    Text("Three steps")
                } footer: {
                    Text("iOS does not let apps install or configure a VPN for you, so step 2 has to be done by hand.")
                }
                Section {
                    Text("Your traffic stays end-to-end encrypted by Pilothouse in addition to Tailscale's own encryption.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .gradientBackground(intensity: 0.6)
            .navigationTitle(Text("Remote Access"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct GuideStep: View {
    let number: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number, format: .number)
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
