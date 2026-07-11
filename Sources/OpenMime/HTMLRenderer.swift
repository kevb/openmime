import AppKit
import SwiftUI
import WebKit

enum SafeHTML {
    static func conversation(_ thread: MailThread) -> String {
        let messages = thread.messages.enumerated().map { index, message in
            let body: String
            if let html = message.htmlBody {
                body = sanitizeFragment(html)
            } else {
                body = "<pre class=\"plain\">\(escape(message.plainBody ?? "This message has no displayable text body."))</pre>"
            }
            let isLatest = index == thread.messages.indices.last
            return """
            <details class="message" \(isLatest ? "open" : "")>
              <summary>
                <span class="avatar">\(escape(initials(message.sender)))</span>
                <span class="summary-main">
                  <span class="sender">\(escape(message.sender))</span>
                  <span class="preview">\(escape(preview(message)))</span>
                  <span class="recipients">To: \(escape(message.recipients))</span>
                </span>
                <time>\(escape(message.date.formatted(date: .abbreviated, time: .shortened)))</time>
              </summary>
              <section class="body">\(body)</section>
            </details>
            """
        }.joined(separator: "")

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; frame-src 'none'; connect-src 'none'">
        <style>
        :root { color-scheme: light dark; font: 15px -apple-system, BlinkMacSystemFont, sans-serif; }
        body { margin: 0; padding: 4px 24px 60px; color: -apple-system-label; background: transparent; overflow-wrap: anywhere; }
        .message { border-bottom: 1px solid color-mix(in srgb, currentColor 18%, transparent); }
        summary { display: grid; grid-template-columns: 48px minmax(0, 1fr) auto; gap: 4px 12px; align-items: center; padding: 16px 0; cursor: default; list-style: none; }
        summary::-webkit-details-marker { display: none; }
        .avatar { display: grid; place-items: center; width: 42px; height: 42px; border-radius: 50%; color: white; background: #ef58a9; font-size: 16px; font-weight: 700; letter-spacing: .2px; }
        .summary-main { display: grid; min-width: 0; gap: 3px; }
        .sender { font-weight: 650; font-size: 16px; }
        .sender, .preview, .recipients { overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
        .preview { color: color-mix(in srgb, currentColor 72%, transparent); }
        .recipients, time { color: color-mix(in srgb, currentColor 60%, transparent); font-size: 13px; }
        .recipients { display: none; }
        details[open] .preview { display: none; }
        details[open] .recipients { display: block; }
        time { align-self: start; padding-top: 2px; white-space: nowrap; }
        .body { padding: 4px 0 26px 60px; }
        .body { line-height: 1.45; }
        .body img { max-width: 100%; height: auto; }
        .body table { max-width: 100%; border-collapse: collapse; }
        .body blockquote { border-left: 3px solid color-mix(in srgb, currentColor 22%, transparent); margin-left: 0; padding-left: 14px; }
        .plain { white-space: pre-wrap; font: inherit; margin: 0; }
        a { color: -apple-system-link; }
        @media (prefers-color-scheme: dark) {
          .body [data-openmime-dark-text] { color: #e8eaed !important; }
        }
        </style></head><body>\(messages)</body></html>
        """
    }

    static func sanitizeFragment(_ html: String) -> String {
        var value = html
        let blockPatterns = [
            #"(?is)<script\b[^>]*>.*?</script\s*>"#,
            #"(?is)<iframe\b[^>]*>.*?</iframe\s*>"#,
            #"(?is)<object\b[^>]*>.*?</object\s*>"#,
            #"(?is)<style\b[^>]*>.*?</style\s*>"#,
            #"(?is)<head\b[^>]*>.*?</head\s*>"#,
        ]
        for pattern in blockPatterns {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let singlePatterns = [
            #"(?is)</?(?:html|body|meta|link|base|form|input|button|textarea|select|option|video|audio|source|embed)\b[^>]*>"#,
            #"(?i)\s+on[a-z]+\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
            #"(?i)(href|src)\s*=\s*([\"'])\s*(?:javascript|file|data:text/html):[^\2]*\2"#,
        ]
        for pattern in singlePatterns {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        value = value.replacingOccurrences(
            of: #"(?i)\bsrc\s*=\s*([\"'])(https?://[^\"']+)\1"#,
            with: "data-openmime-src=$1$2$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)\bsrc\s*=\s*(https?://[^\s>]+)"#,
            with: "data-openmime-src=\"$1\"",
            options: .regularExpression
        )
        value = markDarkNeutralText(in: value)
        return value
    }

    /// Email templates often hard-code near-black text for a white canvas.
    /// The canvas is transparent in OpenMime, so mark only neutral dark colors
    /// for a dark-mode override while preserving brand and semantic colors.
    static func markDarkNeutralText(in html: String) -> String {
        let neutralColors = [
            "black", "#000", "#000000", "#1f1f1f", "#202124", "#222", "#222222",
            "#292929", "#333", "#333333", "#3c4043", "#5f6368", "rgb(0,0,0)", "rgb(0, 0, 0)",
            "rgba(0,0,0,0.87)", "rgba(0, 0, 0, 0.87)", "rgba(0,0,0,0.54)", "rgba(0, 0, 0, 0.54)",
        ]
        var value = html
        for color in neutralColors {
            let escaped = NSRegularExpression.escapedPattern(for: color)
            value = value.replacingOccurrences(
                of: "(?i)(<[^>]*\\bstyle\\s*=\\s*[\\\"'][^\\\"']*\\bcolor\\s*:\\s*\(escaped)(?:\\s*!important)?[^\\\"']*[\\\"'][^>]*)(>)",
                with: "$1 data-openmime-dark-text$2",
                options: .regularExpression
            )
            value = value.replacingOccurrences(
                of: "(?i)(<[^>]*\\bcolor\\s*=\\s*[\\\"']\\s*\(escaped)\\s*[\\\"'][^>]*)(>)",
                with: "$1 data-openmime-dark-text$2",
                options: .regularExpression
            )
        }
        return value
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func initials(_ sender: String) -> String {
        let name = sender.split(separator: "<", maxSplits: 1).first.map(String.init) ?? sender
        let words = name.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).split(whereSeparator: { $0.isWhitespace })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private static func preview(_ message: MailMessage) -> String {
        let source = message.plainBody ?? message.htmlBody ?? "No message preview"
        return source
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RenderedThread: Identifiable, Equatable, Sendable {
    let id: String
    let subject: String
    let messageCount: Int
    let remoteImageSender: String
    let containsRemoteImages: Bool
    let attachments: [MailAttachment]
    let replyContext: ReplyContext?
    var document: String
    var isShowingRemoteImages: Bool

    init(_ thread: MailThread) {
        id = thread.id
        subject = thread.subject
        messageCount = thread.messages.count
        remoteImageSender = Self.senderAddress(thread.messages.last?.sender ?? "Unknown sender")
        attachments = thread.messages.flatMap(\.attachments).filter { $0.contentID == nil }
        if let latest = thread.messages.last {
            replyContext = ReplyContext(
                threadID: thread.id,
                sender: latest.sender,
                recipients: latest.recipients,
                cc: latest.cc,
                replyTo: latest.replyTo,
                subject: latest.subject,
                date: latest.date,
                messageIDHeader: latest.messageIDHeader,
                references: latest.references,
                quotableBody: Self.quotableBody(latest),
                attachments: latest.attachments.filter { $0.contentID == nil }
            )
        } else {
            replyContext = nil
        }
        let renderedDocument = SafeHTML.conversation(thread)
        containsRemoteImages = renderedDocument.localizedCaseInsensitiveContains("data-openmime-src=")
        document = renderedDocument
        isShowingRemoteImages = false
    }

    init(
        id: String,
        subject: String,
        messageCount: Int,
        remoteImageSender: String,
        containsRemoteImages: Bool,
        attachments: [MailAttachment],
        replyContext: ReplyContext? = nil,
        document: String
    ) {
        self.id = id
        self.subject = subject
        self.messageCount = messageCount
        self.remoteImageSender = remoteImageSender
        self.containsRemoteImages = containsRemoteImages
        self.attachments = attachments
        self.replyContext = replyContext
        self.document = document
        isShowingRemoteImages = false
    }

    mutating func showRemoteImages() {
        guard containsRemoteImages, !isShowingRemoteImages else { return }
        document = document
            .replacingOccurrences(of: "data-openmime-src=", with: "src=", options: .caseInsensitive)
            .replacingOccurrences(of: "img-src data:;", with: "img-src data: https: http:;")
        isShowingRemoteImages = true
    }

    var renderID: String { "\(id):\(isShowingRemoteImages)" }

    private static func senderAddress(_ sender: String) -> String {
        if let start = sender.lastIndex(of: "<"), let end = sender.lastIndex(of: ">"), start < end {
            return String(sender[sender.index(after: start)..<end]).lowercased()
        }
        return sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func quotableBody(_ message: MailMessage) -> String {
        let source = message.plainBody ?? message.htmlBody ?? ""
        let text = source
            .replacingOccurrences(of: #"(?is)<(?:br\s*/?|/p|/div|/li)>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(100_000))
    }
}

struct ConversationWebView: NSViewRepresentable {
    let thread: RenderedThread

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedThreadID != thread.renderID else { return }
        context.coordinator.loadedThreadID = thread.renderID
        view.loadHTMLString(thread.document, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedThreadID: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if url.scheme == "https" || url.scheme == "http" || url.scheme == "mailto" {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
