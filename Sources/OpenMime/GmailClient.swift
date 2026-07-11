import Foundation

struct GmailProfile: Codable, Equatable, Sendable {
    let emailAddress: String
    let messagesTotal: Int
    let threadsTotal: Int
    let historyId: String
}

struct ThreadSummary: Identifiable, Equatable, Sendable {
    let id: String
    let sender: String
    let subject: String
    let snippet: String
    let date: Date
    let isUnread: Bool
    let isStarred: Bool
    let messageCount: Int
    let attachmentNames: [String]
    var labelIDs: Set<String> = []
    var correspondents: [EmailContact] = []

    func changing(isUnread: Bool? = nil, isStarred: Bool? = nil, labelIDs: Set<String>? = nil) -> ThreadSummary {
        ThreadSummary(
            id: id,
            sender: sender,
            subject: subject,
            snippet: snippet,
            date: date,
            isUnread: isUnread ?? self.isUnread,
            isStarred: isStarred ?? self.isStarred,
            messageCount: messageCount,
            attachmentNames: attachmentNames,
            labelIDs: labelIDs ?? self.labelIDs,
            correspondents: correspondents
        )
    }
}

struct EmailContact: Identifiable, Codable, Equatable, Sendable {
    var id: String { email }
    let name: String
    let email: String

    var formattedAddress: String {
        name.isEmpty || name.caseInsensitiveCompare(email) == .orderedSame ? email : "\(name) <\(email)>"
    }
}

struct MailMessage: Identifiable, Equatable, Sendable {
    let id: String
    let sender: String
    let recipients: String
    let cc: String
    let replyTo: String?
    let subject: String
    let date: Date
    let messageIDHeader: String?
    let references: String?
    let htmlBody: String?
    let plainBody: String?
    let attachments: [MailAttachment]

    init(
        id: String,
        sender: String,
        recipients: String,
        cc: String = "",
        replyTo: String? = nil,
        subject: String,
        date: Date,
        messageIDHeader: String? = nil,
        references: String? = nil,
        htmlBody: String?,
        plainBody: String?,
        attachments: [MailAttachment]
    ) {
        self.id = id
        self.sender = sender
        self.recipients = recipients
        self.cc = cc
        self.replyTo = replyTo
        self.subject = subject
        self.date = date
        self.messageIDHeader = messageIDHeader
        self.references = references
        self.htmlBody = htmlBody
        self.plainBody = plainBody
        self.attachments = attachments
    }

    func replacingHTMLBody(_ htmlBody: String?) -> MailMessage {
        MailMessage(
            id: id,
            sender: sender,
            recipients: recipients,
            cc: cc,
            replyTo: replyTo,
            subject: subject,
            date: date,
            messageIDHeader: messageIDHeader,
            references: references,
            htmlBody: htmlBody,
            plainBody: plainBody,
            attachments: attachments
        )
    }
}

struct MailAttachment: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let messageID: String
    let filename: String
    let mimeType: String
    let size: Int
    let contentID: String?
}

struct MailThread: Identifiable, Equatable, Sendable {
    let id: String
    let subject: String
    let messages: [MailMessage]
}

struct GmailHistoryDelta: Equatable, Sendable {
    let historyID: String
    let changedThreadIDs: Set<String>
    let removedThreadIDs: Set<String>
}

struct ThreadSummaryChanges: Equatable, Sendable {
    let upserts: [ThreadSummary]
    let removals: Set<String>
}

struct GmailEditableDraft: Sendable {
    let id: String
    let draft: ComposeDraft
}

