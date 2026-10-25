import PilothouseKit
import SwiftUI

/// Explains how to install and sign in to Claude Code (prompt §4.4).
/// Remote Code never signs in on the user's behalf.
struct ClaudeSetupView: View {
    @Environment(AppController.self) private var controller

    private let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Claude Code").font(.title2.weight(.semibold))
                    statusText
                }
            }

            if !controller.claude.installed {
                step(1, title: "Install Claude Code", detail: "Open Terminal and run the official installer, or follow the setup guide.") {
                    CommandBox(command: installCommand)
                    if let url = AppInfo.claudeCodeSetupURL {
                        Link("Open the Claude Code setup guide", destination: url)
                    }
                }
            }
            step(controller.claude.installed ? 1 : 2, title: "Sign in once in Terminal", detail: "Run `claude` and follow the prompts to sign in with your Claude account (or set up an API key). Remote Code never sees your credentials.") {
                CommandBox(command: "claude")
            }
            step(controller.claude.installed ? 2 : 3, title: "Check again", detail: "Remote Code looks in your login shell's PATH, ~/.local/bin, /opt/homebrew/bin and /usr/local/bin.") {
                Button {
                    Task { await controller.refreshClaude() }
                } label: {
                    if controller.isCheckingClaude {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check Again", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder private var statusText: some View {
        if let version = controller.claude.version, let path = controller.claude.path {
            VStack(alignment: .leading, spacing: 2) {
                Text("Installed: \(version)")
                Text(path.abbreviatingHome).font(.caption.monospaced()).foregroundStyle(.secondary)
                switch controller.claude.loggedIn {
                case true?: Label("Signed in", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                case false?: Label("Not signed in", systemImage: "xmark.seal").foregroundStyle(.orange)
                case nil: EmptyView()
                }
            }
        } else {
            Text("Not found on this Mac").foregroundStyle(.orange)
        }
    }

    private func step<Content: View>(_ number: Int, title: LocalizedStringKey, detail: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.headline)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }
}

/// A copyable monospaced shell command.
struct CommandBox: View {
    let command: String

    var body: some View {
        HStack {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(Text("Copy command"))
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
