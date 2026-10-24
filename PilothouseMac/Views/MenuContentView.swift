import PilothouseKit
import SwiftUI

/// Content of the menu bar window: a gradient header with the status, what
/// needs attention, one main action, then sessions and limits (D-104).
/// Addresses, devices, agents and Tailscale live in Settings.
struct MenuContentView: View {
    @Environment(AppController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    /// Measured height of the scrollable sections. The menu bar window sizes
    /// itself to the ideal size, and a bare ScrollView has none, so without an
    /// explicit height the sections collapse to nothing.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !controller.claude.installed || controller.claude.loggedIn == false {
                        claudeWarning
                    }
                    if !controller.pendingRequests.isEmpty {
                        approvals
                    }
                    updateBanner
                    primaryAction
                    sessionsSection
                    limitsSection
                    keepAwake
                }
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, 500))
            footer
        }
        .frame(width: 360)
        .background(BrandBackground(intensity: 0.8))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image("MenuBarIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pilothouse").font(.title3.weight(.bold))
                    Text(verbatim: controller.macName)
                        .font(.caption)
                        .opacity(0.85)
                }
                Spacer()
                StatusPill(text: statusText, color: statusColor)
            }
            if controller.phase == .running {
                HStack(spacing: 8) {
                    stat(value: controller.connectedDeviceIds.count, symbol: "iphone", label: Text("connected"))
                    stat(value: controller.activeSessions.count, symbol: "bolt.fill", label: Text("working"))
                    stat(value: controller.openSessions.count, symbol: "bubble.left.and.bubble.right.fill", label: Text("open chats"))
                }
            } else if case .failed(let message) = controller.phase {
                Text(message).font(.caption)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Brand.gradient)
    }

    private func stat(value: Int, symbol: String, label: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(verbatim: "\(value)").font(.headline.monospacedDigit())
            } icon: {
                Image(systemName: symbol).font(.caption)
            }
            label.font(.caption2).opacity(0.85)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var statusText: Text {
        switch controller.phase {
        case .starting: Text("Starting…")
        case .running: Text("Ready")
        case .failed: Text("Problem")
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
            HStack(spacing: 10) {
                IconBadge(symbol: "exclamationmark.triangle.fill", colors: [.orange, .red], size: 28)
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
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .glassCard()
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
        .glassCard()
    }

    /// Shown while a new release is available or being installed.
    @ViewBuilder private var updateBanner: some View {
        let updater = controller.updater
        switch updater.state {
        case .available, .downloading, .installing, .failed:
            if updater.availableRelease != nil {
                HStack(spacing: 10) {
                    IconBadge(symbol: "arrow.down.circle.fill", colors: [.green, Brand.teal], size: 28)
                    UpdateStatusView(updater: updater)
                        .font(.callout)
                }
                .glassCard()
            }
        default:
            EmptyView()
        }
    }

    /// Pairing when nothing is paired yet, otherwise a quieter "add device".
    @ViewBuilder private var primaryAction: some View {
        if controller.devices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your iPhone")
                    .font(.headline)
                Text("Install Pilothouse on your iPhone or iPad, then scan a pairing code from this Mac. Both need to be on the same Wi-Fi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    startPairing()
                } label: {
                    Label("Pair iPhone or iPad…", systemImage: "qrcode")
                }
                .buttonStyle(GradientButtonStyle())
                .disabled(controller.phase != .running)
                Button("How do I get the iPhone app?") { show(WindowID.iPhoneApp) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .glassCard()
        } else {
            HStack(spacing: 8) {
                Button {
                    startPairing()
                } label: {
                    Label("Pair Another Device…", systemImage: "qrcode")
                }
                .buttonStyle(GradientButtonStyle())
                .disabled(controller.phase != .running)
                Button {
                    show(WindowID.iPhoneApp)
                } label: {
                    Image(systemName: "iphone.and.arrow.forward")
                        .frame(width: 34, height: 34)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(Text("Get the iPhone app"))
                .accessibilityLabel(Text("Get the iPhone app"))
            }
        }
    }

    @ViewBuilder private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Chats")
            if controller.openSessions.isEmpty {
                Text("Start a chat from your iPhone or iPad. It runs here on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.openSessions.prefix(6)) { session in
                HStack(spacing: 10) {
                    IconBadge(
                        symbol: session.state.isBusy ? "bolt.fill" : "bubble.left.fill",
                        colors: session.state.isBusy ? [Brand.teal, Brand.indigo] : [.gray.opacity(0.7), .gray],
                        size: 24
                    )
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
        .glassCard()
    }

    @ViewBuilder private var limitsSection: some View {
        let known = controller.usageLimits.filter { !$0.windows.isEmpty }
        if !known.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Usage limits")
                ForEach(known) { limits in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: limits.agent.displayName)
                            .font(.callout.weight(.medium))
                        ForEach(limits.windows.prefix(3)) { window in
                            HStack(spacing: 8) {
                                Text(verbatim: LimitFormat.windowName(window))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .leading)
                                    .lineLimit(1)
                                UsageBar(fraction: window.usedPercent / 100)
                                Text(verbatim: "\(Int(window.usedPercent.rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 36, alignment: .trailing)
                            }
                            .help(LimitFormat.resetText(window))
                        }
                    }
                }
            }
            .glassCard()
        }
    }

    private var keepAwake: some View {
        @Bindable var settings = controller.settings
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                IconBadge(
                    symbol: controller.sleepAssertion.isActive ? "moon.zzz.fill" : "moon.zzz",
                    colors: [Brand.indigo, Brand.violet],
                    size: 24
                )
                VStack(alignment: .leading, spacing: 1) {
                    if controller.sleepAssertion.isActive {
                        Text("Mac stays awake")
                    } else {
                        Text("Sleep prevention is off")
                    }
                    Text("The display may still turn off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(isOn: $settings.keepAwakeWithLidClosed) {
                    Text("Lid closed")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(Text("Stay awake with the lid closed"))
                .onChange(of: settings.keepAwakeWithLidClosed) { _, _ in
                    Task { await controller.applySettings() }
                }
            }
            lidStatus
        }
        .font(.callout)
        .glassCard()
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

    private var footer: some View {
        HStack(spacing: 14) {
            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }
            Button {
                NSApp.activate()
                NSApp.orderFrontStandardAboutPanel(nil)
            } label: {
                Label("About", systemImage: "info.circle")
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Pilothouse", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func startPairing() {
        Task { await controller.createPairing() }
        show(WindowID.pairing)
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

/// Short labels for usage windows (menu and settings).
enum LimitFormat {
    static func windowName(_ window: LimitWindow) -> String {
        let base: String = switch window.durationMinutes {
        case 300?: String(localized: "5 h")
        case 10_080?: String(localized: "Week")
        case let minutes? where minutes % 1_440 == 0: String(localized: "\(minutes / 1_440) d")
        case let minutes? where minutes % 60 == 0: String(localized: "\(minutes / 60) h")
        default: window.key
        }
        return window.model.map { "\(base) · \($0)" } ?? base
    }

    static func resetText(_ window: LimitWindow) -> String {
        guard let resetsAt = window.resetsAt else { return "" }
        return String(localized: "Resets \(resetsAt.formatted(.relative(presentation: .named)))")
    }
}
