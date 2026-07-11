import AppKit
import Foundation
import OSLog

@MainActor
final class AppSession: ObservableObject {
    private static let logger = Logger(subsystem: "org.openmime.OpenMime", category: "sync")
    enum MailboxAction: Sendable, Equatable {
        case archive
        case trash
        case spam
        case toggleStar
        case toggleRead
    }

    enum MailboxPhase: Equatable {
        case idle
        case loading
        case loaded(Date)
        case failed(String)
    }

    enum DraftSavePhase: Equatable {
        case idle
        case waiting
        case saving
        case saved(Date)
        case failed(String)
    }

    enum ContactsPhase: Equatable {
        case disconnected
        case connecting
        case loading
        case connected(Int)
        case failed(String)
    }

    enum Phase: Equatable {
        case starting
        case signedOut
        case authorizing
        case signedIn
        case failed(String)
    }

    struct State: Equatable {
        var phase: Phase = .starting
        var profile: GmailProfile?
        var hasOAuthConfiguration = OAuthConfigurationStore.load() != nil
    }

    @Published private(set) var state = State()
    @Published private(set) var inbox: [ThreadSummary] = []
    @Published private(set) var labels: [GmailLabel] = []
    @Published private(set) var selectedMailboxID = MailboxDescriptor.primary.id
    @Published var searchText = ""
    @Published private(set) var selectedThread: RenderedThread?
    @Published private(set) var selectedThreadID: String?
    @Published private(set) var selectedThreadIDs: Set<String> = []
    @Published private(set) var mailboxPhase: MailboxPhase = .idle
    @Published private(set) var lastSuccessfulSync: Date?
    @Published private(set) var isRefreshingMailbox = false
    @Published private(set) var isOffline = false
    @Published private(set) var isLoadingThread = false
    @Published private(set) var actionInProgress = false
    @Published private(set) var downloadingAttachmentID: String?
    @Published private(set) var isLoadingMoreSearchResults = false
    @Published var isComposing = false
    @Published private(set) var isSendingMessage = false
    @Published private(set) var addressSuggestions: [EmailContact] = []
    @Published private(set) var contactsPhase: ContactsPhase = .disconnected
    @Published private(set) var composeDraft = ComposeDraft()
    @Published private(set) var draftSavePhase: DraftSavePhase = .idle
    @Published private(set) var isLoadingEditableDraft = false
    @Published private(set) var isMarkingAllRead = false
    @Published var presentedError: String?

    private let auth = GoogleOAuthClient()
    private let gmail = GmailClient()
    private let googleContactsClient = GoogleContactsClient()
    private let store = try! MailboxStore.live()
    private var mailboxTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var viewTask: Task<Void, Never>?
    private var primaryInbox: [ThreadSummary] = []
    private var activeSearchQuery: String?
    private var searchNextPageToken: String?
    private var oauthTokens: OAuthTokens?
    private var contactsTokens: OAuthTokens?
    private var googleContacts: [EmailContact] = []
    private var tokenRefreshTask: Task<OAuthTokens, Error>?
    private var addressSuggestionTask: Task<Void, Never>?
    private var draftAutosaveTask: Task<Void, Never>?
    private var pendingDraftSave: (generation: UUID, draft: ComposeDraft)?
    private var composeGeneration = UUID()
    private var activeGmailDraftID: String?
    private var isDraftSaveInFlight = false

    deinit {
        mailboxTask?.cancel()
        pollTask?.cancel()
        viewTask?.cancel()
        draftAutosaveTask?.cancel()
    }

    func start() async {
        guard state.phase == .starting else { return }
        await restoreSession()
    }

