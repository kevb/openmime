import Testing
@testable import OpenMime

@Test func builtInMailboxesHaveUniqueIDsAndExpectedGmailFilters() {
    let mailboxes = MailboxDescriptor.builtIns
    #expect(Set(mailboxes.map(\.id)).count == mailboxes.count)
    #expect(mailboxes.first { $0.id == "social" }?.labelIDs == ["INBOX", "CATEGORY_SOCIAL"])
    #expect(mailboxes.first { $0.id == "promotions" }?.labelIDs == ["INBOX", "CATEGORY_PROMOTIONS"])
    #expect(mailboxes.first { $0.id == "updates" }?.labelIDs == ["INBOX", "CATEGORY_UPDATES"])
    #expect(mailboxes.first { $0.id == "all-mail" }?.query == "-in:spam -in:trash")
    #expect(mailboxes.first { $0.id == "primary" }?.labelIDs == ["INBOX"])
    #expect(mailboxes.first { $0.id == "primary" }?.query == "category:primary")
    #expect(mailboxes.first { $0.id == "unread" }?.labelIDs == ["INBOX", "UNREAD"])
}

@Test func GmailBatchModifyChunksAtAPIAllowance() {
    let values = Array(0..<2_001)
    let batches = GmailClient.batches(values, size: 1_000)
    #expect(batches.map(\.count) == [1_000, 1_000, 1])
    #expect(batches.flatMap { $0 } == values)
}

@Test func userLabelsPreserveGmailIDs() {
    let label = MailboxDescriptor.userLabel(id: "Label_42", name: "Receipts")
    #expect(label.id == "label:Label_42")
    #expect(label.labelIDs == ["Label_42"])
    #expect(label.section == .gmail)
    #expect(label.isUserLabel)
}