struct GmailClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func profile(accessToken: String) async throws -> GmailProfile {
        try await get(path: "/gmail/v1/users/me/profile", accessToken: accessToken)
    }

    func inbox(
        accessToken: String,
        maxResults: Int = 24,
        known: [String: ThreadSummary] = [:]
    ) async throws -> [ThreadSummary] {
        try await mailbox(
            labelIDs: MailboxDescriptor.primary.labelIDs,
            query: MailboxDescriptor.primary.query,
            accessToken: accessToken,
            maxResults: maxResults,
            known: known,
            requiredLabelIDs: Set(MailboxDescriptor.primary.labelIDs)
        )
    }

    func mailbox(
        labelIDs: [String],
        query: String?,
        accessToken: String,
        maxResults: Int = 24,
        known: [String: ThreadSummary] = [:],
        requiredLabelIDs: Set<String>? = nil
    ) async throws -> [ThreadSummary] {
        try await mailboxPage(
            labelIDs: labelIDs,
            query: query,
            accessToken: accessToken,
            maxResults: maxResults,
            known: known,
            requiredLabelIDs: requiredLabelIDs
        ).summaries
    }

    func mailboxPage(
        labelIDs: [String],
        query: String?,
        accessToken: String,
        maxResults: Int = 24,
        pageToken: String? = nil,
        known: [String: ThreadSummary] = [:],
        requiredLabelIDs: Set<String>? = nil
    ) async throws -> GmailMailboxPage {
        let queryItems = Self.threadListQueryItems(
            labelIDs: labelIDs,
            query: query,
            maxResults: maxResults,
            pageToken: pageToken
        )
        let page: ThreadListResponse = try await get(
            path: "/gmail/v1/users/me/threads",
            query: queryItems,
            accessToken: accessToken
        )
        let references = page.threads ?? []
        var summaries = references.compactMap { known[$0.id] }
        summaries.reserveCapacity(references.count)
        let missing = references.filter { known[$0.id] == nil }

        for batchStart in stride(from: 0, to: missing.count, by: 12) {
            let batch = missing[batchStart..<min(batchStart + 12, missing.count)]
            let fetched = try await withThrowingTaskGroup(of: ThreadSummary.self) { group in
                for reference in batch {
                    group.addTask {
                        try await summary(
                            id: reference.id,
                            accessToken: accessToken,
                            requiredLabelIDs: requiredLabelIDs
                        )
                    }
                }
                var values: [ThreadSummary] = []
                for try await value in group { values.append(value) }
                return values
            }
            summaries.append(contentsOf: fetched)
        }
        return GmailMailboxPage(
            summaries: summaries.sorted { $0.date > $1.date },
            nextPageToken: page.nextPageToken
        )
    }

    static func threadListQueryItems(
        labelIDs: [String],
        query: String?,
        maxResults: Int,
        pageToken: String? = nil
    ) -> [URLQueryItem] {
        var items = labelIDs.map { URLQueryItem(name: "labelIds", value: $0) }
        items.append(URLQueryItem(name: "maxResults", value: String(maxResults)))
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let pageToken, !pageToken.isEmpty { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return items
    }

    func labels(accessToken: String) async throws -> [GmailLabel] {
        let list: LabelListResponse = try await get(path: "/gmail/v1/users/me/labels", accessToken: accessToken)
        let labels = list.labels ?? []
        let featured = Set(MailboxDescriptor.builtIns.flatMap(\.labelIDs))
        var details: [String: LabelResource] = [:]
        try await withThrowingTaskGroup(of: LabelResource.self) { group in
            for label in labels where featured.contains(label.id) {
                group.addTask {
                    try await get(path: "/gmail/v1/users/me/labels/\(label.id)", accessToken: accessToken)
                }
            }
            for try await detail in group { details[detail.id] = detail }
        }
        return labels.map { label in
            let detail = details[label.id] ?? label
            return GmailLabel(
                id: label.id,
                name: label.name,
                type: label.type,
                threadsTotal: detail.threadsTotal,
                threadsUnread: detail.threadsUnread
            )
        }
    }

    func thread(id: String, accessToken: String) async throws -> MailThread {
        let resource: ThreadResource = try await get(
            path: "/gmail/v1/users/me/threads/\(id)",
            query: [URLQueryItem(name: "format", value: "full")],
            accessToken: accessToken
        )
        var messages = (resource.messages ?? []).map { message in
            MailMessage(
                id: message.id,
                sender: message.header("From") ?? "Unknown sender",
                recipients: message.header("To") ?? "",
                cc: message.header("Cc") ?? "",
                replyTo: message.header("Reply-To"),
                subject: message.header("Subject") ?? "(No subject)",
                date: message.messageDate,
                messageIDHeader: message.header("Message-ID"),
                references: message.header("References"),
                htmlBody: message.payload?.decodedBody(mimeType: "text/html"),
                plainBody: message.payload?.decodedBody(mimeType: "text/plain"),
                attachments: message.payload?.attachments(messageID: message.id) ?? []
            )
        }.sorted { $0.date < $1.date }
        messages = await hydrateInlineImages(in: messages, accessToken: accessToken)
        return MailThread(id: resource.id, subject: messages.last?.subject ?? "(No subject)", messages: messages)
    }

    func history(since startHistoryID: String, accessToken: String) async throws -> GmailHistoryDelta {
        var pageToken: String?
        var latestHistoryID = startHistoryID
        var changed: Set<String> = []
        var removed: Set<String> = []

        repeat {
            var query = [
                URLQueryItem(name: "startHistoryId", value: startHistoryID),
                URLQueryItem(name: "maxResults", value: "100"),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: HistoryListResponse = try await get(
                path: "/gmail/v1/users/me/history",
                query: query,
                accessToken: accessToken
            )
            latestHistoryID = page.historyId ?? latestHistoryID
            for record in page.history ?? [] {
                latestHistoryID = record.id
                for change in record.messagesAdded ?? [] {
                    changed.insert(change.message.threadId)
                }
                for change in record.labelsAdded ?? [] {
                    changed.insert(change.message.threadId)
                }
                for change in record.labelsRemoved ?? [] {
                    changed.insert(change.message.threadId)
                    if change.labelIds.contains("INBOX") { removed.insert(change.message.threadId) }
                }
                for change in record.messagesDeleted ?? [] {
                    changed.insert(change.message.threadId)
                }
            }
            pageToken = page.nextPageToken
        } while pageToken != nil

        return GmailHistoryDelta(
            historyID: latestHistoryID,
            changedThreadIDs: changed,
            removedThreadIDs: removed
        )
    }

    func summariesForChangedThreads(
        ids: Set<String>,
        accessToken: String
    ) async throws -> ThreadSummaryChanges {
        var upserts: [ThreadSummary] = []
        var removals: Set<String> = []
        let ordered = ids.sorted()
        for batchStart in stride(from: 0, to: ordered.count, by: 12) {
            let batch = ordered[batchStart..<min(batchStart + 12, ordered.count)]
            let values = try await withThrowingTaskGroup(of: (String, ThreadSummary?).self) { group in
                for id in batch {
                    group.addTask {
                        do {
                            return (id, try await summary(
                                id: id,
                                accessToken: accessToken,
                                requiredLabelIDs: Set(MailboxDescriptor.primary.labelIDs)
                            ))
                        } catch GmailError.notInInbox {
                            return (id, nil)
                        } catch GmailError.requestFailed(let status, _) where status == 404 {
                            return (id, nil)
                        }
                    }
                }
                var result: [(String, ThreadSummary?)] = []
                for try await value in group { result.append(value) }
                return result
            }
            for (id, summary) in values {
                if let summary { upserts.append(summary) } else { removals.insert(id) }
            }
        }
        return ThreadSummaryChanges(upserts: upserts, removals: removals)
    }

    func modifyThread(
        id: String,
        addLabelIDs: [String] = [],
        removeLabelIDs: [String] = [],
        accessToken: String
    ) async throws {
        let body = try JSONEncoder().encode(ThreadModifyRequest(
            addLabelIds: addLabelIDs,
            removeLabelIds: removeLabelIDs
        ))
        try await post(path: "/gmail/v1/users/me/threads/\(id)/modify", body: body, accessToken: accessToken)
    }

    func trashThread(id: String, accessToken: String) async throws {
        try await post(path: "/gmail/v1/users/me/threads/\(id)/trash", body: Data("{}".utf8), accessToken: accessToken)
    }

    func markAllInboxRead(accessToken: String) async throws {
        var pageToken: String?
        var messageIDs: [String] = []
        repeat {
            var query = [
                URLQueryItem(name: "q", value: "is:unread in:inbox"),
                URLQueryItem(name: "maxResults", value: "500"),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: MessageListResponse = try await get(
                path: "/gmail/v1/users/me/messages",
                query: query,
                accessToken: accessToken
            )
            messageIDs.append(contentsOf: (page.messages ?? []).map(\.id))
            pageToken = page.nextPageToken
        } while pageToken != nil

        for batch in Self.batches(messageIDs, size: 1_000) {
            let body = try JSONEncoder().encode(BatchModifyRequest(
                ids: batch,
                addLabelIds: [],
                removeLabelIds: ["UNREAD"]
            ))
            try await post(path: "/gmail/v1/users/me/messages/batchModify", body: body, accessToken: accessToken)
        }
    }

    static func batches<T>(_ values: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: values.count, by: size).map {
            Array(values[$0..<min($0 + size, values.count)])
        }
    }

    func send(_ draft: ComposeDraft, from: String, accessToken: String) async throws {
        let raw = try await rawMessage(draft, from: from, accessToken: accessToken, requireRecipient: true)
        let body = try JSONEncoder().encode(SendMessageRequest(raw: raw, threadId: draft.threadID))
        try await post(path: "/gmail/v1/users/me/messages/send", body: body, accessToken: accessToken)
    }

    func saveDraft(
        _ draft: ComposeDraft,
        from: String,
        draftID: String?,
        accessToken: String
    ) async throws -> String {
        let raw = try await rawMessage(draft, from: from, accessToken: accessToken, requireRecipient: false)
        let body = try JSONEncoder().encode(DraftWriteRequest(
            message: SendMessageRequest(raw: raw, threadId: draft.threadID)
        ))
        let resource: DraftResource
        if let draftID {
            resource = try await writeReturning(
                method: "PUT",
                path: "/gmail/v1/users/me/drafts/\(draftID)",
                body: body,
                accessToken: accessToken
            )
        } else {
            resource = try await writeReturning(
                method: "POST",
                path: "/gmail/v1/users/me/drafts",
                body: body,
                accessToken: accessToken
            )
        }
        return resource.id
    }

    func sendDraft(id: String, accessToken: String) async throws {
        let body = try JSONEncoder().encode(DraftSendRequest(id: id))
        try await post(path: "/gmail/v1/users/me/drafts/send", body: body, accessToken: accessToken)
    }

    func editableDraft(threadID: String, accessToken: String) async throws -> GmailEditableDraft? {
        var pageToken: String?
        var match: DraftResource?
        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "100")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: DraftListResponse = try await get(
                path: "/gmail/v1/users/me/drafts",
                query: query,
                accessToken: accessToken
            )
            match = page.drafts?.first { $0.message?.threadId == threadID }
            pageToken = match == nil ? page.nextPageToken : nil
        } while match == nil && pageToken != nil
        guard let match else { return nil }

        let detail: DraftResource = try await get(
            path: "/gmail/v1/users/me/drafts/\(match.id)",
            query: [URLQueryItem(name: "format", value: "full")],
            accessToken: accessToken
        )
        guard let message = detail.message else { return nil }
        let plain = message.payload?.decodedBody(mimeType: "text/plain")
        let html = message.payload?.decodedBody(mimeType: "text/html")
        let attachments = (message.payload?.attachments(messageID: message.id) ?? [])
            .filter { $0.contentID == nil }
            .map(ComposeAttachment.gmail)
        return GmailEditableDraft(
            id: detail.id,
            draft: ComposeDraft(
                to: message.header("To") ?? "",
                cc: message.header("Cc") ?? "",
                bcc: message.header("Bcc") ?? "",
                subject: message.header("Subject") ?? "",
                body: plain ?? Self.plainText(fromHTML: html ?? ""),
                threadID: message.threadId,
                inReplyTo: message.header("In-Reply-To"),
                references: message.header("References"),
                attachments: attachments
            )
        )
    }

    private func rawMessage(
        _ draft: ComposeDraft,
        from: String,
        accessToken: String,
        requireRecipient: Bool
    ) async throws -> String {
        guard draft.attachments.reduce(0, { $0 + $1.size }) <= MIMEMessageBuilder.maximumAttachmentBytes else {
            throw MIMEMessageBuilder.BuildError.attachmentsTooLarge
        }
        var resolved: [ResolvedComposeAttachment] = []
        resolved.reserveCapacity(draft.attachments.count)
        for attachment in draft.attachments {
            let data: Data
            switch attachment.source {
            case .local(let url):
                guard let value = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    throw MIMEMessageBuilder.BuildError.unreadableAttachment(attachment.filename)
                }
                data = value
            case .gmail(let gmailAttachment):
                data = try await attachmentData(gmailAttachment, accessToken: accessToken)
            }
            resolved.append(ResolvedComposeAttachment(
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                data: data
            ))
        }
        let message = try MIMEMessageBuilder.build(
            draft: draft,
            from: from,
            resolvedAttachments: resolved,
            requireRecipient: requireRecipient
        )
        return message.base64URLEncodedString()
    }

    func attachmentData(_ attachment: MailAttachment, accessToken: String) async throws -> Data {
        let response: AttachmentResponse = try await get(
            path: "/gmail/v1/users/me/messages/\(attachment.messageID)/attachments/\(attachment.id)",
            accessToken: accessToken
        )
        guard let data = Data(base64URLEncoded: response.data) else { throw GmailError.invalidAttachmentData }
        return data
    }

    static func replacingCIDReference(
        in html: String,
        contentID: String,
        mimeType: String,
        data: Data
    ) -> String {
        let dataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
        return html.replacingOccurrences(
            of: "cid:\(contentID)",
            with: dataURL,
            options: .caseInsensitive
        )
    }

    private func hydrateInlineImages(in messages: [MailMessage], accessToken: String) async -> [MailMessage] {
        let maximumPartSize = 1_000_000
        let maximumTotalSize = 2_000_000
        var remaining = maximumTotalSize
        var hydrated = messages

        for messageIndex in hydrated.indices {
            guard var html = hydrated[messageIndex].htmlBody else { continue }
            let candidates = hydrated[messageIndex].attachments.filter {
                $0.contentID != nil && $0.mimeType.hasPrefix("image/") && $0.size <= maximumPartSize
            }
            for attachment in candidates where attachment.size <= remaining {
                guard let contentID = attachment.contentID,
                      html.range(of: "cid:\(contentID)", options: .caseInsensitive) != nil,
                      let data = try? await attachmentData(attachment, accessToken: accessToken),
                      data.count <= maximumPartSize && data.count <= remaining
                else { continue }
                html = Self.replacingCIDReference(
                    in: html,
                    contentID: contentID,
                    mimeType: attachment.mimeType,
                    data: data
                )
                remaining -= data.count
            }
            hydrated[messageIndex] = hydrated[messageIndex].replacingHTMLBody(html)
        }
        return hydrated
    }

    private func summary(
        id: String,
        accessToken: String,
        requiredLabelIDs: Set<String>? = nil
    ) async throws -> ThreadSummary {
        let resource: ThreadResource = try await get(
            path: "/gmail/v1/users/me/threads/\(id)",
            query: [
                URLQueryItem(name: "format", value: "full"),
                // Partial-response fields retain MIME attachment structure but
                // omit body data, keeping list sync far lighter than full mail.
                URLQueryItem(name: "fields", value: Self.summaryFields),
            ],
            accessToken: accessToken
        )
        guard let messages = resource.messages, let latest = messages.max(by: { $0.messageDate < $1.messageDate }) else {
            throw GmailError.missingThreadData
        }
        let ordered = messages.sorted { $0.messageDate < $1.messageDate }
        let labels = Set(messages.flatMap { $0.labelIds ?? [] })
        if let requiredLabelIDs, !requiredLabelIDs.isSubset(of: labels) { throw GmailError.notInInbox }
        let participants = Self.participantNames(ordered.map { message in
            (
                message.header("From") ?? "Unknown sender",
                Set(message.labelIds ?? []).contains("SENT") || Set(message.labelIds ?? []).contains("DRAFT")
            )
        })
        let attachmentNames = Self.uniqueAttachmentNames(
            ordered.flatMap { $0.payload?.attachmentFilenames ?? [] }
        )
        let correspondents = Self.uniqueContacts(ordered.flatMap { message in
            (message.payload?.headers ?? [])
                .filter { ["from", "to", "cc", "bcc"].contains($0.name.lowercased()) }
                .flatMap { Self.contacts(from: $0.value) }
        })
        return ThreadSummary(
            id: resource.id,
            sender: participants.joined(separator: ", "),
            subject: Self.normalizedSubject(latest.header("Subject") ?? "(No subject)"),
            snippet: Self.decodedSnippet(resource.snippet ?? latest.snippet ?? ""),
            date: latest.messageDate,
            isUnread: labels.contains("UNREAD"),
            isStarred: labels.contains("STARRED"),
            messageCount: messages.count,
            attachmentNames: attachmentNames,
            labelIDs: labels,
            correspondents: correspondents
        )
    }

    static func participantNames(_ values: [(sender: String, isMe: Bool)]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let name = value.isMe ? "me" : displayName(value.sender)
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seen.insert(key).inserted ? name : nil
        }
    }

    static func normalizedSubject(_ subject: String) -> String {
        var result = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["re:", "fwd:", "fw:"]
        while let prefix = prefixes.first(where: { result.lowercased().hasPrefix($0) }) {
            result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty ? "(No subject)" : result
    }

    static func uniqueAttachmentNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { name in
            seen.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted
        }
    }

    static func contacts(from header: String) -> [EmailContact] {
        let pattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(header.startIndex..., in: header)
        return expression.matches(in: header, range: range).compactMap { match in
            guard let emailRange = Range(match.range, in: header) else { return nil }
            let email = String(header[emailRange]).lowercased()
            let prefix = header[..<emailRange.lowerBound]
            let name: String
            if prefix.last == "<" {
                let withoutBracket = prefix.dropLast()
                let start = withoutBracket.lastIndex(of: ">")
                    .map { withoutBracket.index(after: $0) } ?? withoutBracket.startIndex
                name = String(withoutBracket[start...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,;\t\"'"))
            } else {
                name = email
            }
            return EmailContact(name: name.isEmpty ? email : name, email: email)
        }
    }

    static func uniqueContacts(_ contacts: [EmailContact]) -> [EmailContact] {
        var values: [String: EmailContact] = [:]
        for contact in contacts {
            if let existing = values[contact.email], existing.name != existing.email { continue }
            values[contact.email] = contact
        }
        return Array(values.values)
    }

    private static func displayName(_ sender: String) -> String {
        var value = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bracket = value.firstIndex(of: "<") { value = String(value[..<bracket]) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        if value.isEmpty, let at = sender.firstIndex(of: "@") {
            value = String(sender[..<at]).trimmingCharacters(in: CharacterSet(charactersIn: " <\"'"))
        }
        return value.isEmpty ? "Unknown sender" : value
    }

    private static func decodedSnippet(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static let summaryFields = "id,snippet,messages(id,labelIds,snippet,internalDate,payload(headers,filename,body/attachmentId,parts(headers,filename,body/attachmentId,parts(headers,filename,body/attachmentId,parts(headers,filename,body/attachmentId)))))"

    private static func plainText(fromHTML html: String) -> String {
        html.replacingOccurrences(of: #"(?is)<(?:br\s*/?|/p|/div)>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func get<T: Decodable & Sendable>(
        path: String,
        query: [URLQueryItem] = [],
        accessToken: String
    ) async throws -> T {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "gmail.googleapis.com"
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw GmailError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GmailError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GmailError.requestFailed(status: http.statusCode, body: body)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post(path: String, body: Data, accessToken: String) async throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "gmail.googleapis.com"
        components.path = path
        guard let url = components.url else { throw GmailError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GmailError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw GmailError.requestFailed(status: http.statusCode, body: responseBody)
        }
    }

    private func writeReturning<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: Data,
        accessToken: String
    ) async throws -> T {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "gmail.googleapis.com"
        components.path = path
        guard let url = components.url else { throw GmailError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GmailError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw GmailError.requestFailed(status: http.statusCode, body: responseBody)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct ThreadModifyRequest: Encodable, Sendable {
    let addLabelIds: [String]
    let removeLabelIds: [String]
}

private struct BatchModifyRequest: Encodable, Sendable {
    let ids: [String]
    let addLabelIds: [String]
    let removeLabelIds: [String]
}

private struct MessageListResponse: Decodable, Sendable {
    let messages: [ThreadReference]?
    let nextPageToken: String?
}

private struct SendMessageRequest: Encodable, Sendable {
    let raw: String
    let threadId: String?
}

private struct DraftWriteRequest: Encodable, Sendable {
    let message: SendMessageRequest
}

private struct DraftSendRequest: Encodable, Sendable {
    let id: String
}

private struct DraftResource: Decodable, Sendable {
    let id: String
    let message: MessageResource?
}

private struct DraftListResponse: Decodable, Sendable {
    let drafts: [DraftResource]?
    let nextPageToken: String?
}

private struct AttachmentResponse: Decodable, Sendable {
    let data: String
}

struct GmailMailboxPage: Sendable {
    let summaries: [ThreadSummary]
    let nextPageToken: String?
}

private struct ThreadListResponse: Decodable, Sendable {
    let threads: [ThreadReference]?
    let nextPageToken: String?
}

private struct LabelListResponse: Decodable, Sendable {
    let labels: [LabelResource]?
}

private struct LabelResource: Decodable, Sendable {
    let id: String
    let name: String
    let type: String
    let threadsTotal: Int?
    let threadsUnread: Int?
}

private struct HistoryListResponse: Decodable, Sendable {
    let history: [HistoryRecord]?
    let nextPageToken: String?
    let historyId: String?
}

private struct HistoryRecord: Decodable, Sendable {
    let id: String
    let messagesAdded: [HistoryMessageChange]?
    let messagesDeleted: [HistoryMessageChange]?
    let labelsAdded: [HistoryLabelChange]?
    let labelsRemoved: [HistoryLabelChange]?
}

private struct HistoryMessageChange: Decodable, Sendable {
    let message: HistoryMessage
}

private struct HistoryLabelChange: Decodable, Sendable {
    let message: HistoryMessage
    let labelIds: [String]
}

private struct HistoryMessage: Decodable, Sendable {
    let id: String
    let threadId: String
}

private struct ThreadReference: Decodable, Sendable {
    let id: String
}

private struct ThreadResource: Decodable, Sendable {
    let id: String
    let snippet: String?
    let messages: [MessageResource]?
}

private struct MessageResource: Decodable, Sendable {
    let id: String
    let threadId: String?
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    let payload: MessagePart?

    func header(_ name: String) -> String? {
        payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var messageDate: Date {
        guard let internalDate, let milliseconds = Double(internalDate) else { return .distantPast }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

struct MessagePart: Decodable, Sendable {
    struct Header: Decodable, Sendable {
        let name: String
        let value: String
    }
    struct Body: Decodable, Sendable {
        let data: String?
        let attachmentId: String?
        let size: Int?
    }

    let filename: String?
    let mimeType: String?
    let headers: [Header]?
    let body: Body?
    let parts: [MessagePart]?

    func decodedBody(mimeType wantedType: String) -> String? {
        if mimeType?.lowercased() == wantedType, let encoded = body?.data,
           let data = Data(base64URLEncoded: encoded) {
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }
        for part in parts ?? [] {
            if let value = part.decodedBody(mimeType: wantedType) { return value }
        }
        return nil
    }

    func attachments(messageID: String) -> [MailAttachment] {
        var values: [MailAttachment] = []
        if let attachmentID = body?.attachmentId, !(filename ?? "").isEmpty {
            let contentID = headers?.first { $0.name.caseInsensitiveCompare("Content-ID") == .orderedSame }?.value
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            values.append(MailAttachment(
                id: attachmentID,
                messageID: messageID,
                filename: filename ?? "Attachment",
                mimeType: mimeType ?? "application/octet-stream",
                size: body?.size ?? 0,
                contentID: contentID
            ))
        }
        for part in parts ?? [] { values.append(contentsOf: part.attachments(messageID: messageID)) }
        return values
    }

    var attachmentFilenames: [String] {
        var values: [String] = []
        if let filename, !filename.isEmpty, body?.attachmentId != nil { values.append(filename) }
        for part in parts ?? [] { values.append(contentsOf: part.attachmentFilenames) }
        return values
    }
}

extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }
}

enum GmailError: LocalizedError {
    case invalidResponse
    case requestFailed(status: Int, body: String)
    case missingThreadData
    case notInInbox
    case invalidAttachmentData

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Gmail returned an invalid response."
        case .requestFailed(let status, let body):
            "Gmail request failed (HTTP \(status)). \(body.prefix(300))"
        case .missingThreadData:
            "Gmail returned a thread without message metadata."
        case .notInInbox:
            "This thread is no longer in the inbox."
        case .invalidAttachmentData:
            "Gmail returned invalid attachment data."
        }
    }
}
