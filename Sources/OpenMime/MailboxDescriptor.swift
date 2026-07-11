import Foundation

struct MailboxDescriptor: Identifiable, Equatable, Sendable {
    enum Section: Equatable, Sendable { case inboxes, favorites, gmail }

    let id: String
    let title: String
    let systemImage: String
    let labelIDs: [String]
    let query: String?
    let section: Section
    let isUserLabel: Bool

    static let primary = MailboxDescriptor(
        id: "primary", title: "Primary", systemImage: "tray", labelIDs: ["INBOX"],
        query: "category:primary", section: .inboxes, isUserLabel: false
    )

    static let builtIns: [MailboxDescriptor] = [
        primary,
        .init(id: "unread", title: "Unread", systemImage: "circle.fill", labelIDs: ["INBOX", "UNREAD"], query: nil, section: .favorites, isUserLabel: false),
        .init(id: "social", title: "Social", systemImage: "person.crop.rectangle.stack", labelIDs: ["INBOX", "CATEGORY_SOCIAL"], query: nil, section: .inboxes, isUserLabel: false),
        .init(id: "promotions", title: "Promotions", systemImage: "newspaper", labelIDs: ["INBOX", "CATEGORY_PROMOTIONS"], query: nil, section: .inboxes, isUserLabel: false),
        .init(id: "updates", title: "Updates", systemImage: "doc.text.magnifyingglass", labelIDs: ["INBOX", "CATEGORY_UPDATES"], query: nil, section: .inboxes, isUserLabel: false),
        .init(id: "starred", title: "Starred", systemImage: "star", labelIDs: ["STARRED"], query: nil, section: .favorites, isUserLabel: false),
        .init(id: "drafts", title: "Drafts", systemImage: "doc", labelIDs: ["DRAFT"], query: nil, section: .favorites, isUserLabel: false),
        .init(id: "sent", title: "Sent", systemImage: "paperplane", labelIDs: ["SENT"], query: nil, section: .favorites, isUserLabel: false),
        .init(id: "all-mail", title: "All Mail", systemImage: "archivebox", labelIDs: [], query: "-in:spam -in:trash", section: .favorites, isUserLabel: false),
        .init(id: "spam", title: "Spam", systemImage: "exclamationmark.octagon", labelIDs: ["SPAM"], query: nil, section: .favorites, isUserLabel: false),
        .init(id: "trash", title: "Trash", systemImage: "trash", labelIDs: ["TRASH"], query: nil, section: .favorites, isUserLabel: false),
        .init(id: "important", title: "Important", systemImage: "chevron.right.2", labelIDs: ["IMPORTANT"], query: nil, section: .gmail, isUserLabel: false),
    ]

    static func userLabel(id: String, name: String) -> MailboxDescriptor {
        MailboxDescriptor(
            id: "label:\(id)", title: name, systemImage: "tag", labelIDs: [id], query: nil,
            section: .gmail, isUserLabel: true
        )
    }
}

struct GmailLabel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let type: String
    let threadsTotal: Int?
    let threadsUnread: Int?
}
