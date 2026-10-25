import AppKit
import SwiftUI

/// Public links shown by the Mac app.
enum AppLinks {
    /// Public TestFlight link of the iPhone and iPad app.
    static let testFlight = URL(string: "https://testflight.apple.com/join/6CE4VRRE")!
    static let website = URL(string: "https://rcode.ardasnturk.com")!
}

/// Whether the public TestFlight link takes new testers yet. Until Apple's
/// beta review is through, its page says it "isn't accepting any new
/// testers"; the QR code is only shown once it does.
enum TestFlightAvailability {
    static func isOpen() async -> Bool {
        var request = URLRequest(url: AppLinks.testFlight, timeoutInterval: 10)
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return false }
        let page = String(decoding: data, as: UTF8.self)
        return !page.contains("accepting any new testers") && !page.contains("This beta is full")
    }
}

/// "Get Remote Code for iPhone": the TestFlight QR code, shown on first launch
/// and from the menu, so the phone app can be installed without searching.
struct GetIPhoneAppView: View {
    @Environment(AppController.self) private var controller
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var copied = false
    /// `nil` while checking the TestFlight link.
    @State private var isOpen: Bool?

    var body: some View {
        Group {
            switch isOpen {
            case nil:
                ProgressView()
                    .frame(width: 440, height: 300)
            case false?:
                comingSoon
            case true?:
                available
            }
        }
        .task { isOpen = await TestFlightAvailability.isOpen() }
    }

    private var comingSoon: some View {
        VStack(spacing: 14) {
            Image(systemName: "hourglass")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("The iPhone app is almost here")
                .font(.title2.weight(.semibold))
            Text("Remote Code for iPhone and iPad is waiting for Apple's beta review. As soon as TestFlight accepts testers, the QR code to install it appears here and on the website.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Link(destination: AppLinks.website) {
                    Text("Open the Website")
                }
                Spacer()
                Button("Check Again") {
                    isOpen = nil
                    Task { isOpen = await TestFlightAvailability.isOpen() }
                }
            }
        }
        .padding(28)
        .frame(width: 440)
    }

    private var available: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Get Remote Code for iPhone and iPad")
                    .font(.title2.weight(.semibold))
                Text("Scan the code with your iPhone's camera to install the app with TestFlight, Apple's free app for beta apps.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let image = QRCode.image(for: AppLinks.testFlight.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel(Text("QR code for the TestFlight link"))
            }
            VStack(alignment: .leading, spacing: 8) {
                step(1, LocalizedStringKey("Scan the code, or open the link on your iPhone or iPad."))
                step(2, LocalizedStringKey("Install TestFlight if asked, then tap Install for Remote Code."))
                step(3, LocalizedStringKey("Come back here and choose Pair New Device…"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppLinks.testFlight.absoluteString, forType: .string)
                    copied = true
                } label: {
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                    } else {
                        Label("Copy Link", systemImage: "doc.on.doc")
                    }
                }
                Spacer()
                Button("Pair New Device…") {
                    Task { await controller.createPairing() }
                    dismissWindow(id: WindowID.iPhoneApp)
                    openWindow(id: WindowID.pairing)
                    NSApp.activate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.phase != .running)
            }
        }
        .padding(28)
        .frame(width: 440)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
