import PilothouseKit
import SwiftUI

/// Settings (prompt §6.2.5).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var macToUnpair: PairedMac?
    @State private var showTailscaleGuide = false
    @State private var confirmClearCache = false

    var body: some View {
        @Bindable var preferences = model.preferences
        NavigationStack {
            Form {
                macsSection
                if let status = model.connection?.status, model.connection?.isConnected == true {
                    statusSection(status)
                }
                Section {
                    Picker("Connect via", selection: $preferences.connectionPreference) {
                        Text("Automatic").tag(ConnectionPreference.automatic)
                        Text("Local network only").tag(ConnectionPreference.localOnly)
                        Text("Tailscale only").tag(ConnectionPreference.tailscaleOnly)
                    }
                    Button("Set Up Remote Access (Tailscale)") { showTailscaleGuide = true }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Automatic tries the last working address, then your local network, then Tailscale.")
                }
                .onChange(of: preferences.connectionPreference) { _, preference in
                    model.connection?.setPreference(preference)
                }

                Section {
                    Picker("Model", selection: $preferences.defaultModel) {
                        Text("Mac default").tag("")
                        ForEach(UserPreferences.modelSuggestions.filter { !$0.isEmpty }, id: \.self) { name in
                            Text(name.capitalized).tag(name)
                        }
                    }
                    Picker("Permissions", selection: $preferences.defaultPermissionMode) {
                        ForEach(PermissionMode.standardModes, id: \.self) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                } header: {
                    Text("New chats")
                }

                Section {
                    Picker("Appearance", selection: $preferences.appearance) {
                        Text("System").tag(UserPreferences.Appearance.system)
                        Text("Light").tag(UserPreferences.Appearance.light)
                        Text("Dark").tag(UserPreferences.Appearance.dark)
                    }
                    Toggle("Haptic feedback", isOn: $preferences.hapticsEnabled)
                } header: {
                    Text("Appearance")
                }

                Section {
                    Toggle("Demo mode", isOn: Binding(
                        get: { model.preferences.demoMode },
                        set: { enabled in Task { await model.setDemoMode(enabled) } }
                    ))
                    .accessibilityIdentifier("demoModeToggle")
                } footer: {
                    Text("Explore Pilothouse with a simulated Mac. Nothing is sent anywhere and no Mac is needed.")
                }

                aboutSection
            }
            .navigationTitle(Text("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showTailscaleGuide) { TailscaleGuideView() }
            .confirmationDialog(
                Text("Remove this Mac?"),
                isPresented: Binding(get: { macToUnpair != nil }, set: { if !$0 { macToUnpair = nil } }),
                titleVisibility: .visible,
                presenting: macToUnpair
            ) { mac in
                Button("Remove \(mac.name)", role: .destructive) {
                    Task { await model.unpair(mac) }
                }
            } message: { _ in
                Text("This device forgets the Mac and its cached transcripts. To block this device on the Mac too, revoke it in the Pilothouse menu on the Mac.")
            }
            .confirmationDialog(Text("Clear cached transcripts?"), isPresented: $confirmClearCache, titleVisibility: .visible) {
                Button("Clear Cache", role: .destructive) { model.clearCache() }
            } message: {
                Text("Transcripts stay on your Mac and are downloaded again when you open a session.")
            }
        }
    }

    private var macsSection: some View {
        Section {
            ForEach(model.store.macs) { mac in
                Button {
                    Task { await model.switchToMac(mac.id) }
                } label: {
                    HStack {
                        Image(systemName: "laptopcomputer")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: mac.name).foregroundStyle(.primary)
                            Text(verbatim: model.verificationCode(for: mac))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !model.preferences.demoMode && model.activeMac?.id == mac.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel(Text("Active"))
                        }
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { macToUnpair = mac }
                }
                .contextMenu {
                    Button("Remove", systemImage: "trash", role: .destructive) { macToUnpair = mac }
                }
            }
            Button {
                dismiss()
                model.isPresentingPairing = true
            } label: {
                Label("Pair Another Mac", systemImage: "qrcode.viewfinder")
            }
        } header: {
            Text("Macs")
        }
    }

    private func statusSection(_ status: MacStatus) -> some View {
        Section {
            LabeledContent("Claude Code", value: status.claude.version ?? String(localized: "Not installed"))
            if status.claude.loggedIn == false {
                Label("Claude Code is not signed in on the Mac. Run `claude` in Terminal there.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            LabeledContent("Keeps Mac awake") {
                status.sleepPrevented ? Text("Yes") : Text("No")
            }
            LabeledContent("Tailscale") {
                Text(verbatim: status.tailscale.running ? (status.tailscale.magicDNSName ?? status.tailscale.ipv4 ?? "") : "—")
            }
            if let route = model.connection?.route {
                LabeledContent("Connected via") { Text(route.localizedName) }
            }
        } header: {
            Text("This Mac")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            if let url = URL(string: "https://github.com/ardasnturk/pilot-house") {
                Link(destination: url) {
                    Label("Source Code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            NavigationLink {
                LicensesView()
            } label: {
                Label("Licenses", systemImage: "doc.text")
            }
            Button("Clear Cached Transcripts", role: .destructive) { confirmClearCache = true }
        } header: {
            Text("About")
        } footer: {
            Text("Pilothouse works with Claude Code. It is an independent open-source project and is not affiliated with Anthropic. Pilothouse collects no data.")
        }
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pilothouse").font(.headline)
                Text(verbatim: Self.mit)
                    .font(.footnote.monospaced())
                Text("Third-party software").font(.headline)
                Text("Pilothouse uses no third-party libraries. Encryption is provided by Apple CryptoKit and follows the public-domain Noise Protocol Framework specification.")
                    .font(.footnote)
            }
            .padding()
        }
        .navigationTitle(Text("Licenses"))
    }

    static let mit = """
        MIT License

        Copyright (c) 2026 Arda Şentürk and the Pilothouse contributors

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """
}
