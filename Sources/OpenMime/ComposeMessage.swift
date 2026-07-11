import Foundation

struct ComposeDraft: Equatable, Sendable {
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var threadID: String?
    var inReplyTo: String?
    var references: String?
    var attachments: [ComposeAttachment] = []

    var canSend: Bool {
        !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasDraftContent: Bool {
        !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !bcc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !attachments.isEmpty
    }
}

struct ComposeAttachment: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case local(URL)
        case gmail(MailAttachment)
    }

    let id: String
    let filename: String
    let mimeType: String
    let size: Int
    let source: Source

    static func local(url: URL, mimeType: String, size: Int) -> ComposeAttachment {
        ComposeAttachment(id: "local:\(UUID().uuidString)", filename: url.lastPathComponent, mimeType: mimeType, size: size, source: .local(url))
    }

    static func gmail(_ attachment: MailAttachment) -> ComposeAttachment {
        ComposeAttachment(
            id: "gmail:\(attachment.messageID):\(attachment.id)",
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            size: attachment.size,
            source: .gmail(attachment)
        )
    }
}

struct ResolvedComposeAttachment: Equatable, Sendable {
    let filename: String
    let mimeType: String
    let data: Data
}

enum ResponseKind: Equatable, Sendable { case reply, replyAll, forward }

struct ReplyContext: Codable, Equatable, Sendable {
    let threadID: String
    let sender: String
    let recipients: String
    let cc: String
    let replyTo: String?
    let subject: String
    let date: Date
    let messageIDHeader: String?
    let references: String?
    let quotableBody: String
    let attachments: [MailAttachment]
}

enum ResponseDraftBuilder {
    static func draft(for kind: ResponseKind, context: ReplyContext, ownAddress: String) -> ComposeDraft {
        switch kind {
        case .reply, .replyAll:
            let targetHeader = replyTarget(context: context, ownAddress: ownAddress)
            let targets = GmailClient.uniqueContacts(GmailClient.contacts(from: targetHeader))
            let targetEmails = Set(targets.map { $0.email.lowercased() })
            var cc = ""
            if kind == .replyAll {
                let others = GmailClient.uniqueContacts(
                    GmailClient.contacts(from: context.recipients) + GmailClient.contacts(from: context.cc)
                ).filter {
                    $0.email.caseInsensitiveCompare(ownAddress) != .orderedSame && !targetEmails.contains($0.email.lowercased())
                }
                cc = others.map(\.formattedAddress).joined(separator: ", ")
            }
            let quote = quotedReply(context)
            return ComposeDraft(
                to: targets.map(\.formattedAddress).joined(separator: ", "),
                cc: cc,
                subject: prefixed("Re:", subject: context.subject),
                body: "\n\n\(quote)",
                threadID: context.threadID,
                inReplyTo: context.messageIDHeader,
                references: appendedReferences(context)
            )
        case .forward:
            return ComposeDraft(
                subject: prefixed("Fwd:", subject: context.subject),
                body: "\n\n\(forwardedMessage(context))",
                attachments: context.attachments.map(ComposeAttachment.gmail)
            )
        }
    }

    private static func replyTarget(context: ReplyContext, ownAddress: String) -> String {
        let senderContacts = GmailClient.contacts(from: context.sender)
        if senderContacts.contains(where: { $0.email.caseInsensitiveCompare(ownAddress) == .orderedSame }) {
            return context.recipients
        }
        return context.replyTo?.isEmpty == false ? context.replyTo! : context.sender
    }

    private static func prefixed(_ prefix: String, subject: String) -> String {
        subject.lowercased().hasPrefix(prefix.lowercased()) ? subject : "\(prefix) \(subject)"
    }

    private static func appendedReferences(_ context: ReplyContext) -> String? {
        [context.references, context.messageIDHeader]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .nilIfEmpty
    }

    private static func quotedReply(_ context: ReplyContext) -> String {
        let date = context.date.formatted(date: .abbreviated, time: .shortened)
        let quoted = context.quotableBody.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
        return "On \(date), \(context.sender) wrote:\n\(quoted)"
    }

