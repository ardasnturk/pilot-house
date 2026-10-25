import PilothouseKit
import SwiftUI

/// First launch: what Remote Code is, the three steps to get going, then
/// pairing or the demo (D-107: plain, numbered guidance).
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image("BrandMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: Brand.indigo.opacity(0.3), radius: 12, y: 6)
                            .accessibilityHidden(true)
                        Text("Remote Code")
                            .font(.largeTitle.bold())
                        Text("Your coding agents run on your Mac. Remote Code lets you talk to them, follow every step and approve changes from your iPhone or iPad.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Get started in three steps")
                            .font(.headline)
                        StepRow(number: 1, title: "Install Remote Code on your Mac", detail: "Download it from the website and open it. A >_ icon appears in the menu bar at the top of the screen.")
                        StepRow(number: 2, title: "Have an agent ready on the Mac", detail: "Claude Code, Codex or Gemini CLI, installed and signed in once in Terminal. The Mac app tells you if something is missing.")
                        StepRow(number: 3, title: "Pair on the same Wi-Fi", detail: "On the Mac, click the >_ icon, choose “Pair iPhone or iPad…”, then tap the button below and scan the code.")
                        Link(destination: URL(string: "https://pilot.ardasnturk.com") ?? URL(fileURLWithPath: "/")) {
                            Label("Get Remote Code for Mac", systemImage: "arrow.up.right.square")
                                .font(.callout.weight(.medium))
                        }
                    }
                    .padding(18)
                    .glassCard(cornerRadius: 22)

                    VStack(spacing: 12) {
                        Button {
                            model.isPresentingPairing = true
                        } label: {
                            Label("Scan the Pairing Code", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(GradientButtonStyle())
                        .accessibilityIdentifier("pairButton")

                        Button {
                            Task { await model.setDemoMode(true) }
                        } label: {
                            Text("Try the Demo First")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityIdentifier("demoButton")
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        FeatureRow(symbol: "folder", title: "Pick any folder", detail: "Browse your Mac and start a chat where your project lives.")
                        FeatureRow(symbol: "text.bubble", title: "Follow along live", detail: "Watch replies, tool calls, file diffs and command output as they happen.")
                        FeatureRow(symbol: "hand.raised", title: "Stay in control", detail: "Approve or deny file edits and commands with one tap.")
                        FeatureRow(symbol: "lock.shield", title: "Private by design", detail: "End-to-end encrypted between your devices. No accounts, no cloud, no tracking.")
                    }
                    .padding(18)
                    .glassCard(cornerRadius: 22)
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(GradientBackground())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// A numbered step of the getting-started guide.
struct StepRow: View {
    let number: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Brand.bubbleGradient, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
                .foregroundStyle(Brand.bubbleGradient)
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
