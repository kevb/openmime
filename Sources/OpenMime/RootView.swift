import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        content
            .task { await session.start() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                session.refreshMailbox()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state.phase {
        case .starting:
            ProgressView("Restoring Gmail session…")
                .controlSize(.large)
        case .signedOut:
            WelcomeView()
        case .authorizing:
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Finish signing in with Google in your browser")
                    .font(.headline)
                Text("OpenMime is waiting for Google to return you to the app.")
                    .foregroundStyle(.secondary)
            }
        case .signedIn:
            MailShellView()
        case .failed(let message):
            ContentUnavailableView {
                Label("OpenMime needs attention", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
                    .textSelection(.enabled)
            } actions: {
                HStack {
                    Button("Try Again") { session.retry() }
                    Button("Choose OAuth JSON…") { session.chooseOAuthConfiguration() }
                }
            }
        }
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 58, weight: .medium))
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                Text("OpenMime")
                    .font(.largeTitle.bold())
                Text("A fast, private Gmail client for your Mac")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Connects directly to Gmail", systemImage: "lock.shield")
                Label("Credentials stay on this Mac", systemImage: "key")
                Label("No OpenMime cloud service", systemImage: "externaldrive")
            }
            .foregroundStyle(.secondary)

            if session.state.hasOAuthConfiguration {
                Button("Sign in with Google") { session.signIn() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Choose a different OAuth JSON…") { session.chooseOAuthConfiguration() }
                    .buttonStyle(.link)
            } else {
                Button("Choose Google OAuth JSON…") { session.chooseOAuthConfiguration() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text("Choose the Desktop OAuth client JSON downloaded from Google Cloud Console.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(48)
    }
}

private struct MailShellView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.openWindow) private var openWindow
    @State private var showsAdvancedSearch = false
    @State private var confirmsMarkAllRead = false
    @State private var showsLabelPicker = false

    private var selection: Binding<Set<String>> {
        Binding(get: { session.selectedThreadIDs }, set: { session.selectThreads(ids: $0) })
    }

    private var mailboxSelection: Binding<String?> {
        Binding(get: { session.selectedMailboxID }, set: { session.selectMailbox(id: $0) })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: mailboxSelection) {
                Section("Inboxes") {
                    MailboxSectionRows(section: .inboxes)
                }
                Section("Favorites") {
                    MailboxSectionRows(section: .favorites)
                }
                Section("Gmail") {
                    MailboxSectionRows(section: .gmail)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        session.beginNewMessage()
                        openWindow(id: "compose")
                    } label: {
                        Label("Compose", systemImage: "square.and.pencil")
                    }
                    .help("New Message (⌘N)")
                }
            }
        } content: {
            Group {
                if session.inbox.isEmpty, session.mailboxPhase == .loading {
                    ProgressView("Loading inbox…")
                        .controlSize(.large)
                } else if session.inbox.isEmpty {
                    ContentUnavailableView(
                        session.selectedMailboxID == "__search__" ? "No search results" : "No messages",
                        systemImage: session.selectedMailboxID == "__search__" ? "magnifyingglass" : "tray"
                    )
                } else {
                    ThreadSummaryList(selection: selection)
                }
            }
            .navigationTitle(session.selectedMailboxTitle)
            .navigationSplitViewColumnWidth(min: 300, ideal: 360)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        if session.isRefreshingMailbox {
                            ProgressView().controlSize(.mini)
                            Text("Checking Gmail…")
                        } else {
                            Image(systemName: session.isOffline ? "wifi.slash" : "checkmark.circle")
                                .foregroundStyle(session.isOffline ? .orange : .secondary)
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(Reliability.freshnessText(lastSuccessfulSync: session.lastSuccessfulSync, now: context.date))
                            }
                        }
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.12))
                    Divider()
                    if session.selectedMailboxID == "unread" {
                        HStack {
                            Text("\(session.count(for: session.selectedMailbox) ?? session.inbox.count) unread conversations")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if session.isMarkingAllRead {
                                ProgressView().controlSize(.small)
                            }
                            Button("Mark All Read") { confirmsMarkAllRead = true }
                                .controlSize(.small)
                                .disabled(session.isMarkingAllRead)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.quaternary.opacity(0.22))
                        Divider()
                    }
                    if case .failed(let message) = session.mailboxPhase {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(session.isOffline ? "Offline — showing cached mail" : "Gmail sync failed: \(message)")
                                .font(.caption)
                                .lineLimit(2)
                            Spacer()
                            Button("Retry") { session.refreshMailbox() }
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.orange.opacity(0.12))
                        Divider()
                    }
                }
            }
        } detail: {
            Group {
                if session.isLoadingThread {
                    ProgressView("Loading conversation…")
                        .controlSize(.large)
                } else if let thread = session.selectedThread {
                    VStack(spacing: 0) {
                        HStack {
                            Text(thread.subject)
                                .font(.title2.bold())
                                .lineLimit(2)
                            if let mailboxLabel = conversationMailboxLabel {
                                Text(mailboxLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(.secondary.opacity(0.45), lineWidth: 0.5)
                                    }
                            }
                            ForEach(conversationUserLabels) { label in
                                Text(label.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.purple.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        Divider()
                        if thread.containsRemoteImages, !thread.isShowingRemoteImages {
                            RemoteImagesBanner(
                                sender: thread.remoteImageSender,
                                loadOnce: { session.showRemoteImagesForSelectedThread() },
                                alwaysLoad: { session.showRemoteImagesForSelectedThread(alwaysForSender: true) }
                            )
                            Divider()
                        }
                        if !thread.attachments.isEmpty {
                            AttachmentBar(
                                attachments: thread.attachments,
                                downloadingID: session.downloadingAttachmentID,
                                download: { session.downloadAttachment($0) }
                            )
                            Divider()
                        }
                        ConversationWebView(thread: thread)
                    }
                } else if session.selectedThreadIDs.count > 1 {
                    ContentUnavailableView(
                        "\(session.selectedThreadIDs.count) conversations selected",
                        systemImage: "checkmark.circle"
                    )
                } else {
                    ContentUnavailableView("Select a conversation", systemImage: "envelope.open")
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { session.perform(.archive) } label: { Label("Archive", systemImage: "archivebox") }
                    .keyboardShortcut("e", modifiers: [])
                    .help("Archive (E)")
                    .disabled(session.selectedSummaries.isEmpty || session.actionInProgress)
                Button { session.perform(.trash) } label: { Label("Trash", systemImage: "trash") }
                    .keyboardShortcut(.delete, modifiers: [])
                    .help("Move to Trash (Delete)")
                    .disabled(session.selectedSummaries.isEmpty || session.actionInProgress)
                Button { session.perform(.toggleRead) } label: {
                    Label(
                        session.selectedSummaries.contains(where: \.isUnread) ? "Mark Read" : "Mark Unread",
                        systemImage: session.selectedSummaries.contains(where: \.isUnread) ? "envelope.open" : "envelope.badge"
                    )
                }
                .keyboardShortcut("u", modifiers: [])
                .help(session.selectedSummaries.contains(where: \.isUnread) ? "Mark Read (U)" : "Mark Unread (U)")
                .disabled(session.selectedSummaries.isEmpty || session.actionInProgress)
                Button { session.perform(.toggleStar) } label: {
                    Label(
                        session.selectedSummaries.allSatisfy(\.isStarred) ? "Unstar" : "Star",
                        systemImage: session.selectedSummaries.allSatisfy(\.isStarred) ? "star.fill" : "star"
                    )
                }
                .keyboardShortcut("s", modifiers: [])
                .help(session.selectedSummaries.allSatisfy(\.isStarred) ? "Unstar (S)" : "Star (S)")
                .disabled(session.selectedSummaries.isEmpty || session.actionInProgress)
                Button { showsLabelPicker.toggle() } label: {
                    Label("Labels", systemImage: "tag")
                }
                .help("Apply or remove labels")
                .disabled(session.selectedSummaries.isEmpty || session.actionInProgress)
                .popover(isPresented: $showsLabelPicker, arrowEdge: .bottom) {
                    LabelPickerView()
                        .environmentObject(session)
                }
                if session.selectedMailboxID == "drafts" {
                    Button {
                        Task {
                            if await session.beginEditingSelectedDraft() {
                                openWindow(id: "compose")
                            }
                        }
                    } label: { Label("Edit Draft", systemImage: "pencil.and.list.clipboard") }
                        .help("Edit Gmail Draft")
                        .disabled(!session.canEditSelectedDraft || session.isLoadingEditableDraft)
                }
                Button {
                    session.beginResponse(.reply)
                    openWindow(id: "compose")
                } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    .help("Reply")
                    .disabled(!session.canRespondToSelectedThread)
                Button {
                    session.beginResponse(.replyAll)
                    openWindow(id: "compose")
                } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                    .help("Reply All")
                    .disabled(!session.canRespondToSelectedThread)
                Button {
                    session.beginResponse(.forward)
                    openWindow(id: "compose")
                } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                    .help("Forward")
                    .disabled(!session.canRespondToSelectedThread)
                Menu {
                    Button("Report Spam", systemImage: "exclamationmark.octagon") {
                        session.perform(.spam)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(session.selectedSummaries.isEmpty || session.actionInProgress)
            }
            ToolbarItem {
                Button { session.refreshCurrentMailbox() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh inbox")
            }
            ToolbarItem {
                Button { showsAdvancedSearch = true } label: {
                    Label("Advanced Search", systemImage: "slider.horizontal.3")
                }
                .help("Advanced Gmail search")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.beginNewMessage()
                    openWindow(id: "compose")
                } label: { Label("Compose", systemImage: "square.and.pencil") }
                    .help("New Message (⌘N)")
            }
        }
        .alert(
            "Gmail action failed",
            isPresented: Binding(
                get: { session.presentedError != nil },
                set: { if !$0 { session.presentedError = nil } }
            )
        ) {
            Button("OK") { session.presentedError = nil }
        } message: {
            Text(session.presentedError ?? "Unknown error")
        }
        .alert("Mark every inbox message as read?", isPresented: $confirmsMarkAllRead) {
            Button("Cancel", role: .cancel) {}
            Button("Mark All Read") { session.markAllRead() }
        } message: {
            Text("This changes every unread message currently in your Gmail inbox, not only the rows loaded in OpenMime.")
        }
        .searchable(
            text: Binding(
                get: { session.searchText },
                set: {
                    session.searchText = $0
                    session.searchTextChanged()
                }
            ),
            placement: .toolbar,
            prompt: "Search Gmail"
        )
        .onSubmit(of: .search) { session.submitSearch() }
        .sheet(isPresented: $showsAdvancedSearch) {
            AdvancedSearchView { query in
                session.searchText = query
                session.submitSearch()
            }
        }
    }

    private var conversationMailboxLabel: String? {
        switch session.selectedMailboxID {
        case "primary", "social", "promotions", "updates": "Inbox"
        case "__search__": nil
        default: session.selectedMailboxTitle
        }
    }

    private var conversationUserLabels: [GmailLabel] {
        guard let summary = session.selectedSummary else { return [] }
        return session.userLabels.filter { summary.labelIDs.contains($0.id) }
    }
}

struct ComposeView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ComposeDraft()
    @State private var showsCc = false
    @State private var showsBcc = false
    @State private var showsContactsSetup = false
    @State private var showsDraftFailure = false
    @State private var toInput = ""
    @State private var ccInput = ""
    @State private var bccInput = ""
    @AppStorage("dismissedContactsBanner") private var dismissedContactsBanner = false
    @FocusState private var focusedField: Field?

    private enum Field { case to, cc, bcc, subject, body }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    recipientField("To:", committed: $draft.to, input: $toInput, field: .to, prompt: "Recipients")
                    Button("Cc") { showsCc.toggle() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Bcc") { showsBcc.toggle() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                addressSuggestionList(field: .to)
                if showsCc {
                    Divider().padding(.leading, 86)
                    recipientField("Cc:", committed: $draft.cc, input: $ccInput, field: .cc, prompt: "Carbon copy")
                    addressSuggestionList(field: .cc)
                }
                if showsBcc {
                    Divider().padding(.leading, 86)
                    recipientField("Bcc:", committed: $draft.bcc, input: $bccInput, field: .bcc, prompt: "Blind carbon copy")
                    addressSuggestionList(field: .bcc)
                }
                Divider().padding(.leading, 78)
                composeField("Subject:", text: $draft.subject, field: .subject, prompt: "Subject")
            }

            Divider()

            HStack {
                Text("From:")
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                Text(session.state.profile?.emailAddress ?? "")
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)

            Divider()

            if case .disconnected = session.contactsPhase, !dismissedContactsBanner {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").foregroundStyle(.blue)
                    Text("Connect Google Contacts for better address suggestions.")
                    Button("Connect…") { showsContactsSetup = true }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        dismissedContactsBanner = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.18))
                Divider()
            } else if case .failed(let message) = session.contactsPhase {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Google Contacts: \(message)").font(.caption).lineLimit(2)
                    Spacer()
                    Button("Try Again") { showsContactsSetup = true }.controlSize(.small)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                Divider()
            }

            if !draft.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(draft.attachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo.fill" : "doc.fill")
                                    .foregroundStyle(attachment.mimeType.hasPrefix("image/") ? .red : .blue)
                                Text(attachment.filename)
                                    .lineLimit(1)
                                if attachment.size > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    draft.attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .disabled(session.isSendingMessage)
                            }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                }
                Divider()
            }

            TextEditor(text: $draft.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(18)
                .focused($focusedField, equals: .body)
                .disabled(session.isSendingMessage)
        }
        .frame(minWidth: 640, minHeight: 460)
        .interactiveDismissDisabled(session.isSendingMessage)
        .onAppear {
            if !session.isComposing { session.beginNewMessage() }
            draft = session.composeDraft
            focusedField = .to
        }
        .onDisappear { session.finishComposing(draft) }
        .onChange(of: draft) { _, newDraft in
            session.scheduleDraftSave(newDraft)
        }
        .onChange(of: focusedField) { previousField, field in
            if let previousField, previousField != field {
                commitPending(field: previousField)
            }
            switch field {
            case .to: session.updateAddressSuggestions(for: toInput)
            case .cc: session.updateAddressSuggestions(for: ccInput)
            case .bcc: session.updateAddressSuggestions(for: bccInput)
            default: session.clearAddressSuggestions()
            }
        }
        .onChange(of: session.isComposing) { wasComposing, isComposing in
            if wasComposing, !isComposing { dismiss() }
        }
        .onChange(of: session.composeDraft) { _, newDraft in
            if !session.isSendingMessage { draft = newDraft }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { chooseAttachments() } label: {
                    Label("Attach Files", systemImage: "paperclip")
                }
                .disabled(session.isSendingMessage)
                .help("Attach Files")
            }
            ToolbarItem(placement: .status) {
                if session.isSendingMessage {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Sending…").foregroundStyle(.secondary)
                    }
                } else {
                    switch session.draftSavePhase {
                    case .waiting:
                        Text("Waiting to save…").foregroundStyle(.tertiary)
                    case .saving:
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Saving draft…").foregroundStyle(.secondary)
                        }
                    case .saved:
                        Label("Saved to Gmail", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Button {
                            showsDraftFailure = true
                        } label: {
                            Label("Draft not saved", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .help("Draft not saved: \(message)")
                    case .idle:
                        EmptyView()
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.sendMessage(draft)
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!draft.canSend || session.isSendingMessage || session.isSavingDraft)
                .help("Send Message (⌘↩)")
            }
        }
        .alert(
            "Could not attach file",
            isPresented: Binding(
                get: { session.presentedError != nil },
                set: { if !$0 { session.presentedError = nil } }
            )
        ) {
            Button("OK") { session.presentedError = nil }
        } message: {
            Text(session.presentedError ?? "Unknown error")
        }
        .sheet(isPresented: $showsContactsSetup) {
            GoogleServicesConnectionView()
                .environmentObject(session)
        }
        .alert("Draft not saved", isPresented: $showsDraftFailure) {
            Button("OK") {}
        } message: {
            if case .failed(let message) = session.draftSavePhase {
                Text(message)
            } else {
                Text("The draft could not be saved to Gmail.")
            }
        }
    }

    private func composeField(
        _ title: String,
        text: Binding<String>,
        field: Field,
        prompt: String
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: field)
                .disabled(session.isSendingMessage)
                .onChange(of: text.wrappedValue) { _, value in
                    if focusedField == field { session.updateAddressSuggestions(for: value) }
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func recipientField(
        _ title: String,
        committed: Binding<String>,
        input: Binding<String>,
        field: Field,
        prompt: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(GmailClient.contacts(from: committed.wrappedValue)) { contact in
                        HStack(spacing: 5) {
                            Text(contact.name.caseInsensitiveCompare(contact.email) == .orderedSame ? contact.email : contact.name)
                                .lineLimit(1)
                            Button {
                                removeRecipient(contact, from: committed)
                            } label: {
                                Image(systemName: "xmark").font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.28), in: RoundedRectangle(cornerRadius: 5))
                        .help(contact.email)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Recipient \(contact.name), \(contact.email)")
                        .accessibilityHint("Use the remove button to delete this recipient")
                    }
                    TextField(prompt, text: input)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 120)
                        .focused($focusedField, equals: field)
                        .onSubmit { commitPending(field: field) }
                        .onChange(of: input.wrappedValue) { oldValue, newValue in
                            handleRecipientInput(oldValue: oldValue, newValue: newValue, field: field)
                        }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .disabled(session.isSendingMessage)
    }

    @ViewBuilder
    private func addressSuggestionList(field: Field) -> some View {
        if focusedField == field, !session.addressSuggestions.isEmpty {
            VStack(spacing: 0) {
                ForEach(session.addressSuggestions) { contact in
                    Button {
                        commit(contact, field: field)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(contact.name).lineLimit(1)
                                if contact.name.caseInsensitiveCompare(contact.email) != .orderedSame {
                                    Text(contact.email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 86)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.quaternary.opacity(0.28))
        }
    }

    private func commit(_ contact: EmailContact, field: Field) {
        let committed = committedBinding(for: field)
        var contacts = GmailClient.contacts(from: committed.wrappedValue)
        if !contacts.contains(where: { $0.email.caseInsensitiveCompare(contact.email) == .orderedSame }) {
            contacts.append(contact)
        }
        committed.wrappedValue = contacts.map(\.formattedAddress).joined(separator: ", ")
        inputBinding(for: field).wrappedValue = ""
        session.clearAddressSuggestions()
    }

    private func removeRecipient(_ contact: EmailContact, from committed: Binding<String>) {
        committed.wrappedValue = GmailClient.contacts(from: committed.wrappedValue)
            .filter { $0.email.caseInsensitiveCompare(contact.email) != .orderedSame }
            .map(\.formattedAddress).joined(separator: ", ")
    }

    private func handleRecipientInput(oldValue: String, newValue: String, field: Field) {
        let endsWithDelimiter = newValue.last.map { $0 == "," || $0 == ";" } == true
        let endsWithSpace = newValue.last?.isWhitespace == true && oldValue.last?.isWhitespace != true
        if endsWithDelimiter || (endsWithSpace && validPendingContact(newValue) != nil) {
            commitPending(field: field)
        } else {
            session.updateAddressSuggestions(for: newValue)
        }
    }

    private func commitPending(field: Field) {
        let input = inputBinding(for: field)
        guard let contact = validPendingContact(input.wrappedValue) else { return }
        commit(contact, field: field)
    }

    private func validPendingContact(_ value: String) -> EmailContact? {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " ,;\t\n"))
        let contacts = GmailClient.contacts(from: trimmed)
        guard contacts.count == 1, contacts[0].email.contains("@") else { return nil }
        return contacts[0]
    }

    private func committedBinding(for field: Field) -> Binding<String> {
        switch field {
        case .to: $draft.to
        case .cc: $draft.cc
        case .bcc: $draft.bcc
        default: $draft.to
        }
    }

    private func inputBinding(for field: Field) -> Binding<String> {
        switch field {
        case .to: $toInput
        case .cc: $ccInput
        case .bcc: $bccInput
        default: $toInput
        }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.title = "Attach Files"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        var additions: [ComposeAttachment] = []
        for url in panel.urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let size = values?.fileSize ?? 0
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            additions.append(.local(url: url, mimeType: mimeType, size: size))
        }
        let total = (draft.attachments + additions).reduce(0) { $0 + $1.size }
        guard total <= MIMEMessageBuilder.maximumAttachmentBytes else {
            session.presentedError = MIMEMessageBuilder.BuildError.attachmentsTooLarge.localizedDescription
            return
        }
        draft.attachments.append(contentsOf: additions)
    }
}