    private static func forwardedMessage(_ context: ReplyContext) -> String {
        """
        ---------- Forwarded message ----------
        From: \(context.sender)
        Date: \(context.date.formatted(date: .abbreviated, time: .shortened))
        Subject: \(context.subject)
        To: \(context.recipients)

        \(context.quotableBody)
        """
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum MIMEMessageBuilder {
    enum BuildError: LocalizedError, Equatable {
        case missingRecipient
        case invalidHeader
        case attachmentsTooLarge
        case unreadableAttachment(String)
        case unresolvedAttachment

        var errorDescription: String? {
            switch self {
            case .missingRecipient: "Enter at least one recipient."
            case .invalidHeader: "A mail header contains an invalid line break."
            case .attachmentsTooLarge: "Attachments exceed OpenMime’s 10 MB compose limit."
            case .unreadableAttachment(let name): "Could not read attachment: \(name)."
            case .unresolvedAttachment: "A Gmail attachment was not downloaded before MIME generation."
            }
        }
    }

    static let maximumAttachmentBytes = 10_000_000

    static func build(
        draft: ComposeDraft,
        from: String,
        date: Date = Date(),
        messageID: UUID = UUID(),
        boundary: String = "OpenMime-\(UUID().uuidString)",
        resolvedAttachments: [ResolvedComposeAttachment]? = nil,
        requireRecipient: Bool = true
    ) throws -> Data {
        let to = draft.to.trimmingCharacters(in: .whitespacesAndNewlines)
        if requireRecipient, to.isEmpty { throw BuildError.missingRecipient }
        let headers = [from, draft.to, draft.cc, draft.bcc, draft.subject, draft.inReplyTo ?? "", draft.references ?? ""]
        guard headers.allSatisfy({ $0.rangeOfCharacter(from: .newlines) == nil }) else {
            throw BuildError.invalidHeader
        }

        var lines = ["From: \(from)"]
        if !to.isEmpty { lines.append("To: \(to)") }
        if !draft.cc.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("Cc: \(draft.cc)") }
        if !draft.bcc.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("Bcc: \(draft.bcc)") }
        lines.append("Subject: \(encodedHeader(draft.subject))")
        lines.append("Date: \(mailDateFormatter.string(from: date))")
        lines.append("Message-ID: <\(messageID.uuidString.lowercased())@openmime.local>")
        if let inReplyTo = draft.inReplyTo, !inReplyTo.isEmpty { lines.append("In-Reply-To: \(inReplyTo)") }
        if let references = draft.references, !references.isEmpty { lines.append("References: \(references)") }
        let attachments = try resolvedAttachments ?? resolveLocalAttachments(draft.attachments)
        guard attachments.reduce(0, { $0 + $1.data.count }) <= maximumAttachmentBytes else {
            throw BuildError.attachmentsTooLarge
        }
        lines.append("MIME-Version: 1.0")
        if attachments.isEmpty {
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("")
            lines.append(contentsOf: wrappedBase64(Data(normalizedBody(draft.body).utf8)))
        } else {
            lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("")
            lines.append(contentsOf: wrappedBase64(Data(normalizedBody(draft.body).utf8)))
            for attachment in attachments {
                lines.append("--\(boundary)")
                lines.append("Content-Type: \(attachment.mimeType); name*=UTF-8''\(rfc2231(attachment.filename))")
                lines.append("Content-Disposition: attachment; filename*=UTF-8''\(rfc2231(attachment.filename))")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("")
                lines.append(contentsOf: wrappedBase64(attachment.data))
            }
            lines.append("--\(boundary)--")
        }
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private static func resolveLocalAttachments(_ attachments: [ComposeAttachment]) throws -> [ResolvedComposeAttachment] {
        try attachments.map { attachment in
            guard case .local(let url) = attachment.source else { throw BuildError.unresolvedAttachment }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                throw BuildError.unreadableAttachment(attachment.filename)
            }
            return ResolvedComposeAttachment(filename: attachment.filename, mimeType: attachment.mimeType, data: data)
        }
    }

    private static func rfc2231(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$&+-.^_`|~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
    }

    private static func encodedHeader(_ value: String) -> String {
        guard value.unicodeScalars.allSatisfy(\.isASCII) else {
            return "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
        }
        return value
    }

    private static func normalizedBody(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }

    private static func wrappedBase64(_ data: Data) -> [String] {
        let encoded = data.base64EncodedString()
        return stride(from: 0, to: encoded.count, by: 76).map { offset in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(76, encoded.count - offset))
            return String(encoded[start..<end])
        }
    }

    private static let mailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}
