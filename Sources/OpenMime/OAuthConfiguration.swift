import Foundation

struct OAuthConfiguration: Codable, Equatable, Sendable {
    let clientID: String
    let clientSecret: String?

    enum ConfigurationError: LocalizedError {
        case invalidFile
        case wrongClientType

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                "This is not a valid Google OAuth client JSON file."
            case .wrongClientType:
                "OpenMime needs an OAuth client created with application type Desktop app."
            }
        }
    }

    private struct Download: Decodable {
        struct Installed: Decodable {
            let clientID: String
            let clientSecret: String?

            enum CodingKeys: String, CodingKey {
                case clientID = "client_id"
                case clientSecret = "client_secret"
            }
        }

        let installed: Installed?
    }

    static func load(from url: URL) throws -> OAuthConfiguration {
        let data = try Data(contentsOf: url)
        let download: Download
        do {
            download = try JSONDecoder().decode(Download.self, from: data)
        } catch {
            throw ConfigurationError.invalidFile
        }
        guard let installed = download.installed else {
            throw ConfigurationError.wrongClientType
        }
        return OAuthConfiguration(clientID: installed.clientID, clientSecret: installed.clientSecret)
    }
}

enum OAuthConfigurationStore {
    private static let key = "googleOAuthConfiguration"

    static func save(_ configuration: OAuthConfiguration) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(configuration), forKey: key)
    }

    static func load() -> OAuthConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(OAuthConfiguration.self, from: data)
    }

    static func delete() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