private struct MailboxSectionRows: View {
    @EnvironmentObject private var session: AppSession
    let section: MailboxDescriptor.Section

    var body: some View {
        ForEach(session.mailboxes.filter { $0.section == section }) { mailbox in
            MailboxRow(mailbox: mailbox, count: session.count(for: mailbox))
                .tag(mailbox.id)
        }
    }
}

private struct ThreadSummaryList: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.openWindow) private var openWindow
    let selection: Binding<Set<String>>

    var body: some View {
        List(selection: selection) {
            ForEach(session.inbox) { thread in
                ThreadRow(thread: thread)
                    .tag(thread.id)
                    .onAppear { session.loadMoreSearchResultsIfNeeded(currentThreadID: thread.id) }
            }
            if session.isLoadingMoreSearchResults {
                HStack {
                    Spacer()
                    ProgressView("Loading more…")
                        .controlSize(.small)
                        .padding(.vertical, 8)
                    Spacer()
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { threadIDs in
            let summaries = session.inbox.filter { threadIDs.contains($0.id) }
            let anyUnread = summaries.contains(where: \.isUnread)
            let allStarred = !summaries.isEmpty && summaries.allSatisfy(\.isStarred)

            Button(anyUnread ? "Mark as Read" : "Mark as Unread", systemImage: anyUnread ? "envelope.open" : "envelope.badge") {
                session.perform(.toggleRead, on: threadIDs)
            }
            Button(allStarred ? "Remove Star" : "Add Star", systemImage: allStarred ? "star.slash" : "star") {
                session.perform(.toggleStar, on: threadIDs)
            }
            Divider()
            Button("Archive", systemImage: "archivebox") { session.perform(.archive, on: threadIDs) }
            Button("Move to Trash", systemImage: "trash") { session.perform(.trash, on: threadIDs) }
            Button("Report Spam", systemImage: "exclamationmark.octagon") { session.perform(.spam, on: threadIDs) }
            Divider()
            Menu("Label", systemImage: "tag") {
                ForEach(session.userLabels) { label in
                    let state = session.labelState(label, threadIDs: threadIDs)
                    Button {
                        session.toggleLabel(label, on: threadIDs)
                    } label: {
                        Label(label.name, systemImage: state.applied == state.total && state.total > 0 ? "checkmark" : state.applied > 0 ? "minus" : "tag")
                    }
                }
            }
            Divider()
            Button("Reply", systemImage: "arrowshape.turn.up.left") {
                session.beginResponse(.reply)
                openWindow(id: "compose")
            }
            .disabled(threadIDs.count != 1 || session.selectedThreadID != threadIDs.first || !session.canRespondToSelectedThread)
            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") {
                session.beginResponse(.replyAll)
                openWindow(id: "compose")
            }
            .disabled(threadIDs.count != 1 || session.selectedThreadID != threadIDs.first || !session.canRespondToSelectedThread)
            Button("Forward", systemImage: "arrowshape.turn.up.right") {
                session.beginResponse(.forward)
                openWindow(id: "compose")
            }
            .disabled(threadIDs.count != 1 || session.selectedThreadID != threadIDs.first || !session.canRespondToSelectedThread)
        }
    }
}

private struct LabelPickerView: View {
    @EnvironmentObject private var session: AppSession
    @State private var search = ""

    private var visibleLabels: [GmailLabel] {
        let value = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? session.userLabels : session.userLabels.filter {
            $0.name.localizedCaseInsensitiveContains(value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Labels").font(.headline)
            TextField("Search labels", text: $search)
                .textFieldStyle(.roundedBorder)
            if visibleLabels.isEmpty {
                ContentUnavailableView("No labels", systemImage: "tag")
                    .frame(height: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleLabels) { label in
                            let state = session.labelState(label)
                            Button {
                                session.toggleLabel(label)
                            } label: {
                                HStack {
                                    Image(systemName: state.applied == state.total && state.total > 0 ? "checkmark.square.fill" : state.applied > 0 ? "minus.square.fill" : "square")
                                        .foregroundStyle(state.applied > 0 ? .blue : .secondary)
                                    Text(label.name).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                            .disabled(session.actionInProgress)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300, height: 360)
    }
}

private struct GoogleServicesConnectionView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var connectsContacts = true

    var body: some View {
        VStack(spacing: 26) {
            Text("Connect Google Services")
                .font(.largeTitle.weight(.semibold))
            Text("Select the optional service to connect. Gmail remains connected either way.")
                .foregroundStyle(.secondary)

            VStack(spacing: 18) {
                serviceRow(icon: "envelope.fill", color: .red, title: "Gmail", subtitle: "Send, receive, and manage email.") {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                }
                serviceRow(icon: "person.crop.circle.fill", color: .blue, title: "Google Contacts", subtitle: "Names and address autocomplete.") {
                    Toggle("", isOn: $connectsContacts).labelsHidden()
                }
            }
            .frame(maxWidth: 520)

            Group {
                switch session.contactsPhase {
                case .disconnected:
                    Text("Contacts permission is read-only. Data and credentials remain on this Mac.")
                        .foregroundStyle(.secondary)
                case .connecting:
                    Label("Waiting for Google in your browser…", systemImage: "safari")
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Signed in. Loading your contacts…")
                    }
                case .connected(let count):
                    Label("Connected \(count) addresses", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .frame(maxWidth: 560)

            HStack(spacing: 16) {
                switch session.contactsPhase {
                case .disconnected:
                    Button("Cancel") { dismiss() }
                    Button {
                        session.connectGoogleContacts()
                    } label: {
                        Label("Sign in with Google", systemImage: "person.badge.key.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!connectsContacts)
                case .connecting, .loading:
                    Button("Continue in Background") { dismiss() }
                case .failed:
                    Button("Close") { dismiss() }
                    Button("Retry Contact Download") { session.retryGoogleContacts() }
                        .buttonStyle(.borderedProminent)
                case .connected:
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(42)
        .frame(width: 680, height: 500)
        .onChange(of: session.contactsPhase) { _, phase in
            if case .connected = phase { dismiss() }
        }
    }

    private func serviceRow<Accessory: View>(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(color).frame(width: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            accessory()
        }
    }
}

private struct AdvancedSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AdvancedSearchDraft()
    let apply: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Advanced Gmail Search")
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                searchField("From", text: $draft.from, prompt: "name@example.com")
                searchField("To", text: $draft.to, prompt: "name@example.com")
                searchField("Subject", text: $draft.subject, prompt: "Words in the subject")
                searchField("Includes", text: $draft.words, prompt: "Words to include")
                searchField("Excludes", text: $draft.excludedWords, prompt: "Words to exclude")
            }

            Toggle("Has an attachment", isOn: $draft.hasAttachment)

            HStack(spacing: 18) {
                Toggle("After", isOn: $draft.useAfterDate)
                DatePicker("", selection: $draft.afterDate, displayedComponents: .date)
                    .labelsHidden()
                    .disabled(!draft.useAfterDate)
                Toggle("Before", isOn: $draft.useBeforeDate)
                DatePicker("", selection: $draft.beforeDate, displayedComponents: .date)
                    .labelsHidden()
                    .disabled(!draft.useBeforeDate)
            }

            Text("This builds Gmail search syntax and places it in the search box, where you can edit it further.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Search") {
                    apply(draft.gmailQuery())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.gmailQuery().isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func searchField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct MailboxRow: View {
    let mailbox: MailboxDescriptor
    let count: Int?

    var body: some View {
        HStack {
            Image(systemName: mailbox.systemImage)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            Text(mailbox.title)
                .lineLimit(1)
            Spacer()
            if let count, count > 0 {
                Text(formattedCount(count))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formattedCount(_ count: Int) -> String {
        if ["social", "promotions", "updates"].contains(mailbox.id), count > 300 { return "300+" }
        return count.formatted()
    }

    private var iconColor: Color {
        switch mailbox.id {
        case "primary": .blue
        case "social", "drafts": .cyan
        case "promotions", "sent": .mint
        case "updates", "spam", "important": .orange
        case "starred": .yellow
        case "all-mail": .pink
        case "trash": .red
        default: mailbox.isUserLabel ? .secondary : .primary
        }
    }
}

private struct AttachmentBar: View {
    let attachments: [MailAttachment]
    let downloadingID: String?
    let download: (MailAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    Button { download(attachment) } label: {
                        HStack(spacing: 8) {
                            if downloadingID == attachment.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: attachmentIcon(attachment.mimeType))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(attachment.filename).lineLimit(1)
                                if attachment.size > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.bordered)
                    .disabled(downloadingID != nil)
                    .help("Save \(attachment.filename)")
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 9)
        }
    }

    private func attachmentIcon(_ mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType.hasPrefix("video/") { return "film" }
        return "paperclip"
    }
}

private struct RemoteImagesBanner: View {
    let sender: String
    let loadOnce: () -> Void
    let alwaysLoad: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
            Text("Remote images are blocked.")
                .fontWeight(.semibold)
            Button("Load images", action: loadOnce)
                .buttonStyle(.link)
            Text("·").foregroundStyle(.tertiary)
            Button("Always load from \(sender)", action: alwaysLoad)
                .buttonStyle(.link)
                .lineLimit(1)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35))
    }
}

private struct ThreadRow: View {
    let thread: ThreadSummary

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(thread.isUnread ? Color.blue : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(thread.sender)
                    .fontWeight(thread.isUnread ? .bold : .semibold)
                    .lineLimit(1)
                if thread.messageCount > 1 {
                    Text("\(thread.messageCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(rowDate)
                    .font(.caption)
                    .foregroundStyle(thread.isUnread ? Color.blue : Color.secondary)
            }
            HStack {
                Text(thread.subject)
                    .fontWeight(thread.isUnread ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
                if thread.isStarred { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            }
            Text(thread.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(thread.attachmentNames.isEmpty ? 2 : 1)
            if let firstAttachment = thread.attachmentNames.first {
                HStack(spacing: 8) {
                    Label {
                        Text(firstAttachment)
                    } icon: {
                        Image(systemName: attachmentAppearance(for: firstAttachment).symbol)
                            .foregroundStyle(attachmentAppearance(for: firstAttachment).color)
                    }
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.secondary.opacity(0.55), lineWidth: 0.5)
                        }
                    if thread.attachmentNames.count > 1 {
                        Text("& \(thread.attachmentNames.count - 1) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Select to open this conversation. Use the context menu for mail actions.")
    }

    private var accessibilityLabel: String {
        var parts = [thread.isUnread ? "Unread" : "Read", "From \(thread.sender)", "Subject \(thread.subject)", rowDate]
        if thread.messageCount > 1 { parts.append("\(thread.messageCount) messages") }
        if thread.isStarred { parts.append("Starred") }
        if !thread.attachmentNames.isEmpty { parts.append("Has attachments") }
        return parts.joined(separator: ", ")
    }

    private var rowDate: String {
        if Calendar.current.isDateInToday(thread.date) {
            return thread.date.formatted(date: .omitted, time: .shortened)
        }
        return thread.date.formatted(date: .numeric, time: .omitted)
    }

    private func attachmentAppearance(for filename: String) -> (symbol: String, color: Color) {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg":
            ("photo.fill", .red)
        case "pdf":
            ("doc.richtext.fill", .red)
        case "html", "htm":
            ("doc.text.fill", .blue)
        case "xls", "xlsx", "csv", "numbers":
            ("tablecells.fill", .green)
        case "doc", "docx", "pages", "rtf", "txt", "md":
            ("doc.text.fill", .blue)
        case "zip", "rar", "7z", "tar", "gz", "bz2":
            ("archivebox.fill", .orange)
        case "mp3", "m4a", "wav", "aac", "flac", "ogg":
            ("waveform", .purple)
        case "mp4", "mov", "m4v", "avi", "mkv", "webm":
            ("film.fill", .purple)
        case "ics":
            ("calendar", .red)
        default:
            ("doc.fill", .secondary)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        Form {
            Section("Google account") {
                if let profile = session.state.profile {
                    LabeledContent("Connected account", value: profile.emailAddress)
                    Button("Sign Out", role: .destructive) { session.signOut() }
                } else {
                    Text("No Gmail account connected")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Google Contacts") {
                switch session.contactsPhase {
                case .connected(let count):
                    LabeledContent("Status", value: "Connected — \(count) addresses")
                    Button("Disconnect Contacts", role: .destructive) { session.disconnectGoogleContacts() }
                case .connecting:
                    ProgressView("Connecting…")
                case .loading:
                    ProgressView("Loading contacts…")
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                    Button("Retry") { session.retryGoogleContacts() }
                case .disconnected:
                    LabeledContent("Status", value: "Not connected")
                    Button("Connect Contacts…") { session.connectGoogleContacts() }
                        .disabled(session.state.profile == nil)
                }
            }
            Section("OAuth configuration") {
                LabeledContent("Desktop client", value: session.state.hasOAuthConfiguration ? "Configured" : "Not configured")
                HStack {
                    Button("Choose JSON…") { session.chooseOAuthConfiguration() }
                    if session.state.hasOAuthConfiguration {
                        Button("Remove", role: .destructive) { session.removeOAuthConfiguration() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
