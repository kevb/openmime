import Foundation
import Testing
@testable import OpenMime

@Test func GmailSearchQueryPreservesAdvancedSyntax() {
    let items = GmailClient.threadListQueryItems(
        labelIDs: [],
        query: "from:alerts@example.com has:attachment newer_than:7d",
        maxResults: 50
    )
    let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(values["q"] == "from:alerts@example.com has:attachment newer_than:7d")
    #expect(values["maxResults"] == "50")
}

@Test func GmailThreadListKeepsMultipleLabelFilters() {
    let items = GmailClient.threadListQueryItems(
        labelIDs: ["INBOX", "CATEGORY_PERSONAL"],
        query: nil,
        maxResults: 24
    )
    #expect(items.filter { $0.name == "labelIds" }.compactMap(\.value) == ["INBOX", "CATEGORY_PERSONAL"])
    #expect(items.first { $0.name == "q" } == nil)
}

@Test func GmailThreadListIncludesPaginationCursor() {
    let items = GmailClient.threadListQueryItems(
        labelIDs: [],
        query: "is:unread",
        maxResults: 50,
        pageToken: "next-page-123"
    )
    #expect(items.first { $0.name == "pageToken" }?.value == "next-page-123")
}

@Test func advancedSearchBuildsEditableGmailSyntax() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var draft = AdvancedSearchDraft()
    draft.from = "alerts@example.com"
    draft.subject = "security notice"
    draft.words = "account urgent"
    draft.excludedWords = "marketing sale"
    draft.hasAttachment = true
    draft.useAfterDate = true
    draft.afterDate = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
    draft.useBeforeDate = true
    draft.beforeDate = calendar.date(from: DateComponents(year: 2026, month: 7, day: 11))!

    #expect(
        draft.gmailQuery(calendar: calendar) ==
            "from:alerts@example.com subject:\"security notice\" account urgent -marketing -sale has:attachment after:2026/07/01 before:2026/07/11"
    )
}
