import PilothouseKit
import SwiftUI

/// First launch: what Pilothouse is and how to pair (prompt §6.2.1).
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showTailscaleGuide = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image("BrandMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text("Pilothouse")
                            .font(.largeTitle.bold())
                        Text("Drive Claude Code on your Mac from your iPhone or iPad.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        FeatureRow(symbol: "folder", title: "Pick any folder", detail: "Browse your Mac and start a Claude Code session where your project lives.")
                        FeatureRow(symbol: "text.bubble", title: "Follow along live", detail: "Watch replies, tool calls, file diffs and command output as they happen.")
                        FeatureRow(symbol: "hand.raised", title: "Stay in control", detail: "Approve or deny file edits and commands with one tap.")
                        FeatureRow(symbol: "lock.shield", title: "Private by design", detail: "End-to-end encrypted between your devices. No accounts, no cloud, no tracking.")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Before you start")
                            .font(.headline)
                        Text("Install the free Pilothouse app on your Mac and make sure Claude Code is installed and signed in there. Then choose “Pair New Device” in its menu bar icon.")
                            .foregroundStyle(.secondary)
                        Link(destination: URL(string: "https://github.com/ardasnturk/pilot-house#readme") ?? URL(fileURLWithPath: "/")) {
                            Label("Get Pilothouse for Mac", systemImage: "arrow.up.right.square")
                        }
                    }

                    VStack(spacing: 12) {
                        Button {
                            model.isPresentingPairing = true
                        } label: {
                            Label("Pair with Your Mac", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("pairButton")

                        Button {
                            Task { await model.setDemoMode(true) }
                        } label: {
                            Text("Try the Demo")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityIdentifier("demoButton")

                        Button("Away from home? Set up Tailscale") {
                            showTailscaleGuide = true
                        }
                        .font(.callout)
                    }
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .sheet(isPresented: $showTailscaleGuide) {
                TailscaleGuideView()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct FeatureRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
