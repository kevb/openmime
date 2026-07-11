import Foundation
import Testing
@testable import OpenMime

@Test func mimeMessageBuildsHeadersAndUnicodeBody() throws {
    let draft = ComposeDraft(
        to: "reader@example.com",
        cc: "copy@example.com",
        bcc: "hidden@example.com",
        subject: "Merhaba dünya",
        body: "First line\nİkinci satır"
    )
    let date = Date(timeIntervalSince1970: 0)
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let data = try MIMEMessageBuilder.build(draft: draft, from: "sender@gmail.com", date: date, messageID: id)
    let message = String(decoding: data, as: UTF8.self)

    #expect(message.contains("From: sender@gmail.com\r\nTo: reader@example.com"))
    #expect(message.contains("Cc: copy@example.com\r\nBcc: hidden@example.com"))
    #expect(message.contains("Subject: =?UTF-8?B?TWVyaGFiYSBkw7xueWE=?="))
    #expect(message.contains("Message-ID: <00000000-0000-0000-0000-000000000001@openmime.local>"))
    let encodedBody = Data("First line\r\nİkinci satır".utf8).base64EncodedString()
    #expect(message.contains("\r\n\r\n\(encodedBody)\r\n"))
}

@Test func mimeMessageRejectsMissingRecipientAndHeaderInjection() {
    #expect(throws: MIMEMessageBuilder.BuildError.missingRecipient) {
        try MIMEMessageBuilder.build(draft: ComposeDraft(), from: "sender@gmail.com")
    }

    var injected = ComposeDraft()
    injected.to = "victim@example.com\r\nBcc: attacker@example.com"
    #expect(throws: MIMEMessageBuilder.BuildError.invalidHeader) {
        try MIMEMessageBuilder.build(draft: injected, from: "sender@gmail.com")
    }
}

@Test func gmailDraftMIMEAllowsSubjectBeforeRecipientIsEntered() throws {
    var draft = ComposeDraft()
    draft.subject = "Unfinished thought"
    let message = String(decoding: try MIMEMessageBuilder.build(
        draft: draft,
        from: "sender@gmail.com",
        requireRecipient: false
    ), as: UTF8.self)
    #expect(message.contains("Subject: Unfinished thought"))
    #expect(!message.contains("\r\nTo:"))
}

@Test func replyDraftPreservesGmailThreadingHeaders() throws {
    let context = ReplyContext(
        threadID: "gmail-thread",
        sender: "Support <support@example.com>",
        recipients: "Reader <reader@example.com>",
        cc: "Team <team@example.com>",
        replyTo: "replies@example.com",
        subject: "Account update",
        date: Date(timeIntervalSince1970: 0),
        messageIDHeader: "<original@example.com>",
        references: "<first@example.com>",
        quotableBody: "Original line",
        attachments: []
    )
    let draft = ResponseDraftBuilder.draft(for: .reply, context: context, ownAddress: "reader@example.com")
    #expect(draft.to == "replies@example.com")
    #expect(draft.subject == "Re: Account update")
    #expect(draft.threadID == "gmail-thread")
    #expect(draft.inReplyTo == "<original@example.com>")
    #expect(draft.references == "<first@example.com> <original@example.com>")
    #expect(draft.body.contains("> Original line"))

    let message = String(decoding: try MIMEMessageBuilder.build(draft: draft, from: "reader@example.com"), as: UTF8.self)
    #expect(message.contains("In-Reply-To: <original@example.com>\r\n"))
    #expect(message.contains("References: <first@example.com> <original@example.com>\r\n"))
}

@Test func replyAllExcludesSelfAndForwardStartsWithoutThreadID() {
    let context = ReplyContext(
        threadID: "thread",
        sender: "Sender <sender@example.com>",
        recipients: "Reader <reader@example.com>, Other <other@example.com>",
        cc: "Copy <copy@example.com>",
        replyTo: nil,
        subject: "Hello",
        date: Date(timeIntervalSince1970: 0),
        messageIDHeader: "<message@example.com>",
        references: nil,
        quotableBody: "Hello there",
        attachments: [MailAttachment(
            id: "attachment",
            messageID: "message",
            filename: "report.pdf",
            mimeType: "application/pdf",
            size: 100,
            contentID: nil
        )]
    )
    let replyAll = ResponseDraftBuilder.draft(for: .replyAll, context: context, ownAddress: "reader@example.com")
    #expect(replyAll.to == "Sender <sender@example.com>")
    #expect(replyAll.cc.contains("Other <other@example.com>"))
    #expect(replyAll.cc.contains("Copy <copy@example.com>"))
    #expect(!replyAll.cc.contains("reader@example.com"))

    let forward = ResponseDraftBuilder.draft(for: .forward, context: context, ownAddress: "reader@example.com")
    #expect(forward.to.isEmpty)
    #expect(forward.threadID == nil)
    #expect(forward.subject == "Fwd: Hello")
    #expect(forward.body.contains("---------- Forwarded message ----------"))
    #expect(forward.attachments.map(\.filename) == ["report.pdf"])
}

@Test func mimeMessageBuildsMultipartAttachments() throws {
    var draft = ComposeDraft()
    draft.to = "reader@example.com"
    draft.subject = "Files"
    draft.body = "Attached"
    let attachment = ResolvedComposeAttachment(
        filename: "fatura ğ.pdf",
        mimeType: "application/pdf",
        data: Data("PDF data".utf8)
    )
    let message = String(decoding: try MIMEMessageBuilder.build(
        draft: draft,
        from: "sender@gmail.com",
        boundary: "TEST-BOUNDARY",
        resolvedAttachments: [attachment]
    ), as: UTF8.self)

    #expect(message.contains("Content-Type: multipart/mixed; boundary=\"TEST-BOUNDARY\""))
    #expect(message.contains("filename*=UTF-8''fatura%20%C4%9F.pdf"))
    #expect(message.contains(Data("PDF data".utf8).base64EncodedString()))
    #expect(message.contains("--TEST-BOUNDARY--\r\n"))
}
