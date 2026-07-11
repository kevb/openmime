import Foundation
import Testing
@testable import OpenMime

@Test func offlineErrorsAreRecognizedWithoutMisclassifyingOtherFailures() {
    #expect(Reliability.isOffline(URLError(.notConnectedToInternet)))
    #expect(Reliability.isOffline(URLError(.timedOut)))
    #expect(!Reliability.isOffline(GmailError.invalidResponse))
}

@Test func authenticationFailuresRequireAReconnect() {
    #expect(Reliability.requiresReauthentication(GmailError.requestFailed(status: 401, body: "")))
    #expect(Reliability.requiresReauthentication(GoogleContactsError.requestFailed(status: 401, message: "expired")))
    #expect(Reliability.requiresReauthentication(OAuthError.tokenExchangeFailed("invalid_grant")))
    #expect(!Reliability.requiresReauthentication(GmailError.requestFailed(status: 503, body: "")))
}

@Test func freshnessTextDoesNotPretendCachedMailWasJustUpdated() {
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(Reliability.freshnessText(lastSuccessfulSync: nil, now: now) == "Not updated yet")
    #expect(Reliability.freshnessText(lastSuccessfulSync: now.addingTimeInterval(-125), now: now) == "Updated 2 min ago")
    #expect(Reliability.freshnessText(lastSuccessfulSync: now.addingTimeInterval(-90_000), now: now) == "Updated 1 day ago")
}

@Test func cachedProfileRoundTripsForOfflineLaunch() {
    defer { CachedProfileStore.delete() }
    let profile = GmailProfile(emailAddress: "offline@example.com", messagesTotal: 10, threadsTotal: 8, historyId: "123")
    CachedProfileStore.save(profile)
    #expect(CachedProfileStore.load() == profile)
}
