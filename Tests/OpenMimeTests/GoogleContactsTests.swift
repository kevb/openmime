import Foundation
import Testing
@testable import OpenMime

@Test func contactsAuthorizationIsIndependentAndReadOnly() throws {
    let configuration = OAuthConfiguration(clientID: "client.apps.googleusercontent.com", clientSecret: nil)
    let url = try GoogleOAuthClient.authorizationURL(
        configuration: configuration,
        redirectURI: URL(string: "http://127.0.0.1:54321/oauth/callback")!,
        verifier: String(repeating: "a", count: 64),
        state: "contacts",
        scope: "https://www.googleapis.com/auth/contacts.readonly",
        loginHint: "owner@example.com"
    )
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(values["scope"] == "https://www.googleapis.com/auth/contacts.readonly")
    #expect(values["scope"]?.contains("gmail") == false)
    #expect(values["login_hint"] == "owner@example.com")
    #expect(values["prompt"] == "consent")
}

@Test func peopleConnectionsBecomeDeduplicatedAddressSuggestions() throws {
    let data = Data("""
    {"connections":[
      {"names":[{"displayName":"Ada Lovelace"}],"emailAddresses":[{"value":"ADA@example.com"}]},
      {"names":[{"displayName":"Ada Duplicate"}],"emailAddresses":[{"value":"ada@example.com"}]},
      {"emailAddresses":[{"value":"plain@example.com"}]}
    ]}
    """.utf8)
    let contacts = try GoogleContactsClient.contacts(from: data)
    #expect(contacts.count == 2)
    #expect(contacts.contains(EmailContact(name: "Ada Duplicate", email: "ada@example.com")))
    #expect(contacts.contains(EmailContact(name: "plain@example.com", email: "plain@example.com")))
}

@Test func otherContactsSearchProducesGmailStyleSuggestions() throws {
    let data = Data(#"{"results":[{"person":{"names":[{"displayName":"José Example"}],"emailAddresses":[{"value":"jose@example.com"}]}}]}"#.utf8)
    #expect(try GoogleContactsClient.contactsFromOtherSearch(data) == [EmailContact(name: "José Example", email: "jose@example.com")])
}
