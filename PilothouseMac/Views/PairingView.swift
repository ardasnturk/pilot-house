import PilothouseKit
import SwiftUI

/// Shows the one-time pairing QR code (prompt §5.2).
struct PairingView: View {
    @Environment(AppController.self) private var controller
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 18) {
            if let device = controller.newlyPairedDevice {
                success(device)
            } else if let pairing = controller.pairing {
                invitation(pairing)
            } else {
                ProgressView()
                    .frame(width: 280, height: 280)
                    .task { await controller.createPairing() }
            }
        }
        .padding(28)
        .frame(width: 420)
        .onDisappear {
            Task { await controller.endPairing() }
        }
    }

    private func invitation(_ pairing: AppController.PairingInvitation) -> some View {
        VStack(spacing: 16) {
            Text("Scan with Remote Code on your iPhone or iPad")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Group {
                if let image = pairing.image {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "qrcode").font(.system(size: 120))
                }
            }
            .frame(width: 260, height: 260)
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel(Text("Pairing QR code"))

            Button("No Remote Code on your iPhone yet? Get the app") {
                openWindow(id: WindowID.iPhoneApp)
            }
            .buttonStyle(.link)
            .font(.callout)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(pairing.payload.expiresAt.timeIntervalSince(context.date)))
                if remaining > 0 {
                    Text("Valid for \(remaining / 60):\(String(format: "%02d", remaining % 60)) · single use")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Button("Code expired — create a new one") {
                        Task { await controller.createPairing() }
                    }
                }
            }

            VStack(spacing: 4) {
                Text("Verification code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(pairing.verificationCode)
                    .font(.title3.monospaced().weight(.medium))
                    .textSelection(.enabled)
                Text("The same code appears on your phone after pairing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pairing.link, forType: .string)
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
                Button {
                    Task { await controller.createPairing() }
                } label: {
                    Label("New Code", systemImage: "arrow.clockwise")
                }
            }

            if pairing.payload.ts.isEmpty {
                Text("Tip: set up Tailscale to reach this Mac away from home.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func success(_ device: PairedDevice) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("\(device.name) is paired")
                .font(.title2.weight(.semibold))
            Text("You can now start Claude Code sessions on this Mac from your device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Done") {
                dismissWindow(id: WindowID.pairing)
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(height: 360)
    }
}
