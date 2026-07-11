import Foundation

enum Reliability {
    static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
            .dataNotAllowed, .timedOut,
        ].contains(urlError.code)
    }

    static func requiresReauthentication(_ error: Error) -> Bool {
        if case GmailError.requestFailed(let status, _) = error, status == 401 { return true }
        if case GoogleContactsError.requestFailed(let status, _) = error, status == 401 { return true }
        if case OAuthError.missingRefreshToken = error { return true }
        if case OAuthError.tokenExchangeFailed(let reason) = error {
            let value = reason.lowercased()
            return value.contains("invalid_grant") || value.contains("revoked") || value.contains("expired")
        }
        return false
    }

    static func freshnessText(lastSuccessfulSync: Date?, now: Date = Date()) -> String {
        guard let date = lastSuccessfulSync else { return "Not updated yet" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 10 { return "Updated just now" }
        if seconds < 60 { return "Updated less than a minute ago" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Updated \(minutes) min ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "Updated \(hours) hr ago" }
        let days = Int(seconds / 86_400)
        return "Updated \(days) day\(days == 1 ? "" : "s") ago"
    }
}

enum SyncFreshnessStore {
    private static let prefix = "lastSuccessfulSync."

    static func load(account: String) -> Date? {
        UserDefaults.standard.object(forKey: prefix + account) as? Date
    }

    static func save(_ date: Date, account: String) {
        UserDefaults.standard.set(date, forKey: prefix + account)
    }

    static func delete(account: String) {
        UserDefaults.standard.removeObject(forKey: prefix + account)
    }
}

enum CachedProfileStore {
    private static let key = "cachedGmailProfile"

    static func load() -> GmailProfile? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(GmailProfile.self, from: data)
    }

    static func save(_ profile: GmailProfile) {
        UserDefaults.standard.set(try? JSONEncoder().encode(profile), forKey: key)
    }

    static func delete() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
