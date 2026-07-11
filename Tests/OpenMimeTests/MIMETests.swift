import Foundation
import Testing
@testable import OpenMime

@Test func mimeTreeExtractsRegularAndInlineAttachments() {
    let regular = MessagePart(
        filename: "report.pdf",
        mimeType: "application/pdf",
        headers: [],
        body: .init(data: nil, attachmentId: "pdf-id", size: 2_048),
        parts: nil
    )
    let inline = MessagePart(
        filename: "logo.png",
        mimeType: "image/png",
        headers: [.init(name: "Content-ID", value: "<company-logo>")],
        body: .init(data: nil, attachmentId: "image-id", size: 512),
        parts: nil
    )
    let root = MessagePart(
        filename: nil,
        mimeType: "multipart/mixed",
        headers: [],
        body: nil,
        parts: [regular, inline]
    )

    let attachments = root.attachments(messageID: "message")
    #expect(attachments.count == 2)
    #expect(attachments[0].filename == "report.pdf")
    #expect(attachments[0].messageID == "message")
    #expect(attachments[1].contentID == "company-logo")
    #expect(attachments[1].mimeType == "image/png")
}

@Test func mimeTreeIgnoresEmptyContainerParts() {
    let root = MessagePart(
        filename: "",
        mimeType: "text/plain",
        headers: [],
        body: .init(data: "SGVsbG8", attachmentId: nil, size: 5),
        parts: nil
    )
    #expect(root.attachments(messageID: "message").isEmpty)
    #expect(root.decodedBody(mimeType: "text/plain") == "Hello")
}

@Test func cidReferencesAreReplacedCaseInsensitivelyWithDataURLs() {
    let html = #"<p>Logo</p><img src="CID:Company-Logo">"#
    let rendered = GmailClient.replacingCIDReference(
        in: html,
        contentID: "company-logo",
        mimeType: "image/png",
        data: Data([0x01, 0x02, 0x03])
    )
    #expect(rendered.contains("data:image/png;base64,AQID"))
    #expect(!rendered.localizedCaseInsensitiveContains("cid:company-logo"))
}
