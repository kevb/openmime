import Foundation
import SQLite3

actor MailboxStore {
    enum StoreError: LocalizedError {
        case open(String)
        case sqlite(String)

        var errorDescription: String? {
            switch self {
            case .open(let message): "Could not open the mail cache: \(message)"
            case .sqlite(let message): "Mail cache error: \(message)"
            }
        }
    }

    nonisolated(unsafe) private let database: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func live() throws -> MailboxStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "OpenMime", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return try MailboxStore(url: support.appending(path: "mail.sqlite"))
    }

    init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let handle { sqlite3_close(handle) }
            throw StoreError.open(message)
        }
        database = handle
        try Self.execute(database, sql: "PRAGMA journal_mode=WAL")
        try Self.execute(database, sql: "PRAGMA synchronous=NORMAL")
        try Self.execute(database, sql: """
            CREATE TABLE IF NOT EXISTS thread_summaries (
                account TEXT NOT NULL,
                id TEXT NOT NULL,
                sender TEXT NOT NULL,
                subject TEXT NOT NULL,
                snippet TEXT NOT NULL,
                date REAL NOT NULL,
                is_unread INTEGER NOT NULL,
                is_starred INTEGER NOT NULL,
                message_count INTEGER NOT NULL,
                PRIMARY KEY (account, id)
            )
            """)
        try Self.execute(database, sql: "CREATE INDEX IF NOT EXISTS inbox_date ON thread_summaries(account, date DESC)")
        try Self.execute(database, sql: """
            CREATE TABLE IF NOT EXISTS sync_state (
                account TEXT PRIMARY KEY,
                history_id TEXT NOT NULL
            )
            """)
        try Self.execute(database, sql: """
            CREATE TABLE IF NOT EXISTS conversation_cache (
                account TEXT NOT NULL,
                thread_id TEXT NOT NULL,
                subject TEXT NOT NULL,
                message_count INTEGER NOT NULL,
                remote_sender TEXT NOT NULL,
                contains_remote INTEGER NOT NULL,
                attachments_json TEXT NOT NULL,
                document TEXT NOT NULL,
                updated REAL NOT NULL,
                PRIMARY KEY (account, thread_id)
            )
            """)
        try Self.execute(database, sql: """
            CREATE TABLE IF NOT EXISTS correspondents (
                account TEXT NOT NULL,
                email TEXT NOT NULL,
                name TEXT NOT NULL,
                last_seen REAL NOT NULL,
                use_count INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY (account, email)
            )
            """)
        try Self.execute(database, sql: "CREATE INDEX IF NOT EXISTS correspondent_lookup ON correspondents(account, name, email)")
        if try Self.integer(database, sql: "PRAGMA user_version") < 2 {
            try Self.execute(database, sql: "DELETE FROM thread_summaries")
            try Self.execute(database, sql: "DELETE FROM sync_state")
            try Self.execute(database, sql: "PRAGMA user_version=2")
        }
        if try Self.integer(database, sql: "PRAGMA user_version") < 3 {
            try Self.execute(database, sql: "ALTER TABLE thread_summaries ADD COLUMN attachment_names TEXT NOT NULL DEFAULT '[]'")
            // Force a lightweight resync so cached rows gain participants,
            // normalized subjects, and attachment metadata.
            try Self.execute(database, sql: "DELETE FROM thread_summaries")
            try Self.execute(database, sql: "DELETE FROM sync_state")
            try Self.execute(database, sql: "PRAGMA user_version=3")
        }
        if try Self.integer(database, sql: "PRAGMA user_version") < 4 {
            // Rebuild summaries once to collapse attachments duplicated by
            // forwarded/sent copies within the same Gmail thread.
            try Self.execute(database, sql: "DELETE FROM thread_summaries")
            try Self.execute(database, sql: "DELETE FROM sync_state")
            try Self.execute(database, sql: "PRAGMA user_version=4")
        }
        if try Self.integer(database, sql: "PRAGMA user_version") < 5 {
            // Rebuild the bounded summary window once to seed local Gmail-derived
            // address suggestions from message headers.
            try Self.execute(database, sql: "DELETE FROM thread_summaries")
            try Self.execute(database, sql: "DELETE FROM sync_state")
            try Self.execute(database, sql: "PRAGMA user_version=5")
        }
        if try Self.integer(database, sql: "PRAGMA user_version") < 6 {
            try Self.execute(database, sql: "ALTER TABLE conversation_cache ADD COLUMN reply_context_json TEXT NOT NULL DEFAULT ''")
            try Self.execute(database, sql: "PRAGMA user_version=6")
        }
        if try Self.integer(database, sql: "PRAGMA user_version") < 7 {
            // Primary now follows Gmail's category:primary query rather than
            // treating CATEGORY_PERSONAL as exact tab membership.
            try Self.execute(database, sql: "DELETE FROM thread_summaries")
            try Self.execute(database, sql: "DELETE FROM sync_state")
            try Self.execute(database, sql: "PRAGMA user_version=7")
        }
        if try Self.integer(database, sql: "PRAGMA user_version") < 8 {
            try Self.execute(database, sql: "ALTER TABLE thread_summaries ADD COLUMN label_ids TEXT NOT NULL DEFAULT '[]'")
            try Self.execute(database, sql: "DELETE FROM thread_summaries")
            try Self.execute(database, sql: "DELETE FROM sync_state")
            try Self.execute(database, sql: "PRAGMA user_version=8")
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func cachedInbox(account: String, limit: Int = 24) throws -> [ThreadSummary] {
        let statement = try prepare("""
            SELECT id, sender, subject, snippet, date, is_unread, is_starred, message_count, attachment_names, label_ids
            FROM thread_summaries WHERE account = ? ORDER BY date DESC LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(account, at: 1, in: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var values: [ThreadSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(ThreadSummary(
                id: string(statement, 0),
                sender: string(statement, 1),
                subject: string(statement, 2),
                snippet: string(statement, 3),
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                isUnread: sqlite3_column_int(statement, 5) != 0,
                isStarred: sqlite3_column_int(statement, 6) != 0,
                messageCount: Int(sqlite3_column_int(statement, 7)),
                attachmentNames: Self.decodeStringArray(string(statement, 8)),
                labelIDs: Set(Self.decodeStringArray(string(statement, 9)))
            ))
        }
        return values
    }

    func historyID(account: String) throws -> String? {
        let statement = try prepare("SELECT history_id FROM sync_state WHERE account = ?")
        defer { sqlite3_finalize(statement) }
        bind(account, at: 1, in: statement)
        return sqlite3_step(statement) == SQLITE_ROW ? string(statement, 0) : nil
    }

    func cachedThread(account: String, threadID: String) throws -> RenderedThread? {
        let statement = try prepare("""
            SELECT subject, message_count, remote_sender, contains_remote, attachments_json, document, reply_context_json
            FROM conversation_cache WHERE account = ? AND thread_id = ?
            """)
        defer { sqlite3_finalize(statement) }
        bind(account, at: 1, in: statement)
        bind(threadID, at: 2, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let attachmentsData = Data(string(statement, 4).utf8)
        let attachments = (try? JSONDecoder().decode([MailAttachment].self, from: attachmentsData)) ?? []
        let contextData = Data(string(statement, 6).utf8)
        let replyContext = try? JSONDecoder().decode(ReplyContext.self, from: contextData)
        return RenderedThread(
            id: threadID,
            subject: string(statement, 0),
            messageCount: Int(sqlite3_column_int(statement, 1)),
            remoteImageSender: string(statement, 2),
            containsRemoteImages: sqlite3_column_int(statement, 3) != 0,
            attachments: attachments,
            replyContext: replyContext,
            // Apply current display-only color normalization to older cached
            // documents as well, so the fix works immediately when offline.
            document: SafeHTML.markDarkNeutralText(in: string(statement, 5))
        )
    }

    func saveThread(account: String, thread: RenderedThread) throws {
        let attachments = String(data: try JSONEncoder().encode(thread.attachments), encoding: .utf8) ?? "[]"
        let replyContext = thread.replyContext.flatMap { try? JSONEncoder().encode($0) }
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        try transaction {
            let statement = try prepare("""
                INSERT INTO conversation_cache
                (account, thread_id, subject, message_count, remote_sender, contains_remote, attachments_json, document, updated, reply_context_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account, thread_id) DO UPDATE SET
                  subject=excluded.subject, message_count=excluded.message_count,
                  remote_sender=excluded.remote_sender, contains_remote=excluded.contains_remote,
                  attachments_json=excluded.attachments_json, document=excluded.document,
                  updated=excluded.updated, reply_context_json=excluded.reply_context_json
                """)
            bind(account, at: 1, in: statement)
            bind(thread.id, at: 2, in: statement)
            bind(thread.subject, at: 3, in: statement)
            sqlite3_bind_int(statement, 4, Int32(thread.messageCount))
            bind(thread.remoteImageSender, at: 5, in: statement)
            sqlite3_bind_int(statement, 6, thread.containsRemoteImages ? 1 : 0)
            bind(attachments, at: 7, in: statement)
            bind(thread.document, at: 8, in: statement)
            sqlite3_bind_double(statement, 9, Date().timeIntervalSince1970)
            bind(replyContext, at: 10, in: statement)
            try stepDone(statement)
            sqlite3_finalize(statement)
            let prune = try prepare("""
                DELETE FROM conversation_cache WHERE account = ? AND thread_id NOT IN (
                  SELECT thread_id FROM conversation_cache WHERE account = ? ORDER BY updated DESC LIMIT 20
                )
                """)
            bind(account, at: 1, in: prune)
            bind(account, at: 2, in: prune)
            try stepDone(prune)
            sqlite3_finalize(prune)
        }
    }

    func replaceInbox(account: String, summaries: [ThreadSummary], historyID: String) throws {
        try transaction {
            let delete = try prepare("DELETE FROM thread_summaries WHERE account = ?")
            bind(account, at: 1, in: delete)
            try stepDone(delete)
            sqlite3_finalize(delete)
            for summary in summaries { try upsert(account: account, summary: summary) }
            try saveHistoryID(account: account, historyID: historyID)
        }
    }

    func apply(
        account: String,
        upserts: [ThreadSummary],
        removals: Set<String>,
        historyID: String
    ) throws {
        try transaction {
            for id in removals {
                let statement = try prepare("DELETE FROM thread_summaries WHERE account = ? AND id = ?")
                bind(account, at: 1, in: statement)
                bind(id, at: 2, in: statement)
                try stepDone(statement)
                sqlite3_finalize(statement)
            }
            for summary in upserts { try upsert(account: account, summary: summary) }
            try saveHistoryID(account: account, historyID: historyID)
        }
    }

    func updateSummaries(
        account: String,
        upserts: [ThreadSummary] = [],
        removals: Set<String> = []
    ) throws {
        try transaction {
            for id in removals {
                let statement = try prepare("DELETE FROM thread_summaries WHERE account = ? AND id = ?")
                bind(account, at: 1, in: statement)
                bind(id, at: 2, in: statement)
                try stepDone(statement)
                sqlite3_finalize(statement)
            }
            for summary in upserts { try upsert(account: account, summary: summary) }
        }
    }

    func removeAccount(_ account: String) throws {
        try transaction {
            for table in ["thread_summaries", "sync_state", "conversation_cache", "correspondents"] {
                let statement = try prepare("DELETE FROM \(table) WHERE account = ?")
                bind(account, at: 1, in: statement)
                try stepDone(statement)
                sqlite3_finalize(statement)
            }
        }
    }

    func searchCorrespondents(account: String, matching text: String, limit: Int = 8) throws -> [EmailContact] {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let statement = try prepare("""
            SELECT name, email FROM correspondents
            WHERE account = ? AND lower(email) != lower(?)
              AND (lower(name) LIKE lower(?) OR lower(email) LIKE lower(?))
            ORDER BY use_count DESC, last_seen DESC LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }
        let pattern = "%\(term)%"
        bind(account, at: 1, in: statement)
        bind(account, at: 2, in: statement)
        bind(pattern, at: 3, in: statement)
        bind(pattern, at: 4, in: statement)
        sqlite3_bind_int(statement, 5, Int32(limit))
        var values: [EmailContact] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(EmailContact(name: string(statement, 0), email: string(statement, 1)))
        }
        return values
    }

    func saveCorrespondents(account: String, from summaries: [ThreadSummary]) throws {
        try transaction {
            for summary in summaries {
                try upsertCorrespondents(account: account, summary: summary)
            }
        }
    }

    private func upsert(account: String, summary: ThreadSummary) throws {
        let statement = try prepare("""
            INSERT INTO thread_summaries
            (account, id, sender, subject, snippet, date, is_unread, is_starred, message_count, attachment_names, label_ids)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account, id) DO UPDATE SET
              sender=excluded.sender, subject=excluded.subject, snippet=excluded.snippet,
              date=excluded.date, is_unread=excluded.is_unread,
              is_starred=excluded.is_starred, message_count=excluded.message_count,
              attachment_names=excluded.attachment_names, label_ids=excluded.label_ids
            """)
        defer { sqlite3_finalize(statement) }
        bind(account, at: 1, in: statement)
        bind(summary.id, at: 2, in: statement)
        bind(summary.sender, at: 3, in: statement)
        bind(summary.subject, at: 4, in: statement)
        bind(summary.snippet, at: 5, in: statement)
        sqlite3_bind_double(statement, 6, summary.date.timeIntervalSince1970)
        sqlite3_bind_int(statement, 7, summary.isUnread ? 1 : 0)
        sqlite3_bind_int(statement, 8, summary.isStarred ? 1 : 0)
        sqlite3_bind_int(statement, 9, Int32(summary.messageCount))
        bind(Self.encodeStringArray(summary.attachmentNames), at: 10, in: statement)
        bind(Self.encodeStringArray(Array(summary.labelIDs).sorted()), at: 11, in: statement)
        try stepDone(statement)
        try upsertCorrespondents(account: account, summary: summary)
    }

    private func upsertCorrespondents(account: String, summary: ThreadSummary) throws {
        for contact in summary.correspondents {
            let contactStatement = try prepare("""
                INSERT INTO correspondents(account, email, name, last_seen, use_count)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(account, email) DO UPDATE SET
                  name=CASE WHEN excluded.name != excluded.email THEN excluded.name ELSE correspondents.name END,
                  last_seen=max(correspondents.last_seen, excluded.last_seen),
                  use_count=correspondents.use_count + 1
                """)
            bind(account, at: 1, in: contactStatement)
            bind(contact.email, at: 2, in: contactStatement)
            bind(contact.name, at: 3, in: contactStatement)
            sqlite3_bind_double(contactStatement, 4, summary.date.timeIntervalSince1970)
            try stepDone(contactStatement)
            sqlite3_finalize(contactStatement)
        }
    }

    private static func encodeStringArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeStringArray(_ value: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? []
    }

    private func saveHistoryID(account: String, historyID: String) throws {
        let statement = try prepare("""
            INSERT INTO sync_state(account, history_id) VALUES (?, ?)
            ON CONFLICT(account) DO UPDATE SET history_id=excluded.history_id
            """)
        defer { sqlite3_finalize(statement) }
        bind(account, at: 1, in: statement)
        bind(historyID, at: 2, in: statement)
        try stepDone(statement)
    }

    private func transaction(_ body: () throws -> Void) throws {
        try Self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            try body()
            try Self.execute(database, sql: "COMMIT")
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func integer(_ database: OpaquePointer, sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int(statement, 0))
    }
}
