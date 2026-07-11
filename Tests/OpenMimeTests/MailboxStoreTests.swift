import Foundation
import Testing
@testable import OpenMime

@Test func mailboxStorePersistsAndIsolatesAccounts() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MailboxStore(url: directory.appending(path: "mail.sqlite"))
    let newer = summary(id: "newer", date: 200, unread: true, labelIDs: ["INBOX", "Label_42"])
    let older = summary(id: "older", date: 100, unread: false)

    try await store.replaceInbox(account: "one@example.com", summaries: [older, newer], historyID: "10")
    try await store.replaceInbox(account: "two@example.com", summaries: [summary(id: "other", date: 300)], historyID: "20")

    #expect(try await store.cachedInbox(account: "one@example.com").map(\.id) == ["newer", "older"])
    #expect(try await store.cachedInbox(account: "one@example.com").first?.labelIDs == ["INBOX", "Label_42"])
    #expect(try await store.cachedInbox(account: "two@example.com").map(\.id) == ["other"])
    #expect(try await store.historyID(account: "one@example.com") == "10")
    #expect(try await store.historyID(account: "two@example.com") == "20")
}

@Test func mailboxStoreAppliesHistoryChangesAtomically() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MailboxStore(url: directory.appending(path: "mail.sqlite"))
    try await store.replaceInbox(
        account: "reader@example.com",
        summaries: [summary(id: "remove", date: 100), summary(id: "update", date: 200)],
        historyID: "100"
    )

    try await store.apply(
        account: "reader@example.com",
        upserts: [summary(id: "update", date: 400, unread: false), summary(id: "add", date: 300)],
        removals: ["remove"],
        historyID: "200"
    )

    let values = try await store.cachedInbox(account: "reader@example.com")
    #expect(values.map(\.id) == ["update", "add"])
    #expect(values.first?.isUnread == false)
    #expect(try await store.historyID(account: "reader@example.com") == "200")
}

@Test func mailboxStoreCachesRenderedConversationAndAttachments() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MailboxStore(url: directory.appending(path: "mail.sqlite"))
    let attachment = MailAttachment(
        id: "attachment",
        messageID: "message",
        filename: "report.pdf",
        mimeType: "application/pdf",
        size: 1_024,
        contentID: nil
    )
    let rendered = RenderedThread(
        id: "thread",
        subject: "Cached subject",
        messageCount: 2,
        remoteImageSender: "sender@example.com",
        containsRemoteImages: true,
        attachments: [attachment],
        replyContext: ReplyContext(
            threadID: "thread",
            sender: "Sender <sender@example.com>",
            recipients: "reader@example.com",
            cc: "",
            replyTo: nil,
            subject: "Cached subject",
            date: Date(timeIntervalSince1970: 1),
            messageIDHeader: "<message@example.com>",
            references: nil,
            quotableBody: "Cached body",
            attachments: []
        ),
        document: "<html>cached</html>"
    )

    try await store.saveThread(account: "reader@example.com", thread: rendered)
    let cached = try await store.cachedThread(account: "reader@example.com", threadID: "thread")
    #expect(cached == rendered)
    #expect(try await store.cachedThread(account: "other@example.com", threadID: "thread") == nil)
}

@Test func mailboxStoreRanksGmailDerivedCorrespondentsAndExcludesSelf() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MailboxStore(url: directory.appending(path: "mail.sqlite"))
    var value = summary(id: "contacts", date: 100)
    value.correspondents = [
        EmailContact(name: "Taylor", email: "taylor@example.com"),
        EmailContact(name: "Me", email: "reader@example.com"),
    ]
    try await store.replaceInbox(account: "reader@example.com", summaries: [value], historyID: "1")

    #expect(try await store.searchCorrespondents(account: "reader@example.com", matching: "tay") == [
        EmailContact(name: "Taylor", email: "taylor@example.com")
    ])
    #expect(try await store.searchCorrespondents(account: "reader@example.com", matching: "reader").isEmpty)
}

private func summary(id: String, date: TimeInterval, unread: Bool = false, labelIDs: Set<String> = []) -> ThreadSummary {
    ThreadSummary(
        id: id,
        sender: "Sender <sender@example.com>",
        subject: "Subject \(id)",
        snippet: "Snippet \(id)",
        date: Date(timeIntervalSince1970: date),
        isUnread: unread,
        isStarred: false,
        messageCount: 1,
        attachmentNames: ["report.pdf"],
        labelIDs: labelIDs
    )
}
