import Foundation
import Testing
@testable import OpenMime

@Suite(.serialized)
struct GmailDraftTests {
@Test func gmailDraftCreateUpdateAndSendUseOneDraftID() async throws {
    DraftURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DraftURLProtocol.self]
    let client = GmailClient(session: URLSession(configuration: configuration))
    var draft = ComposeDraft()
    draft.subject = "Autosaved"
    draft.body = "Body"

    let created = try await client.saveDraft(draft, from: "sender@gmail.com", draftID: nil, accessToken: "token")
    #expect(created == "draft-1")
    draft.body = "Updated body"
    let updated = try await client.saveDraft(draft, from: "sender@gmail.com", draftID: created, accessToken: "token")
    #expect(updated == "draft-1")
    try await client.sendDraft(id: updated, accessToken: "token")

    let requests = DraftURLProtocol.recordedRequests()
    #expect(requests.map(\.httpMethod) == ["POST", "PUT", "POST"])
    #expect(requests.map { $0.url?.path } == [
        "/gmail/v1/users/me/drafts",
        "/gmail/v1/users/me/drafts/draft-1",
        "/gmail/v1/users/me/drafts/send",
    ])
    let sendBody = DraftURLProtocol.recordedBodies().last.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
    #expect(sendBody?["id"] == "draft-1")
}

@Test func gmailDraftCanBeReconstructedForEditing() async throws {
    DraftURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DraftURLProtocol.self]
    let client = GmailClient(session: URLSession(configuration: configuration))

    let editable = try await client.editableDraft(threadID: "thread-1", accessToken: "token")
    #expect(editable?.id == "draft-1")
    #expect(editable?.draft.to == "reader@example.com")
    #expect(editable?.draft.subject == "Saved subject")
    #expect(editable?.draft.body == "Draft body")
    #expect(editable?.draft.threadID == "thread-1")
}
}

private final class DraftURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var bodies: [Data] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        requests = []
        bodies = []
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func recordedBodies() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.bodies.append(Self.bodyData(request))
        Self.lock.unlock()
        let path = request.url?.path ?? ""
        let body: Data
        if request.httpMethod == "GET", path == "/gmail/v1/users/me/drafts" {
            body = Data(#"{"drafts":[{"id":"draft-1","message":{"id":"message","threadId":"thread-1"}}]}"#.utf8)
        } else if request.httpMethod == "GET", path == "/gmail/v1/users/me/drafts/draft-1" {
            body = Data(#"{"id":"draft-1","message":{"id":"message","threadId":"thread-1","payload":{"headers":[{"name":"To","value":"reader@example.com"},{"name":"Subject","value":"Saved subject"}],"mimeType":"text/plain","body":{"data":"RHJhZnQgYm9keQ"}}}}"#.utf8)
        } else if path == "/gmail/v1/users/me/drafts/send" {
            body = Data("{}".utf8)
        } else {
            body = Data(#"{"id":"draft-1"}"#.utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
