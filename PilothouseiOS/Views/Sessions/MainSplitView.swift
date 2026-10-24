import PilothouseKit
import SwiftUI

/// Sidebar of sessions + chat detail; collapses to a stack on iPhone.
struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var hiddenRequestIds: Set<String> = []

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionListView()
        } detail: {
            NavigationStack {
                if let connection = model.connection, let sessionId = model.selectedSessionId {
                    ChatView(connection: connection, sessionId: sessionId)
                        .id(sessionId)
                } else {
                    ContentUnavailableView {
                        Label("No Session Selected", systemImage: "bubble.left.and.text.bubble.right")
                    } description: {
                        Text("Pick a session from the list or start a new chat.")
                    } actions: {
                        Button("New Chat") { model.isPresentingNewChat = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.connection?.isConnected != true)
                    }
                }
            }
        }
        .sheet(isPresented: $model.isPresentingNewChat) {
            NewChatView()
        }
        .sheet(isPresented: $model.isPresentingSettings) {
            SettingsView()
        }
        .sheet(item: Binding(
            get: { visibleRequest },
            set: { request in
                if request == nil, let current = visibleRequest { hiddenRequestIds.insert(current.id) }
            }
        )) { request in
            if let connection = model.connection {
                PermissionRequestSheet(
                    request: request,
                    session: connection.session(request.sessionId),
                    connection: connection,
                    onLater: { hiddenRequestIds.insert(request.id) }
                )
            }
        }
    }

    /// The oldest permission request the user has not set aside.
    private var visibleRequest: PermissionRequest? {
        model.connection?.pendingPermissions.first { !hiddenRequestIds.contains($0.id) }
    }
}
