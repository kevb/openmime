import Testing
@testable import OpenMime

@Test func threadParticipantsUseNamesAndMeInConversationOrder() {
    let names = GmailClient.participantNames([
        (sender: "Taylor Example <taylor@example.com>", isMe: false),
        (sender: "Reader <reader@example.com>", isMe: true),
        (sender: "Taylor Example <taylor@example.com>", isMe: false),
    ])
    #expect(names == ["Taylor Example", "me"])
}

@Test func threadSubjectRemovesReplyAndForwardPrefixes() {
    #expect(GmailClient.normalizedSubject("Fwd: Re: Utility and building dues") == "Utility and building dues")
    #expect(GmailClient.normalizedSubject("Fw: Fwd: ") == "(No subject)")
}

@Test func threadAttachmentNamesIgnoreForwardedDuplicates() {
    #expect(
        GmailClient.uniqueAttachmentNames(["image0.jpeg", "report.xlsx", "IMAGE0.JPEG"]) ==
            ["image0.jpeg", "report.xlsx"]
    )
}

@Test func gmailHeadersProduceNamedAddressSuggestions() {
    let contacts = GmailClient.contacts(
        from: #""Taylor Example" <taylor@example.com>, Reader <reader@example.com>, plain@example.net"#
    )
    #expect(contacts.map(\.email) == ["taylor@example.com", "reader@example.com", "plain@example.net"])
    #expect(contacts.first?.name == "Taylor Example")
    #expect(contacts[1].formattedAddress == "Reader <reader@example.com>")
}
