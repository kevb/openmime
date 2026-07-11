import Foundation
import Testing
@testable import OpenMime

@Test func base64URLDecodingHandlesMissingPadding() {
    let encoded = Data("Hello, Gmail!".utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    #expect(Data(base64URLEncoded: encoded) == Data("Hello, Gmail!".utf8))
}

@Test func sanitizerRemovesActiveAndRemoteContent() {
    let unsafe = """
    <html><head><script>alert('x')</script></head><body onload="steal()">
    <img src="https://tracker.example/pixel" onerror="steal()">
    <a href="javascript:steal()">bad</a><p>Keep me</p>
    <iframe src="https://tracker.example"></iframe></body></html>
    """
    let safe = SafeHTML.sanitizeFragment(unsafe)
    #expect(!safe.localizedCaseInsensitiveContains("script"))
    #expect(!safe.localizedCaseInsensitiveContains("iframe"))
    #expect(!safe.localizedCaseInsensitiveContains("onload"))
    #expect(!safe.localizedCaseInsensitiveContains("onerror"))
    #expect(!safe.localizedCaseInsensitiveContains("javascript:"))
    #expect(safe.contains("data-openmime-src=\"https://tracker.example/pixel\""))
    #expect(safe.range(of: #"(?i)<img\s+src="# , options: .regularExpression) == nil)
    #expect(safe.contains("Keep me"))
}

@Test func remoteImagesRemainBlockedUntilExplicitlyEnabled() {
    let message = MailMessage(
        id: "message",
        sender: "Sender <sender@example.com>",
        recipients: "reader@example.com",
        subject: "Images",
        date: .distantPast,
        htmlBody: #"<img src="https://images.example/photo.jpg">"#,
        plainBody: nil,
        attachments: []
    )
    var rendered = RenderedThread(MailThread(id: "thread", subject: "Images", messages: [message]))
    #expect(rendered.containsRemoteImages)
    #expect(rendered.remoteImageSender == "sender@example.com")
    #expect(rendered.document.contains("img-src data:;"))
    #expect(!rendered.isShowingRemoteImages)
    #expect(rendered.document.contains("data-openmime-src=\"https://images.example/photo.jpg\""))
    rendered.showRemoteImages()
    #expect(rendered.document.contains("img-src data: https: http:;"))
    #expect(rendered.isShowingRemoteImages)
    #expect(rendered.document.contains("src=\"https://images.example/photo.jpg\""))
}

@Test func sanitizerBlocksUnquotedRemoteImageSources() {
    let safe = SafeHTML.sanitizeFragment("<img src=https://images.example/photo.jpg alt=Photo>")
    #expect(safe.contains("data-openmime-src=\"https://images.example/photo.jpg\""))
    #expect(!safe.contains(" src=https://"))
}

@Test func conversationDocumentHasRestrictiveCSP() {
    let message = MailMessage(
        id: "message",
        sender: "Sender <sender@example.com>",
        recipients: "reader@example.com",
        subject: "Hello",
        date: Date(timeIntervalSince1970: 0),
        htmlBody: "<p>Hello</p>",
        plainBody: nil,
        attachments: []
    )
    let document = SafeHTML.conversation(MailThread(id: "thread", subject: "Hello", messages: [message]))
    #expect(document.contains("default-src 'none'"))
    #expect(document.contains("connect-src 'none'"))
    #expect(document.contains("<p>Hello</p>"))
}

@Test func darkModeNormalizesOnlyNeutralSenderTextColors() {
    let html = """
    <h1 style="color: rgba(0,0,0,0.87); font-size: 30px">Dark heading</h1>
    <span style="color:#4285f4">Google blue</span>
    <font color="#000000">Legacy black</font>
    """
    let safe = SafeHTML.sanitizeFragment(html)
    #expect(safe.contains("data-openmime-dark-text"))
    #expect(safe.components(separatedBy: "data-openmime-dark-text").count - 1 == 2)
    #expect(safe.contains("<h1 style=\"color: rgba(0,0,0,0.87); font-size: 30px\" data-openmime-dark-text>"))
    #expect(safe.contains("<font color=\"#000000\" data-openmime-dark-text>"))
    #expect(safe.contains("style=\"color:#4285f4\""))
    let document = SafeHTML.conversation(MailThread(
        id: "dark",
        subject: "Dark",
        messages: [MailMessage(
            id: "message",
            sender: "Google <no-reply@example.com>",
            recipients: "reader@example.com",
            subject: "Dark",
            date: .distantPast,
            htmlBody: html,
            plainBody: nil,
            attachments: []
        )]
    ))
    #expect(document.contains(".body [data-openmime-dark-text]"))
}

@Test func conversationCollapsesOlderMessagesAndOpensLatest() {
    let older = MailMessage(
        id: "older",
        sender: "Example Hosting <noreply@example.com>",
        recipients: "reader@example.com",
        subject: "Token",
        date: Date(timeIntervalSince1970: 0),
        htmlBody: "<p>Older preview</p>",
        plainBody: nil,
        attachments: []
    )
    let latest = MailMessage(
        id: "latest",
        sender: "Example Hosting <noreply@example.com>",
        recipients: "reader@example.com",
        subject: "Token",
        date: Date(timeIntervalSince1970: 1),
        htmlBody: "<p>Latest body</p>",
        plainBody: nil,
        attachments: []
    )
    let document = SafeHTML.conversation(MailThread(id: "thread", subject: "Token", messages: [older, latest]))
    #expect(document.components(separatedBy: "<details class=\"message\"").count - 1 == 2)
    #expect(document.components(separatedBy: "<details class=\"message\" open>").count - 1 == 1)
    #expect(document.contains("class=\"avatar\">EH</span>"))
    #expect(document.contains("class=\"preview\">Older preview</span>"))
}

@Test func renderedThreadRetainsCompactReplyContext() {
    let message = MailMessage(
        id: "message",
        sender: "Sender <sender@example.com>",
        recipients: "reader@example.com",
        cc: "copy@example.com",
        replyTo: "reply@example.com",
        subject: "Hello",
        date: Date(timeIntervalSince1970: 0),
        messageIDHeader: "<message@example.com>",
        references: "<earlier@example.com>",
        htmlBody: "<p>Hello <b>there</b></p>",
        plainBody: nil,
        attachments: []
    )
    let rendered = RenderedThread(MailThread(id: "thread", subject: "Hello", messages: [message]))
    #expect(rendered.replyContext?.threadID == "thread")
    #expect(rendered.replyContext?.replyTo == "reply@example.com")
    #expect(rendered.replyContext?.quotableBody == "Hello there")
}