    func chooseOAuthConfiguration() {
        let panel = NSOpenPanel()
        panel.title = "Choose Google Desktop OAuth JSON"
        panel.message = "Select the JSON downloaded for your Google OAuth Desktop client. It stays on this Mac."
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let configuration = try OAuthConfiguration.load(from: url)
            try OAuthConfigurationStore.save(configuration)
            state.hasOAuthConfiguration = true
            if case .failed = state.phase { state.phase = .signedOut }
        } catch {
            state.phase = .failed(error.localizedDescription)
        }
    }

    func signIn() {
        guard let configuration = OAuthConfigurationStore.load() else {
            chooseOAuthConfiguration()
            return
        }

        state.phase = .authorizing
        Task {
            do {
                let tokens = try await auth.authorize(configuration: configuration)
                try TokenStore.save(tokens)
                oauthTokens = tokens
                let profile = try await gmail.profile(accessToken: tokens.accessToken)
                state.profile = profile
                CachedProfileStore.save(profile)
                await startMailbox()
                state.phase = .signedIn
                await restoreGoogleContacts()
            } catch is CancellationError {
                state.phase = .signedOut
            } catch {
                state.phase = .failed(error.localizedDescription)
            }
        }
    }

    func retry() {
        state.phase = .signedOut
    }

    func signOut() {
        let account = state.profile?.emailAddress
        mailboxTask?.cancel()
        pollTask?.cancel()
        viewTask?.cancel()
        try? TokenStore.delete()
        try? TokenStore.deleteContacts()
        GoogleContactsCache.delete()
        CachedProfileStore.delete()
        if let account { SyncFreshnessStore.delete(account: account) }
        oauthTokens = nil
        contactsTokens = nil
        googleContacts = []
        contactsPhase = .disconnected
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        state.profile = nil
        inbox = []
        primaryInbox = []
        labels = []
        selectedMailboxID = MailboxDescriptor.primary.id
        selectedThread = nil
        selectedThreadID = nil
        selectedThreadIDs = []
        mailboxPhase = .idle
        lastSuccessfulSync = nil
        isRefreshingMailbox = false
        isOffline = false
        isComposing = false
        isSendingMessage = false
        addressSuggestions = []
        addressSuggestionTask?.cancel()
        draftAutosaveTask?.cancel()
        pendingDraftSave = nil
        activeGmailDraftID = nil
        draftSavePhase = .idle
        isDraftSaveInFlight = false
        resetSearchPagination()
        state.phase = .signedOut
        if let account {
            Task { try? await store.removeAccount(account) }
        }
    }

    func refreshMailbox() {
        guard state.profile != nil, mailboxTask == nil else { return }
        Self.logger.info("Mailbox refresh starting")
        mailboxTask = Task { [weak self] in
            guard let self else { return }
            if inbox.isEmpty { mailboxPhase = .loading }
            isRefreshingMailbox = true
            defer {
                mailboxTask = nil
                isRefreshingMailbox = false
            }
            do {
                let token = try await validAccessToken()
                guard let profile = state.profile else { return }
                if let checkpoint = try await store.historyID(account: profile.emailAddress) {
                    do {
                        let delta = try await gmail.history(since: checkpoint, accessToken: token)
                        let changes = try await gmail.summariesForChangedThreads(
                            ids: delta.changedThreadIDs,
                            accessToken: token
                        )
                        try await store.apply(
                            account: profile.emailAddress,
                            upserts: changes.upserts,
                            removals: changes.removals.union(delta.removedThreadIDs),
                            historyID: delta.historyID
                        )
                    } catch GmailError.requestFailed(let status, _) where status == 404 {
                        try await fullMailboxSync(account: profile.emailAddress, accessToken: token)
                    }
                } else {
                    try await fullMailboxSync(account: profile.emailAddress, accessToken: token)
                }
                try await reconcilePrimaryMailbox(account: profile.emailAddress, accessToken: token)
                primaryInbox = try await store.cachedInbox(account: profile.emailAddress)
                if selectedMailboxID == MailboxDescriptor.primary.id { inbox = primaryInbox }
                let completedAt = Date()
                lastSuccessfulSync = completedAt
                SyncFreshnessStore.save(completedAt, account: profile.emailAddress)
                isOffline = false
                mailboxPhase = .loaded(completedAt)
                Self.logger.info("Mailbox refresh completed")
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Mailbox refresh failed: \(error.localizedDescription, privacy: .public)")
                if Reliability.requiresReauthentication(error) {
                    requireReauthentication()
                    return
                }
                isOffline = Reliability.isOffline(error)
                mailboxPhase = .failed(error.localizedDescription)
            }
        }
    }

    func selectThread(id: String?) {
        selectedThreadID = id
        selectedThread = nil
        guard let id else { return }
        isLoadingThread = true
        Task { [weak self] in
            guard let self else { return }
            do {
                if let account = state.profile?.emailAddress,
                   var cached = try await store.cachedThread(account: account, threadID: id) {
                    if RemoteImagePreferences.isAllowed(sender: cached.remoteImageSender) {
                        cached.showRemoteImages()
                    }
                    guard selectedThreadID == id else { return }
                    selectedThread = cached
                    isLoadingThread = false
                }
                let token = try await validAccessToken()
                let thread = try await gmail.thread(id: id, accessToken: token)
                var rendered = await Task.detached(priority: .userInitiated) {
                    RenderedThread(thread)
                }.value
                if let account = state.profile?.emailAddress {
                    try await store.saveThread(account: account, thread: rendered)
                }
                if RemoteImagePreferences.isAllowed(sender: rendered.remoteImageSender) {
                    rendered.showRemoteImages()
                }
                guard selectedThreadID == id else { return }
                selectedThread = rendered
                isLoadingThread = false
            } catch {
                guard selectedThreadID == id else { return }
                isLoadingThread = false
                mailboxPhase = .failed(error.localizedDescription)
            }
        }
    }

    func selectThreads(ids: Set<String>) {
        selectedThreadIDs = ids
        selectThread(id: ids.count == 1 ? ids.first : nil)
    }

    func selectNextConversation() {
        guard !inbox.isEmpty else { return }
        let index = selectedThreadID.flatMap { id in inbox.firstIndex(where: { $0.id == id }) }
        let nextIndex = min((index ?? -1) + 1, inbox.count - 1)
        selectThreads(ids: [inbox[nextIndex].id])
    }

    func selectPreviousConversation() {
        guard !inbox.isEmpty else { return }
        let index = selectedThreadID.flatMap { id in inbox.firstIndex(where: { $0.id == id }) }
        let previousIndex = max((index ?? 1) - 1, 0)
        selectThreads(ids: [inbox[previousIndex].id])
    }

    func clearConversationSelection() {
        selectThreads(ids: [])
    }

    var mailboxes: [MailboxDescriptor] {
        let userLabels = labels
            .filter { $0.type.caseInsensitiveCompare("user") == .orderedSame }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { MailboxDescriptor.userLabel(id: $0.id, name: $0.name) }
        return MailboxDescriptor.builtIns + userLabels
    }

    var selectedMailbox: MailboxDescriptor {
        mailboxes.first { $0.id == selectedMailboxID } ?? .primary
    }

    var selectedMailboxTitle: String {
        selectedMailboxID == "__search__" ? "Search" : selectedMailbox.title
    }

    func count(for mailbox: MailboxDescriptor) -> Int? {
        let visibleCountMailboxes: Set<String> = [
            "primary", "unread", "social", "promotions", "updates", "starred", "drafts", "spam", "important",
        ]
        guard visibleCountMailboxes.contains(mailbox.id) else { return nil }
        if mailbox.id == "unread" {
            return labels.first { $0.id == "INBOX" }?.threadsUnread
        }
        let countLabel = mailbox.labelIDs.last
        guard let countLabel else { return nil }
        return labels.first { $0.id == countLabel }?.threadsTotal
    }

    func selectMailbox(id: String?) {
        guard let id, let mailbox = mailboxes.first(where: { $0.id == id }) else { return }
        selectedMailboxID = id
        searchText = ""
        selectedThreadID = nil
        selectedThreadIDs = []
        selectedThread = nil
        resetSearchPagination()
        if mailbox.id == MailboxDescriptor.primary.id {
            inbox = primaryInbox
            refreshMailbox()
        } else {
            loadMailbox(mailbox)
        }
    }

    func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            if selectedMailboxID == "__search__" { selectMailbox(id: MailboxDescriptor.primary.id) }
            return
        }
        selectedMailboxID = "__search__"
        selectedThreadID = nil
        selectedThread = nil
        viewTask?.cancel()
        activeSearchQuery = query
        searchNextPageToken = nil
        isLoadingMoreSearchResults = false
        mailboxPhase = .loading
        inbox = []
        viewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await validAccessToken()
                let page = try await gmail.mailboxPage(
                    labelIDs: [],
                    query: query,
                    accessToken: token,
                    maxResults: 50
                )
                if let account = state.profile?.emailAddress {
                    try await store.saveCorrespondents(account: account, from: page.summaries)
                }
                guard selectedMailboxID == "__search__", searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                inbox = page.summaries
                searchNextPageToken = page.nextPageToken
                mailboxPhase = .loaded(Date())
            } catch is CancellationError {
                return
            } catch {
                guard selectedMailboxID == "__search__" else { return }
                mailboxPhase = .failed(error.localizedDescription)
                presentedError = "Search failed: \(error.localizedDescription)"
            }
        }
    }

    func loadMoreSearchResultsIfNeeded(currentThreadID: String) {
        guard selectedMailboxID == "__search__",
              !isLoadingMoreSearchResults,
              let query = activeSearchQuery,
              searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query,
              let pageToken = searchNextPageToken,
              let index = inbox.firstIndex(where: { $0.id == currentThreadID }),
              index >= max(0, inbox.count - 5)
        else { return }

        isLoadingMoreSearchResults = true
        Task { [weak self] in
            guard let self else { return }
            defer { isLoadingMoreSearchResults = false }
            do {
                let token = try await validAccessToken()
                let known = Dictionary(uniqueKeysWithValues: inbox.map { ($0.id, $0) })
                let page = try await gmail.mailboxPage(
                    labelIDs: [],
                    query: query,
                    accessToken: token,
                    maxResults: 50,
                    pageToken: pageToken,
                    known: known
                )
                if let account = state.profile?.emailAddress {
                    try await store.saveCorrespondents(account: account, from: page.summaries)
                }
                guard selectedMailboxID == "__search__", activeSearchQuery == query else { return }
                let existing = Set(inbox.map(\.id))
                inbox.append(contentsOf: page.summaries.filter { !existing.contains($0.id) })
                searchNextPageToken = page.nextPageToken
            } catch is CancellationError {
                return
            } catch {
                guard selectedMailboxID == "__search__", activeSearchQuery == query else { return }
                presentedError = "Could not load more search results: \(error.localizedDescription)"
            }
        }
    }

    func searchTextChanged() {
        if searchText.isEmpty, selectedMailboxID == "__search__" {
            selectMailbox(id: MailboxDescriptor.primary.id)
        }
    }

    func refreshCurrentMailbox() {
        if selectedMailboxID == "__search__" {
            submitSearch()
        } else if selectedMailboxID == MailboxDescriptor.primary.id {
            refreshMailbox()
        } else {
            loadMailbox(selectedMailbox)
        }
    }

    func beginNewMessage() {
        guard state.profile != nil else { return }
        resetDraftSession()
        composeDraft = ComposeDraft()
        clearAddressSuggestions()
        isComposing = true
    }

    var canRespondToSelectedThread: Bool { selectedThread?.replyContext != nil }
    var canEditSelectedDraft: Bool { selectedMailboxID == "drafts" && selectedThreadID != nil }

    func beginResponse(_ kind: ResponseKind) {
        guard let context = selectedThread?.replyContext,
              let ownAddress = state.profile?.emailAddress
        else { return }
        resetDraftSession()
        composeDraft = ResponseDraftBuilder.draft(for: kind, context: context, ownAddress: ownAddress)
        clearAddressSuggestions()
        isComposing = true
    }

    func beginEditingSelectedDraft() async -> Bool {
        guard canEditSelectedDraft,
              !isLoadingEditableDraft,
              let threadID = selectedThreadID
        else { return false }
        isLoadingEditableDraft = true
        defer { isLoadingEditableDraft = false }
        do {
            let token = try await validAccessToken()
            guard let editable = try await gmail.editableDraft(threadID: threadID, accessToken: token) else {
                presentedError = "Gmail could not find an editable draft in this thread."
                return false
            }
            resetDraftSession()
            activeGmailDraftID = editable.id
            composeDraft = editable.draft
            draftSavePhase = .saved(Date())
            clearAddressSuggestions()
            isComposing = true
            return true
        } catch {
            presentedError = "Could not open Gmail draft: \(error.localizedDescription)"
            return false
        }
    }

    func dismissComposer() {
        guard !isSendingMessage else { return }
        isComposing = false
    }

    func finishComposing(_ draft: ComposeDraft) {
        if draft.hasDraftContent { scheduleDraftSave(draft, delay: .zero) }
        dismissComposer()
    }

    func scheduleDraftSave(_ draft: ComposeDraft, delay: Duration = .seconds(2)) {
        guard draft.hasDraftContent, state.profile != nil else { return }
        pendingDraftSave = (composeGeneration, draft)
        if isDraftSaveInFlight { return }
        draftAutosaveTask?.cancel()
        draftSavePhase = .waiting
        let generation = composeGeneration
        draftAutosaveTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.performPendingDraftSave(generation: generation)
        }
    }

    var isSavingDraft: Bool { isDraftSaveInFlight }

    func sendMessage(_ draft: ComposeDraft) {
        guard !isSendingMessage, !isDraftSaveInFlight, let from = state.profile?.emailAddress else { return }
        guard draft.canSend else {
            presentedError = MIMEMessageBuilder.BuildError.missingRecipient.localizedDescription
            return
        }
        isSendingMessage = true
        draftAutosaveTask?.cancel()
        pendingDraftSave = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await validAccessToken()
                let draftID = try await gmail.saveDraft(
                    draft,
                    from: from,
                    draftID: activeGmailDraftID,
                    accessToken: token
                )
                try await gmail.sendDraft(id: draftID, accessToken: token)
                activeGmailDraftID = nil
                draftSavePhase = .idle
                isSendingMessage = false
                isComposing = false
            } catch {
                isSendingMessage = false
                presentedError = "Could not send message: \(error.localizedDescription)"
            }
        }
    }

    func updateAddressSuggestions(for value: String) {
        addressSuggestionTask?.cancel()
        guard let account = state.profile?.emailAddress else {
            addressSuggestions = []
            return
        }
        let fragment = value.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard fragment.count >= 2 else {
            addressSuggestions = []
            return
        }
        addressSuggestionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let local = try await store.searchCorrespondents(account: account, matching: fragment, limit: 12)
                guard !Task.isCancelled else { return }
                let needle = fragment.lowercased()
                let remote = googleContacts.filter {
                    $0.name.lowercased().contains(needle) || $0.email.lowercased().contains(needle)
                }
                var seen = Set<String>()
                addressSuggestions = (remote + local).filter { seen.insert($0.email.lowercased()).inserted }.prefix(8).map { $0 }
                if contactsTokens != nil {
                    do {
                        let token = try await validContactsAccessToken()
                        let other = try await googleContactsClient.searchOtherContacts(query: fragment, accessToken: token)
                        guard !Task.isCancelled else { return }
                        seen.removeAll()
                        addressSuggestions = (remote + other + local)
                            .filter { seen.insert($0.email.lowercased()).inserted }
                            .prefix(8).map { $0 }
                    } catch {
                        // Keep cached formal contacts and local correspondents available offline.
                    }
                }
            } catch {
                addressSuggestions = []
            }
        }
    }

    func clearAddressSuggestions() {
        addressSuggestionTask?.cancel()
        addressSuggestions = []
    }

    func connectGoogleContacts() {
        guard contactsPhase != .connecting,
              let configuration = OAuthConfigurationStore.load(),
              let account = state.profile?.emailAddress
        else { return }
        contactsPhase = .connecting
        Task { [weak self] in
            guard let self else { return }
            do {
                let tokens = try await auth.authorize(
                    configuration: configuration,
                    scope: "https://www.googleapis.com/auth/contacts.readonly https://www.googleapis.com/auth/contacts.other.readonly",
                    loginHint: account
                )
                try TokenStore.saveContacts(tokens)
                contactsTokens = tokens
                contactsPhase = .loading
                try await refreshGoogleContacts()
            } catch is CancellationError {
                contactsPhase = .disconnected
            } catch {
                contactsPhase = .failed(error.localizedDescription)
            }
        }
    }

    func disconnectGoogleContacts() {
        try? TokenStore.deleteContacts()
        GoogleContactsCache.delete()
        contactsTokens = nil
        googleContacts = []
        contactsPhase = .disconnected
        UserDefaults.standard.set(false, forKey: "dismissedContactsBanner")
        addressSuggestions = []
    }

    func retryGoogleContacts() {
        guard contactsPhase != .connecting, contactsPhase != .loading else { return }
        guard contactsTokens != nil else {
            connectGoogleContacts()
            return
        }
        contactsPhase = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                try await refreshGoogleContacts()
            } catch {
                if Reliability.requiresReauthentication(error) {
                    disconnectGoogleContacts()
                } else {
                    contactsPhase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func restoreGoogleContacts() async {
        googleContacts = GoogleContactsCache.load()
        guard let tokens = try? TokenStore.loadContacts() else {
            contactsPhase = .disconnected
            return
        }
        contactsTokens = tokens
        contactsPhase = .connected(googleContacts.count)
        do {
            try await refreshGoogleContacts()
        } catch {
            if Reliability.requiresReauthentication(error) {
                disconnectGoogleContacts()
            } else {
                contactsPhase = .failed(error.localizedDescription)
            }
        }
    }

    private func refreshGoogleContacts() async throws {
        guard var tokens = contactsTokens,
              let configuration = OAuthConfigurationStore.load()
        else { return }
        if tokens.needsRefresh {
            tokens = try await auth.refresh(tokens, configuration: configuration)
            try TokenStore.saveContacts(tokens)
            contactsTokens = tokens
        }
        do {
            let contacts = try await googleContactsClient.contacts(accessToken: tokens.accessToken)
            googleContacts = contacts
            try GoogleContactsCache.save(contacts)
            contactsPhase = .connected(contacts.count)
        } catch GoogleContactsError.requestFailed(let status, _) where status == 401 {
            disconnectGoogleContacts()
            throw GoogleContactsError.requestFailed(status: status, message: "Authorization expired")
        }
    }

    private func validContactsAccessToken() async throws -> String {
        guard var tokens = contactsTokens,
              let configuration = OAuthConfigurationStore.load()
        else { throw OAuthError.missingRefreshToken }
        if tokens.needsRefresh {
            tokens = try await auth.refresh(tokens, configuration: configuration)
            try TokenStore.saveContacts(tokens)
            contactsTokens = tokens
        }
        return tokens.accessToken
    }

    private func performPendingDraftSave(generation: UUID) async {
        guard generation == composeGeneration,
              !isDraftSaveInFlight,
              let pending = pendingDraftSave,
              pending.generation == generation,
              let from = state.profile?.emailAddress
        else { return }
        pendingDraftSave = nil
        isDraftSaveInFlight = true
        draftSavePhase = .saving
        let draftID = activeGmailDraftID
        do {
            let token = try await validAccessToken()
            let savedID = try await gmail.saveDraft(
                pending.draft,
                from: from,
                draftID: draftID,
                accessToken: token
            )
            guard generation == composeGeneration else {
                isDraftSaveInFlight = false
                if let next = pendingDraftSave {
                    scheduleDraftSave(next.draft, delay: .seconds(1))
                }
                return
            }
            activeGmailDraftID = savedID
            isDraftSaveInFlight = false
            draftSavePhase = .saved(Date())
            if let next = pendingDraftSave, next.generation == generation {
                scheduleDraftSave(next.draft, delay: .seconds(1))
            }
        } catch is CancellationError {
            isDraftSaveInFlight = false
            if let next = pendingDraftSave {
                scheduleDraftSave(next.draft, delay: .seconds(1))
            }
        } catch {
            isDraftSaveInFlight = false
            if generation == composeGeneration {
                draftSavePhase = .failed(error.localizedDescription)
            } else if let next = pendingDraftSave {
                scheduleDraftSave(next.draft, delay: .seconds(1))
            }
        }
    }

    private func resetDraftSession() {
        draftAutosaveTask?.cancel()
        pendingDraftSave = nil
        composeGeneration = UUID()
        activeGmailDraftID = nil
        draftSavePhase = .idle
    }

    func downloadAttachment(_ attachment: MailAttachment) {
        guard downloadingAttachmentID == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Save Attachment"
        panel.nameFieldStringValue = attachment.filename
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        downloadingAttachmentID = attachment.id
        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await validAccessToken()
                let data = try await gmail.attachmentData(attachment, accessToken: token)
                try data.write(to: destination, options: .atomic)
            } catch {
                presentedError = error.localizedDescription
            }
            downloadingAttachmentID = nil
        }
    }

    func showRemoteImagesForSelectedThread(alwaysForSender: Bool = false) {
        guard var thread = selectedThread else { return }
        if alwaysForSender {
            RemoteImagePreferences.allow(sender: thread.remoteImageSender)
        }
        thread.showRemoteImages()
        selectedThread = thread
    }

    var selectedSummary: ThreadSummary? {
        guard let selectedThreadID else { return nil }
        return inbox.first { $0.id == selectedThreadID }
    }

    var selectedSummaries: [ThreadSummary] {
        inbox.filter { selectedThreadIDs.contains($0.id) }
    }

    var userLabels: [GmailLabel] {
        labels.filter { $0.type.caseInsensitiveCompare("user") == .orderedSame }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func labelState(_ label: GmailLabel) -> (applied: Int, total: Int) {
        labelState(label, threadIDs: selectedThreadIDs)
    }

    func labelState(_ label: GmailLabel, threadIDs: Set<String>) -> (applied: Int, total: Int) {
        let summaries = inbox.filter { threadIDs.contains($0.id) }
        return (summaries.filter { $0.labelIDs.contains(label.id) }.count, summaries.count)
    }

    func perform(_ action: MailboxAction, on threadIDs: Set<String>) {
        if selectedThreadIDs != threadIDs { selectThreads(ids: threadIDs) }
        perform(action)
    }

    func toggleLabel(_ label: GmailLabel, on threadIDs: Set<String>) {
        if selectedThreadIDs != threadIDs { selectThreads(ids: threadIDs) }
        toggleLabel(label)
    }

    func toggleLabel(_ label: GmailLabel) {
        let summaries = selectedSummaries
        guard !summaries.isEmpty, !actionInProgress, let account = state.profile?.emailAddress else { return }
        let shouldApply = summaries.contains { !$0.labelIDs.contains(label.id) }
        let previousInbox = inbox
        let previousPrimary = primaryInbox
        let updated = summaries.map { summary in
            var ids = summary.labelIDs
            if shouldApply { ids.insert(label.id) } else { ids.remove(label.id) }
            return summary.changing(labelIDs: ids)
        }
        replaceSummaries(updated)
        let replacements = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        primaryInbox = primaryInbox.map { replacements[$0.id] ?? $0 }
        actionInProgress = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await validAccessToken()
                for summary in summaries {
                    try await gmail.modifyThread(
                        id: summary.id,
                        addLabelIDs: shouldApply ? [label.id] : [],
                        removeLabelIDs: shouldApply ? [] : [label.id],
                        accessToken: token
                    )
                }
                try await store.updateSummaries(account: account, upserts: updated)
                actionInProgress = false
                await loadLabels()
            } catch {
                inbox = previousInbox
                primaryInbox = previousPrimary
                actionInProgress = false
                presentedError = "Could not update label ‘\(label.name)’: \(error.localizedDescription)"
            }
        }
    }

    func perform(_ action: MailboxAction) {
        if selectedSummaries.count > 1 {
            performBatch(action)
            return
        }
        guard !actionInProgress, let summary = selectedSummary, let account = state.profile?.emailAddress else { return }
        let previousInbox = inbox
        let previousPrimaryInbox = primaryInbox
        let previousThread = selectedThread
        let previousID = selectedThreadID
        let updated: ThreadSummary?

        switch action {
        case .archive, .trash, .spam:
            updated = nil
            inbox.removeAll { $0.id == summary.id }
            selectedThread = nil
            selectedThreadID = nil
            selectedThreadIDs = []
        case .toggleStar:
            updated = summary.changing(isStarred: !summary.isStarred)
            replaceSummary(updated!)
        case .toggleRead:
            updated = summary.changing(isUnread: !summary.isUnread)
            if selectedMailboxID == "unread", summary.isUnread {
                inbox.removeAll { $0.id == summary.id }
                selectedThread = nil
                selectedThreadID = nil
                selectedThreadIDs = []
            } else {
                replaceSummary(updated!)
            }
        }
        if selectedMailboxID == MailboxDescriptor.primary.id { primaryInbox = inbox }

        actionInProgress = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await validAccessToken()
                switch action {
                case .archive:
                    try await gmail.modifyThread(id: summary.id, removeLabelIDs: ["INBOX"], accessToken: token)
                case .trash:
                    try await gmail.trashThread(id: summary.id, accessToken: token)
                case .spam:
                    try await gmail.modifyThread(
                        id: summary.id,
                        addLabelIDs: ["SPAM"],
                        removeLabelIDs: ["INBOX"],
                        accessToken: token
                    )
                case .toggleStar:
                    try await gmail.modifyThread(
                        id: summary.id,
                        addLabelIDs: summary.isStarred ? [] : ["STARRED"],
                        removeLabelIDs: summary.isStarred ? ["STARRED"] : [],
                        accessToken: token
                    )
                case .toggleRead:
                    try await gmail.modifyThread(
                        id: summary.id,
                        addLabelIDs: summary.isUnread ? [] : ["UNREAD"],
                        removeLabelIDs: summary.isUnread ? ["UNREAD"] : [],
                        accessToken: token
                    )
                }
                if let updated {
                    try await store.updateSummaries(account: account, upserts: [updated])
                } else {
                    try await store.updateSummaries(account: account, removals: [summary.id])
                }
                actionInProgress = false
            } catch {
                inbox = previousInbox
                primaryInbox = previousPrimaryInbox
                selectedThread = previousThread
                selectedThreadID = previousID
                actionInProgress = false
                presentedError = error.localizedDescription
            }
        }
    }

    func markAllRead() {
        guard !isMarkingAllRead, state.profile != nil else { return }
        isMarkingAllRead = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await validAccessToken()
                try await gmail.markAllInboxRead(accessToken: token)
                isMarkingAllRead = false
                await loadLabels()
                refreshCurrentMailbox()
            } catch {
                isMarkingAllRead = false
                presentedError = "Could not mark all messages read: \(error.localizedDescription)"
            }
        }
    }

    private func performBatch(_ action: MailboxAction) {
        guard !actionInProgress,
              !selectedSummaries.isEmpty,
              let account = state.profile?.emailAddress
        else { return }
        let summaries = selectedSummaries
        let previousInbox = inbox
        let previousPrimaryInbox = primaryInbox
        let previousSelection = selectedThreadIDs
        let updated: [ThreadSummary]
        let removedFromView: Bool
        let targetStarred = summaries.contains { !$0.isStarred }
        let targetUnread = summaries.allSatisfy { !$0.isUnread }

        switch action {
        case .archive, .trash, .spam:
            updated = []
            removedFromView = true
            let ids = Set(summaries.map(\.id))
            inbox.removeAll { ids.contains($0.id) }
        case .toggleStar:
            updated = summaries.map { $0.changing(isStarred: targetStarred) }
            removedFromView = false
            replaceSummaries(updated)
        case .toggleRead:
            updated = summaries.map { $0.changing(isUnread: targetUnread) }
            removedFromView = selectedMailboxID == "unread" && !targetUnread
            if removedFromView {
                let ids = Set(summaries.map(\.id))
                inbox.removeAll { ids.contains($0.id) }
            } else {
                replaceSummaries(updated)
            }
        }
        if removedFromView { selectedThreadIDs = [] }
        if selectedMailboxID == MailboxDescriptor.primary.id { primaryInbox = inbox }

        actionInProgress = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await validAccessToken()
                for summary in summaries {
                    switch action {
                    case .archive:
                        try await gmail.modifyThread(id: summary.id, removeLabelIDs: ["INBOX"], accessToken: token)
                    case .trash:
                        try await gmail.trashThread(id: summary.id, accessToken: token)
                    case .spam:
                        try await gmail.modifyThread(
                            id: summary.id,
                            addLabelIDs: ["SPAM"],
                            removeLabelIDs: ["INBOX"],
                            accessToken: token
                        )
                    case .toggleStar:
                        try await gmail.modifyThread(
                            id: summary.id,
                            addLabelIDs: targetStarred ? ["STARRED"] : [],
                            removeLabelIDs: targetStarred ? [] : ["STARRED"],
                            accessToken: token
                        )
                    case .toggleRead:
                        try await gmail.modifyThread(
                            id: summary.id,
                            addLabelIDs: targetUnread ? ["UNREAD"] : [],
                            removeLabelIDs: targetUnread ? [] : ["UNREAD"],
                            accessToken: token
                        )
                    }
                }
                if [.archive, .trash, .spam].contains(action) {
                    try await store.updateSummaries(account: account, removals: Set(summaries.map(\.id)))
                } else {
                    try await store.updateSummaries(account: account, upserts: updated)
                }
                actionInProgress = false
                await loadLabels()
            } catch {
                inbox = previousInbox
                primaryInbox = previousPrimaryInbox
                selectedThreadIDs = previousSelection
                actionInProgress = false
                presentedError = "Batch action failed: \(error.localizedDescription)"
                refreshCurrentMailbox()
            }
        }
    }

    private func replaceSummaries(_ summaries: [ThreadSummary]) {
        let replacements = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        inbox = inbox.map { replacements[$0.id] ?? $0 }
    }

    func removeOAuthConfiguration() {
        signOut()
        OAuthConfigurationStore.delete()
        state.hasOAuthConfiguration = false
    }

    private func restoreSession() async {
        guard let configuration = OAuthConfigurationStore.load(),
              let storedTokens = try? TokenStore.load()
        else {
            state.phase = .signedOut
            return
        }

        do {
            let tokens: OAuthTokens
            if storedTokens.needsRefresh {
                tokens = try await auth.refresh(storedTokens, configuration: configuration)
                try TokenStore.save(tokens)
            } else {
                tokens = storedTokens
            }
            oauthTokens = tokens
            let profile = try await gmail.profile(accessToken: tokens.accessToken)
            state.profile = profile
            CachedProfileStore.save(profile)
            await startMailbox()
            state.phase = .signedIn
            await restoreGoogleContacts()
        } catch {
            if Reliability.requiresReauthentication(error) {
                requireReauthentication()
            } else if Reliability.isOffline(error),
                      let tokens = try? TokenStore.load(),
                      let cachedProfile = CachedProfileStore.load() {
                oauthTokens = tokens
                state.profile = cachedProfile
                state.phase = .signedIn
                isOffline = true
                await startMailbox(shouldRefresh: false)
                mailboxPhase = .failed(error.localizedDescription)
            } else {
                state.phase = .failed("Could not restore the Gmail session: \(error.localizedDescription)")
            }
        }
    }

    private func startMailbox(shouldRefresh: Bool = true) async {
        if let account = state.profile?.emailAddress,
           let cached = try? await store.cachedInbox(account: account), !cached.isEmpty {
            primaryInbox = cached
            inbox = cached
            lastSuccessfulSync = SyncFreshnessStore.load(account: account)
            mailboxPhase = .loaded(lastSuccessfulSync ?? .distantPast)
        }
        if shouldRefresh {
            Task { [weak self] in await self?.loadLabels() }
        }
        if shouldRefresh { refreshMailbox() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.refreshMailbox()
            }
        }
    }

    private func loadLabels() async {
        do {
            let token = try await validAccessToken()
            labels = try await gmail.labels(accessToken: token)
        } catch {
            presentedError = "Could not load Gmail labels: \(error.localizedDescription)"
        }
    }

    private func loadMailbox(_ mailbox: MailboxDescriptor) {
        viewTask?.cancel()
        mailboxPhase = .loading
        inbox = []
        viewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await validAccessToken()
                let values = try await gmail.mailbox(
                    labelIDs: mailbox.labelIDs,
                    query: mailbox.query,
                    accessToken: token
                )
                if let account = state.profile?.emailAddress {
                    try await store.saveCorrespondents(account: account, from: values)
                }
                guard selectedMailboxID == mailbox.id else { return }
                inbox = values
                mailboxPhase = .loaded(Date())
            } catch is CancellationError {
                return
            } catch {
                guard selectedMailboxID == mailbox.id else { return }
                mailboxPhase = .failed(error.localizedDescription)
                presentedError = error.localizedDescription
            }
        }
    }

    private func fullMailboxSync(account: String, accessToken: String) async throws {
        let summaries = try await gmail.inbox(accessToken: accessToken)
        let currentProfile = try await gmail.profile(accessToken: accessToken)
        try await store.replaceInbox(
            account: account,
            summaries: summaries,
            historyID: currentProfile.historyId
        )
    }

    private func reconcilePrimaryMailbox(account: String, accessToken: String) async throws {
        let cached = try await store.cachedInbox(account: account)
        let known = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0) })
        let summaries = try await gmail.mailbox(
            labelIDs: MailboxDescriptor.primary.labelIDs,
            query: MailboxDescriptor.primary.query,
            accessToken: accessToken,
            maxResults: 24,
            known: known,
            requiredLabelIDs: Set(MailboxDescriptor.primary.labelIDs)
        )
        let historyID: String
        if let saved = try await store.historyID(account: account) {
            historyID = saved
        } else {
            historyID = try await gmail.profile(accessToken: accessToken).historyId
        }
        try await store.replaceInbox(account: account, summaries: summaries, historyID: historyID)
    }

    private func replaceSummary(_ summary: ThreadSummary) {
        guard let index = inbox.firstIndex(where: { $0.id == summary.id }) else { return }
        inbox[index] = summary
    }

    private func resetSearchPagination() {
        activeSearchQuery = nil
        searchNextPageToken = nil
        isLoadingMoreSearchResults = false
    }

    private func validAccessToken() async throws -> String {
        guard let storedTokens = oauthTokens else { throw OAuthError.missingRefreshToken }
        if !storedTokens.needsRefresh { return storedTokens.accessToken }
        guard let configuration = OAuthConfigurationStore.load() else { throw OAuthError.missingRefreshToken }
        let task: Task<OAuthTokens, Error>
        if let existing = tokenRefreshTask {
            task = existing
        } else {
            task = Task { [auth] in
                let refreshed = try await auth.refresh(storedTokens, configuration: configuration)
                try TokenStore.save(refreshed)
                return refreshed
            }
            tokenRefreshTask = task
        }
        defer { tokenRefreshTask = nil }
        let refreshed = try await task.value
        oauthTokens = refreshed
        return refreshed.accessToken
    }

    private func requireReauthentication() {
        try? TokenStore.delete()
        oauthTokens = nil
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
        mailboxTask?.cancel()
        pollTask?.cancel()
        isRefreshingMailbox = false
        state.phase = .failed("Your Google session has expired or was revoked. Sign in again to reconnect OpenMime; cached mail remains on this Mac.")
    }
}

enum RemoteImagePreferences {
    private static let key = "remoteImageAllowedSenders"

    static func isAllowed(sender: String) -> Bool {
        allowedSenders.contains(sender.lowercased())
    }

    static func allow(sender: String) {
        var senders = allowedSenders
        senders.insert(sender.lowercased())
        UserDefaults.standard.set(Array(senders).sorted(), forKey: key)
    }

    private static var allowedSenders: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }
}
