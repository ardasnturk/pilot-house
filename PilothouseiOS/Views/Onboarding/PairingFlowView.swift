import PilothouseKit
import SwiftUI
import VisionKit

/// Scan (or paste) the QR code shown by the Mac, then pair (prompt §5.2, §6.2.1).
struct PairingFlowView: View {
    let initialLink: String?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .scan
    @State private var pastedLink = ""

    enum Step: Equatable {
        case scan
        case paste
        case pairing
        case success(PairedMac)
        case failure(String, showsSettings: Bool)
    }

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            content
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GradientBackground())
                .navigationTitle(Text("Pair with Your Mac"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .task {
            model.requestLocalNetworkAccess()
            if let initialLink {
                pair(initialLink)
            } else if !scannerAvailable {
                step = .paste
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .scan:
            VStack(spacing: 20) {
                Text("Open Pilothouse on your Mac, choose “Pair New Device…” and point the camera at the QR code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                QRScannerView { code in pair(code) }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .frame(maxHeight: 420)
                    .accessibilityLabel(Text("Camera viewfinder for the pairing QR code"))
                Text("The camera is only used to read the pairing code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Paste a Pairing Link Instead") { step = .paste }
            }
        case .paste:
            VStack(alignment: .leading, spacing: 16) {
                Text("On your Mac, click “Copy Link” in the pairing window and paste it here (for example via Universal Clipboard).")
                    .foregroundStyle(.secondary)
                TextField("pilothouse://pair?d=…", text: $pastedLink, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                    .lineLimit(3...6)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("pairingLinkField")
                HStack {
                    Button {
                        pastedLink = UIPasteboard.general.string ?? pastedLink
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    Spacer()
                    Button("Pair") { pair(pastedLink) }
                        .buttonStyle(.borderedProminent)
                        .disabled(pastedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("confirmPairButton")
                }
                if scannerAvailable {
                    Button("Scan the QR Code Instead") { step = .scan }
                }
                Spacer()
            }
        case .pairing:
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Connecting to your Mac…")
                Text("If iOS asks for Local Network access, allow it so Pilothouse can find your Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .success(let mac):
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Paired with \(mac.name)")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                VStack(spacing: 4) {
                    Text("Verification code")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(model.verificationCode(for: mac))
                        .font(.title3.monospaced())
                    Text("It matches the code in the pairing window on your Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Start Using Pilothouse") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        case .failure(let message, let showsSettings):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Pairing failed").font(.title2.bold())
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Try Again") { step = scannerAvailable ? .scan : .paste }
                    .buttonStyle(.borderedProminent)
                if showsSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    private func pair(_ link: String) {
        guard step != .pairing else { return }
        step = .pairing
        Task {
            do {
                let mac = try await model.pair(link: link)
                Haptics.success()
                step = .success(mac)
            } catch {
                step = .failure(Self.message(for: error), showsSettings: error as? MacClientError == .localNetworkDenied)
            }
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case let error as ErrorPayload:
            return error.message
        case is PairingPayload.ParseError:
            return String(localized: "This is not a valid Pilothouse pairing code.")
        case MacClientError.localNetworkDenied:
            return String(localized: "Pilothouse is not allowed to use the local network, so it cannot reach your Mac on this Wi-Fi. Turn on Local Network for Pilothouse in Settings, then try again.")
        case MacClientError.unreachable:
            return String(localized: "Could not reach your Mac. Make sure Pilothouse is running on it and both devices are on the same network (or connected to Tailscale). Check Settings → Pilothouse → Local Network.")
        case let error as HandshakeError:
            return error.description
        default:
            return error.localizedDescription
        }
    }
}

/// VisionKit live QR scanner.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item,
                    let value = barcode.payloadStringValue,
                    value.lowercased().hasPrefix("\(PairingPayload.scheme)://")
                {
                    delivered = true
                    dataScanner.stopScanning()
                    onCode(value)
                    return
                }
            }
        }
    }
}
