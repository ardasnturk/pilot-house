import PilothouseKit
import SwiftData
import SwiftUI

@main
struct PilothouseApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(colorScheme)
                .onOpenURL { url in
                    if url.scheme == PairingPayload.scheme {
                        model.incomingPairingLink = url.absoluteString
                        model.isPresentingPairing = true
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    model.scenePhaseChanged(phase)
                }
                .onChange(of: model.preferences.hapticsEnabled, initial: true) { _, enabled in
                    Haptics.isEnabled = enabled
                }
                .transaction { transaction in
                    if model.launch.isUITesting { transaction.disablesAnimations = true }
                }
        }
        .modelContainer(model.cache.container)
    }

    private var colorScheme: ColorScheme? {
        switch model.preferences.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Onboarding until a Mac is paired, then the session browser.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let error = model.identityError {
                ContentUnavailableView {
                    Label("Keychain unavailable", systemImage: "key.slash")
                } description: {
                    Text(error)
                }
            } else if model.hasPairedMac {
                MainSplitView()
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $model.isPresentingPairing) {
            PairingFlowView(initialLink: model.incomingPairingLink)
                .onDisappear { model.incomingPairingLink = nil }
        }
        .task {
            model.connect()
        }
    }
}
