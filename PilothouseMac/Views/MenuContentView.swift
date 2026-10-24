import PilothouseKit
import SwiftUI

/// Content of the menu bar window (prompt §4.2).
struct MenuContentView: View {
    @Environment(AppController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    /// Measured height of the scrollable sections. The menu bar window sizes
    /// itself to the ideal size, and a bare ScrollView has none, so without an
    /// explicit height the sections collapse to nothing.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !controller.claude.installed || controller.claude.loggedIn == false {
                        claudeWarning
                    }
                    if !controller.pendingRequests.isEmpty {
                        approvals
                    }
                    addresses
                    pairButton
                    keepAwake
                    sessionsSection
                    devicesSection
                    integrations
                }
                .padding(14)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, 520))
            Divider()
            footer
        }
        .frame(width: 360)
        .alert(
            Text("Pilothouse"),
            isPresented: Binding(get: { controller.alert != nil }, set: { if !$0 { controller.alert = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.alert ?? "")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image("MenuBarIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pilothouse").font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .accessibilityLabel(Text(statusLine))
        }
        .padding(14)
    }

    private var statusLine: String {
        switch controller.phase {
        case .starting:
            return String(localized: "Starting…")
        case .failed(let message):
            return message
        case .running:
            let devices = controller.devices.count
            let sessions = controller.activeSessions.count
            return String(localized: "Running · \(devices) paired devices · \(sessions) active sessions")
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .starting: .orange
        case .running: .green
        case .failed: .red
        }
    }

    private var claudeWarning: some View {
        Button {
            show(WindowID.claudeSetup)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if controller.claude.installed {
                            Text("Claude Code is not signed in")
                        } else {
                            Text("Claude Code is not installed")
                        }
                    }
                    .font(.callout.weight(.semibold))
                    Text("Click for setup instructions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var approvals: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Waiting for approval")
            ForEach(controller.pendingRequests) { request in
                PermissionApprovalRow(request: request)
            }
        }
    }

    private var addresses: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Connection addresses")
            if controller.reachableAddresses.isEmpty {
                Text("No network connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.reachableAddresses, id: \.self) { address in
                AddressRow(address: address, port: controller.port)
            }
        }
    }

    private var pairButton: some View {
        Button {
            Task { await controller.createPairing() }
            show(WindowID.pairing)
        } label: {
            Label("Pair New Device…", systemImage: "qrcode")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(controller.phase != .running)
    }

    private var keepAwake: some View {
        @Bindable var settings = controller.settings
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Keep awake")
            Label {
                if controller.sleepAssertion.isActive {
                    Text("Preventing system sleep (the display may still turn off)")
                } else {
                    Text("Sleep prevention is off")
                }
            } icon: {
                Image(systemName: controller.sleepAssertion.isActive ? "moon.zzz.fill" : "moon.zzz")
                    .foregroundStyle(controller.sleepAssertion.isActive ? Color.accentColor : .secondary)
            }
            .font(.callout)
            Toggle(isOn: $settings.keepAwakeWithLidClosed) {
                Text("Stay awake with the lid closed")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: settings.keepAwakeWithLidClosed) { _, _ in
                Task { await controller.applySettings() }
            }
            lidStatus
        }
    }

    @ViewBuilder private var lidStatus: some View {
        switch controller.lidClosed.state {
        case .off:
            EmptyView()
        case .active:
            Text("Lid-closed mode is on. Keep your Mac ventilated; it can get warm in a bag.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .pausedOnBattery:
            Text("Paused while on battery. It resumes on power.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .needsApproval:
            Button("Allow the Pilothouse helper in Login Items…") {
                controller.lidClosed.openApprovalSettings()
            }
            .font(.caption)
            .buttonStyle(.link)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Active sessions")
            if controller.openSessions.isEmpty {
                Text("Start a session from your iPhone or iPad.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.openSessions.prefix(8)) { session in
                HStack(spacing: 8) {
                    Image(systemName: session.state.isBusy ? "bolt.circle.fill" : "circle")
                        .foregroundStyle(session.state.isBusy ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title).lineLimit(1)
                        Text("\(session.cwd.abbreviatingHome) · \(session.state.localizedName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        Task { await controller.close(session) }
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("End this session"))
                    .accessibilityLabel(Text("End session \(session.title)"))
                }
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Paired devices")
            if controller.devices.isEmpty {
                Text("No devices paired yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.devices) { device in
                DeviceRow(device: device, isConnected: controller.connectedDeviceIds.contains(device.id)) {
                    Task { await controller.revoke(device) }
                }
            }
        }
    }

    private var integrations: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Integrations")
            Button {
                show(WindowID.claudeSetup)
            } label: {
                LabeledContent {
                    Text(controller.claude.version ?? String(localized: "Not found"))
                        .foregroundStyle(controller.claude.installed ? .secondary : Color.orange)
                } label: {
                    Label("Claude Code", systemImage: "terminal")
                }
            }
            .buttonStyle(.plain)
            Button {
                show(WindowID.tailscale)
            } label: {
                LabeledContent {
                    Text(tailscaleSummary)
                        .foregroundStyle(controller.tailscale.running ? .secondary : Color.orange)
                } label: {
                    Label("Tailscale", systemImage: "network")
                }
            }
            .buttonStyle(.plain)
            .help(Text("Set up remote access with Tailscale"))
        }
        .font(.callout)
    }

    private var tailscaleSummary: String {
        if controller.tailscale.running {
            return controller.tailscale.ipv4 ?? String(localized: "Connected")
        }
        return controller.tailscale.installed ? String(localized: "Not connected") : String(localized: "Not installed")
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Text("Settings…")
            }
            Button("About") {
                NSApp.activate()
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            Spacer()
            Button("Quit Pilothouse") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate()
    }
}

struct SectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}

struct AddressRow: View {
    let address: HostAddress
    let port: Int?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: address.kind == .local ? "wifi" : "lock.shield")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(address.host)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Text(kindName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(port.map { "\(address.host):\($0)" } ?? address.host, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(Text("Copy address"))
            .accessibilityLabel(Text("Copy \(address.host)"))
        }
    }

    private var kindName: String {
        switch address.kind {
        case .local: String(localized: "Local network")
        case .tailscale: String(localized: "Tailscale IP")
        case .magicDNS: String(localized: "MagicDNS name")
        }
    }
}

struct DeviceRow: View {
    let device: PairedDevice
    let isConnected: Bool
    let revoke: () -> Void
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.platform.lowercased().contains("ipad") ? "ipad" : "iphone")
                .foregroundStyle(isConnected ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Group {
                    if isConnected {
                        Text("Connected now")
                    } else if let seen = device.lastSeenAt {
                        Text("Last seen \(seen, style: .relative) ago")
                    } else {
                        Text("Never connected")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) {
                confirming = true
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .confirmationDialog(Text("Revoke \(device.name)?"), isPresented: $confirming) {
            Button("Revoke", role: .destructive, action: revoke)
        } message: {
            Text("The device is disconnected immediately and has to pair again to reconnect.")
        }
    }
}
