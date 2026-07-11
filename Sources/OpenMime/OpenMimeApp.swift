import SwiftUI

@main
struct OpenMimeApp: App {
    @StateObject private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                ComposeCommand(session: session, isEnabled: session.state.profile != nil)
            }
            CommandMenu("Conversation") {
                Button("Next Conversation") { session.selectNextConversation() }
                    .keyboardShortcut("j", modifiers: [])
                    .disabled(session.state.profile == nil || session.isComposing)
                Button("Previous Conversation") { session.selectPreviousConversation() }
                    .keyboardShortcut("k", modifiers: [])
                    .disabled(session.state.profile == nil || session.isComposing)
                Divider()
                Button("Clear Selection") { session.clearConversationSelection() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(session.state.profile == nil || session.isComposing)
            }
        }

        Window("New Message", id: "compose") {
            ComposeView()
                .environmentObject(session)
        }
        .defaultSize(width: 760, height: 620)

        Settings {
            SettingsView()
                .environmentObject(session)
                .frame(width: 520, height: 390)
        }
    }
}

private struct ComposeCommand: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var session: AppSession
    let isEnabled: Bool

    var body: some View {
        Button("New Message") {
            session.beginNewMessage()
            openWindow(id: "compose")
        }
            .keyboardShortcut("n")
            .disabled(!isEnabled)
    }
}
