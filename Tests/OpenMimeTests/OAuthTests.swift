import Foundation
import Testing
@testable import OpenMime

@Test func pkceVerifierAndChallengeAreURLSafe() {
    let verifier = PKCE.codeVerifier()
    let challenge = PKCE.challenge(for: verifier)
    #expect((43...128).contains(verifier.count))
    #expect(verifier.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil)
    #expect(challenge.count == 43)
    #expect(challenge.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil)
}

@Test func authorizationURLUsesLeastPrivilegeMailScope() throws {
    let configuration = OAuthConfiguration(clientID: "client.apps.googleusercontent.com", clientSecret: nil)
    let url = try GoogleOAuthClient.authorizationURL(
        configuration: configuration,
        redirectURI: URL(string: "http://127.0.0.1:54321/oauth/callback")!,
        verifier: String(repeating: "a", count: 64),
        state: "test-state"
    )
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(values["scope"]?.contains("gmail.modify") == true)
    #expect(values["scope"]?.contains("mail.google.com") == false)
    #expect(values["code_challenge_method"] == "S256")
    #expect(values["redirect_uri"] == "http://127.0.0.1:54321/oauth/callback")
}

@Test func desktopOAuthJSONLoads() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "client.json")
    let json = #"{"installed":{"client_id":"abc.apps.googleusercontent.com","client_secret":"secret"}}"#
    try Data(json.utf8).write(to: url)
    let configuration = try OAuthConfiguration.load(from: url)
    #expect(configuration.clientID == "abc.apps.googleusercontent.com")
    #expect(configuration.clientSecret == "secret")
}

@Test func webOAuthJSONIsRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "client.json")
    try Data(#"{"web":{"client_id":"wrong"}}"#.utf8).write(to: url)
    #expect(throws: OAuthConfiguration.ConfigurationError.wrongClientType) {
        try OAuthConfiguration.load(from: url)
    }
}

@Test func formEncodingIsDeterministic() {
    let body = String(data: FormEncoding.encode(["z": "hello world", "a": "x+y"]), encoding: .utf8)
    #expect(body == "a=x%2By&z=hello%20world")
}
