import Foundation

struct GoogleContactsClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func contacts(accessToken: String) async throws -> [EmailContact] {
        var pageToken: String?
        var values: [String: EmailContact] = [:]
        repeat {
            var components = URLComponents(string: "https://people.googleapis.com/v1/people/me/connections")!
            var query = [
                URLQueryItem(name: "personFields", value: "names,emailAddresses"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "sortOrder", value: "LAST_MODIFIED_DESCENDING"),
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = query
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GoogleContactsError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let response = try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data)
                throw GoogleContactsError.requestFailed(
                    status: http.statusCode,
                    message: response?.error.message ?? "Unknown Google API error"
                )
            }
            let page = try JSONDecoder().decode(PeopleConnectionsPage.self, from: data)
            for contact in Self.contacts(from: page) { values[contact.email] = contact }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return values.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func contacts(from data: Data) throws -> [EmailContact] {
        contacts(from: try JSONDecoder().decode(PeopleConnectionsPage.self, from: data))
    }

    static func contactsFromOtherSearch(_ data: Data) throws -> [EmailContact] {
        let page = try JSONDecoder().decode(OtherContactsSearchPage.self, from: data)
        return contacts(from: PeopleConnectionsPage(connections: page.results?.compactMap(\.person), nextPageToken: nil))
    }

    func searchOtherContacts(query: String, accessToken: String) async throws -> [EmailContact] {
        var components = URLComponents(string: "https://people.googleapis.com/v1/otherContacts:search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "readMask", value: "names,emailAddresses"),
            URLQueryItem(name: "pageSize", value: "30"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleContactsError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let response = try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data)
            throw GoogleContactsError.requestFailed(status: http.statusCode, message: response?.error.message ?? "Unknown Google API error")
        }
        return try Self.contactsFromOtherSearch(data)
    }

    private static func contacts(from page: PeopleConnectionsPage) -> [EmailContact] {
        var values: [String: EmailContact] = [:]
        for person in page.connections ?? [] {
            let name = person.names?.first?.displayName ?? ""
            for address in person.emailAddresses ?? [] {
                let email = address.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard email.contains("@") else { continue }
                values[email] = EmailContact(name: name.isEmpty ? email : name, email: email)
            }
        }
        return Array(values.values)
    }
}

enum GoogleContactsError: LocalizedError, Equatable {
    case invalidResponse
    case requestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Google Contacts returned an invalid response."
        case .requestFailed(let status, let message):
            if status == 403 {
                "Google Contacts access was refused. Enable People API and add the contacts.readonly scope in Google Cloud, then retry. (\(message))"
            } else {
                "Google Contacts request failed (HTTP \(status)): \(message)"
            }
        }
    }
}

private struct GoogleAPIErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String }
    let error: APIError
}

private struct PeopleConnectionsPage: Decodable {
    let connections: [Person]?
    let nextPageToken: String?
}

private struct Person: Decodable {
    let names: [PersonName]?
    let emailAddresses: [PersonEmail]?
}

private struct PersonName: Decodable { let displayName: String? }
private struct PersonEmail: Decodable { let value: String }
private struct OtherContactsSearchPage: Decodable {
    struct Result: Decodable { let person: Person? }
    let results: [Result]?
}

enum GoogleContactsCache {
    private static var url: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("OpenMime", isDirectory: true)
            .appendingPathComponent("google-contacts.json")
    }

    static func load() -> [EmailContact] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([EmailContact].self, from: data)) ?? []
    }

    static func save(_ contacts: [EmailContact]) throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(contacts).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete() { if let url { try? FileManager.default.removeItem(at: url) } }
}
