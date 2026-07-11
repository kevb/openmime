import Foundation

struct OAuthTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiration: Date

    var needsRefresh: Bool { expiration.timeIntervalSinceNow < 90 }
}

/// Development builds deliberately use a private application-support file.
/// Keychain ACLs bind local, frequently rebuilt binaries to a specific code
/// identity and can therefore present repeated password dialogs. A notarized
/// Developer ID release can replace this implementation with Keychain storage.
enum TokenStore {
    enum StoreError: LocalizedError {
        case invalidStorageDirectory

        var errorDescription: String? {
            switch self {
            case .invalidStorageDirectory:
                "OpenMime could not locate its Application Support directory."
            }
        }
    }

    private static func fileURL(named filename: String) throws -> URL {
            if let override = ProcessInfo.processInfo.environment["OPENMIME_TOKEN_STORE_PATH"] {
                let url = URL(fileURLWithPath: override)
                return filename == "oauth-tokens.json" ? url : url.deletingLastPathComponent().appendingPathComponent(filename)
            }
            guard let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw StoreError.invalidStorageDirectory
            }
            return support
                .appendingPathComponent("OpenMime", isDirectory: true)
                .appendingPathComponent(filename, isDirectory: false)
    }

    static func save(_ tokens: OAuthTokens) throws {
        try save(tokens, filename: "oauth-tokens.json")
    }

    static func load() throws -> OAuthTokens? { try load(filename: "oauth-tokens.json") }
    static func delete() throws { try delete(filename: "oauth-tokens.json") }
    // v2 adds contacts.other.readonly for Gmail interaction-derived autocomplete.
    static func saveContacts(_ tokens: OAuthTokens) throws { try save(tokens, filename: "contacts-oauth-tokens-v2.json") }
    static func loadContacts() throws -> OAuthTokens? { try load(filename: "contacts-oauth-tokens-v2.json") }
    static func deleteContacts() throws { try delete(filename: "contacts-oauth-tokens-v2.json") }

    private static func save(_ tokens: OAuthTokens, filename: String) throws {
        let url = try fileURL(named: filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(tokens)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func load(filename: String) throws -> OAuthTokens? {
        let url = try fileURL(named: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(OAuthTokens.self, from: Data(contentsOf: url))
    }

    private static func delete(filename: String) throws {
        let url = try fileURL(named: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
