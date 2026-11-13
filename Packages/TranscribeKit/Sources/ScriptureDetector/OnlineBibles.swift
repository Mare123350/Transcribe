import Foundation
import Security
import SQLite3

// MARK: - Model

/// A version offered by an online provider.
public struct OnlineVersion: Sendable, Hashable, Codable, Identifiable {
    public let provider: OnlineProviderID
    public let abbreviation: String
    public let name: String
    /// The provider's own id for the version (API.Bible's bibleId).
    public let remoteID: String

    public var id: String { "\(provider.rawValue):\(remoteID)" }

    public init(provider: OnlineProviderID, abbreviation: String, name: String, remoteID: String) {
        self.provider = provider
        self.abbreviation = abbreviation
        self.name = name
        self.remoteID = remoteID
    }
}

public enum OnlineProviderID: String, Sendable, Codable, CaseIterable {
    case esv = "esv-api"
    case apiBible = "api-bible"

    public var displayName: String {
        switch self {
        case .esv: "ESV API (Crossway)"
        case .apiBible: "API.Bible"
        }
    }

    public var signUpURL: URL {
        switch self {
        case .esv: URL(string: "https://api.esv.org/account/create-application/")!
        case .apiBible: URL(string: "https://api.bible/sign-up")!
        }
    }

    /// What the provider's terms allow us to keep locally.
    public var cachePolicy: CachePolicy {
        switch self {
        // ESV API terms: no more than 500 verses stored at a time.
        case .esv: CachePolicy(maxVerses: 500, maxAge: nil)
        // API.Bible: cached Scripture must be refreshed at least every 30 days.
        case .apiBible: CachePolicy(maxVerses: nil, maxAge: 30 * 24 * 3600)
        }
    }

    /// Shown with every passage from this provider, as its terms require.
    public var attribution: String {
        switch self {
        case .esv: "Scripture quotations are from the ESV® Bible (The Holy Bible, English Standard Version®), © 2001 by Crossway, a publishing ministry of Good News Publishers. Used by permission. All rights reserved. esv.org"
        case .apiBible: "Provided by API.Bible"
        }
    }
}

public struct CachePolicy: Sendable, Equatable {
    public let maxVerses: Int?
    public let maxAge: TimeInterval?
}

public struct OnlinePassage: Sendable, Equatable {
    public let text: String
    public let copyright: String
    public let version: OnlineVersion
    public let fromCache: Bool
}

public enum OnlineBibleError: LocalizedError, Sendable, Equatable {
    case noKey(OnlineProviderID)
    case invalidKey(OnlineProviderID)
    case notFound
    case rateLimited
    case network(String)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .noKey(let provider): "Add your \(provider.displayName) key in Settings › Translations."
        case .invalidKey(let provider): "\(provider.displayName) didn't accept the key. Check it in Settings › Translations."
        case .notFound: "The provider doesn't have that passage."
        case .rateLimited: "The provider's request limit was reached. Try again in a minute."
        case .network(let detail): "Couldn't reach the provider: \(detail)"
        case .unexpected(let detail): "The provider sent an unexpected reply: \(detail)"
        }
    }
}

// MARK: - HTTP

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url, timeoutInterval: 10)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw OnlineBibleError.network(error.localizedDescription)
        }
    }
}

// MARK: - Credentials

/// Where provider keys are kept.
public protocol CredentialStore: Sendable {
    func key(for provider: OnlineProviderID) -> String?
    func setKey(_ key: String?, for provider: OnlineProviderID) throws
}

/// Keys in the user's Keychain, never in preferences or files.
public struct KeychainCredentialStore: CredentialStore {
    let service: String

    public init(service: String = "app.transcribe.Transcribe.bible-providers") {
        self.service = service
    }

    public func key(for provider: OnlineProviderID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setKey(_ key: String?, for provider: OnlineProviderID) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "Transcribe — \(provider.displayName) key"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw OnlineBibleError.unexpected("the Keychain refused to save the key (\(status))")
        }
    }
}

/// For tests and previews.
public final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var keys: [OnlineProviderID: String]
    private let lock = NSLock()

    public init(_ keys: [OnlineProviderID: String] = [:]) { self.keys = keys }

    public func key(for provider: OnlineProviderID) -> String? { lock.withLock { keys[provider] } }
    public func setKey(_ key: String?, for provider: OnlineProviderID) throws { lock.withLock { keys[provider] = key } }
}

// MARK: - Cache

/// Verses fetched online, kept within each provider's terms (see `CachePolicy`).
public final class OnlineVerseCache: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock = NSLock()

    /// `url` nil keeps the cache in memory.
    public init(url: URL?) throws {
        if let url { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        var handle: OpaquePointer?
        guard sqlite3_open(url?.path ?? ":memory:", &handle) == SQLITE_OK, let handle else { throw OnlineBibleError.unexpected("couldn't open the verse cache") }
        db = handle
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS passages(provider TEXT, version TEXT, key TEXT, text TEXT, copyright TEXT,
                verses INTEGER, fetched REAL, used REAL, PRIMARY KEY(provider, version, key));
            """, nil, nil, nil)
    }

    deinit { sqlite3_close(db) }

    public func passage(provider: OnlineProviderID, version: String, key: String, now: Date = .now) -> (text: String, copyright: String)? {
        lock.lock(); defer { lock.unlock() }
        if let maxAge = provider.cachePolicy.maxAge {
            exec("DELETE FROM passages WHERE provider = ? AND fetched < ?", [provider.rawValue, now.timeIntervalSince1970 - maxAge])
        }
        let rows = BibleTranslation.query(db, "SELECT text, copyright FROM passages WHERE provider = ? AND version = ? AND key = ?", bind: { s in
            sqlite3_bind_text(s, 1, provider.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(s, 2, version, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(s, 3, key, -1, SQLITE_TRANSIENT)
        }, row: { (String(cString: sqlite3_column_text($0, 0)), String(cString: sqlite3_column_text($0, 1))) })
        guard let row = rows.first else { return nil }
        exec("UPDATE passages SET used = ? WHERE provider = ? AND version = ? AND key = ?", [now.timeIntervalSince1970, provider.rawValue, version, key])
        return row
    }

    public func store(provider: OnlineProviderID, version: String, key: String, text: String, copyright: String, verses: Int, now: Date = .now) {
        lock.lock(); defer { lock.unlock() }
        let policy = provider.cachePolicy
        if let maxVerses = policy.maxVerses, verses > maxVerses { return }
        exec("INSERT OR REPLACE INTO passages VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [provider.rawValue, version, key, text, copyright, verses, now.timeIntervalSince1970, now.timeIntervalSince1970])
        if let maxVerses = policy.maxVerses {
            // Evict the least recently used passages until the provider is within its limit.
            while totalVerses(provider) > maxVerses {
                exec("DELETE FROM passages WHERE rowid IN (SELECT rowid FROM passages WHERE provider = ? ORDER BY used ASC LIMIT 1)", [provider.rawValue])
            }
        }
    }

    public func totalVerses(_ provider: OnlineProviderID) -> Int {
        BibleTranslation.query(db, "SELECT COALESCE(SUM(verses), 0) FROM passages WHERE provider = ?", bind: { s in
            sqlite3_bind_text(s, 1, provider.rawValue, -1, SQLITE_TRANSIENT)
        }, row: { Int(sqlite3_column_int64($0, 0)) }).first ?? 0
    }

    public func clear(_ provider: OnlineProviderID? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let provider { exec("DELETE FROM passages WHERE provider = ?", [provider.rawValue]) } else { exec("DELETE FROM passages", []) }
    }

    private func exec(_ sql: String, _ values: [Any]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let int as Int: sqlite3_bind_int64(statement, position, Int64(int))
            case let double as Double: sqlite3_bind_double(statement, position, double)
            default: sqlite3_bind_text(statement, position, "\(value)", -1, SQLITE_TRANSIENT)
            }
        }
        sqlite3_step(statement)
    }
}

// MARK: - Providers

/// Fetches passages from the ESV API and API.Bible with the user's own keys, through the cache.
public actor OnlineBibleService {
    private let http: any HTTPClient
    private let credentials: any CredentialStore
    private let cache: OnlineVerseCache
    /// API.Bible versions the user chose to use (their key decides which are available).
    public private(set) var apiBibleVersions: [OnlineVersion]
    /// Anonymous ids for API.Bible's usage reporting (FUMS). No personal data.
    private let deviceID: String
    private let sessionID = UUID().uuidString

    public static let esvVersion = OnlineVersion(provider: .esv, abbreviation: "ESV", name: "English Standard Version", remoteID: "esv")
    static let apiBibleHosts = ["https://rest.api.bible", "https://api.scripture.api.bible"]

    public init(http: any HTTPClient = URLSessionHTTPClient(), credentials: any CredentialStore, cache: OnlineVerseCache, apiBibleVersions: [OnlineVersion] = [], deviceID: String = UUID().uuidString) {
        self.http = http
        self.credentials = credentials
        self.cache = cache
        self.apiBibleVersions = apiBibleVersions
        self.deviceID = deviceID
    }

    public func setAPIBibleVersions(_ versions: [OnlineVersion]) { apiBibleVersions = versions }

    /// Versions usable right now: those whose provider has a key.
    public func availableVersions() -> [OnlineVersion] {
        var result: [OnlineVersion] = []
        if credentials.key(for: .esv) != nil { result.append(Self.esvVersion) }
        if credentials.key(for: .apiBible) != nil { result += apiBibleVersions }
        return result
    }

    public func version(abbreviation: String) -> OnlineVersion? {
        availableVersions().first { $0.abbreviation.caseInsensitiveCompare(abbreviation) == .orderedSame }
    }

    public func passage(_ reference: BibleReference, abbreviation: String) async throws -> OnlinePassage {
        guard let version = version(abbreviation: abbreviation) else { throw OnlineBibleError.notFound }
        let key = reference.key
        if let cached = cache.passage(provider: version.provider, version: version.remoteID, key: key) {
            return OnlinePassage(text: cached.text, copyright: cached.copyright, version: version, fromCache: true)
        }
        let fetched: (text: String, copyright: String)
        switch version.provider {
        case .esv: fetched = try await fetchESV(reference)
        case .apiBible: fetched = try await fetchAPIBible(reference, bibleID: version.remoteID)
        }
        cache.store(provider: version.provider, version: version.remoteID, key: key, text: fetched.text, copyright: fetched.copyright, verses: reference.verseNumbers.count)
        return OnlinePassage(text: fetched.text, copyright: fetched.copyright, version: version, fromCache: false)
    }

    /// Checks a key and, for API.Bible, lists the English versions it can use.
    public func verify(_ provider: OnlineProviderID, key: String) async throws -> [OnlineVersion] {
        switch provider {
        case .esv:
            _ = try await fetchESV(BibleReference(book: "JHN", chapter: 11, verseStart: 35), key: key)
            return [Self.esvVersion]
        case .apiBible:
            let data = try await getAPIBible("/v1/bibles?language=eng", key: key)
            struct Response: Decodable {
                struct Bible: Decodable { let id: String; let abbreviation: String?; let abbreviationLocal: String?; let name: String }
                let data: [Bible]
            }
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw OnlineBibleError.unexpected("the list of Bibles couldn't be read") }
            return response.data.map { bible in
                OnlineVersion(provider: .apiBible, abbreviation: (bible.abbreviationLocal ?? bible.abbreviation ?? bible.name).uppercased(), name: bible.name, remoteID: bible.id)
            }.sorted { $0.abbreviation < $1.abbreviation }
        }
    }

    // MARK: ESV

    private func fetchESV(_ reference: BibleReference, key: String? = nil) async throws -> (text: String, copyright: String) {
        guard let key = key ?? credentials.key(for: .esv) else { throw OnlineBibleError.noKey(.esv) }
        var components = URLComponents(string: "https://api.esv.org/v3/passage/text/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: reference.description),
            URLQueryItem(name: "include-passage-references", value: "false"),
            URLQueryItem(name: "include-verse-numbers", value: "false"),
            URLQueryItem(name: "include-first-verse-numbers", value: "false"),
            URLQueryItem(name: "include-footnotes", value: "false"),
            URLQueryItem(name: "include-headings", value: "false"),
            URLQueryItem(name: "include-short-copyright", value: "false"),
            URLQueryItem(name: "indent-poetry", value: "false"),
            URLQueryItem(name: "indent-paragraphs", value: "0"),
        ]
        let (data, status) = try await http.get(components.url!, headers: ["Authorization": "Token \(key)"])
        try Self.check(status, provider: .esv)
        struct Response: Decodable { let passages: [String] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw OnlineBibleError.unexpected("the ESV passage couldn't be read") }
        let text = collapse(response.passages.joined(separator: " "))
        guard !text.isEmpty else { throw OnlineBibleError.notFound }
        return (text, OnlineProviderID.esv.attribution)
    }

    // MARK: API.Bible

    private func fetchAPIBible(_ reference: BibleReference, bibleID: String) async throws -> (text: String, copyright: String) {
        guard let key = credentials.key(for: .apiBible) else { throw OnlineBibleError.noKey(.apiBible) }
        let range = reference.verseNumbers
        let passageID = "\(reference.book).\(reference.chapter).\(range.lowerBound)-\(reference.book).\(reference.chapter).\(range.upperBound)"
        let path = "/v1/bibles/\(bibleID)/passages/\(passageID)?content-type=text&include-notes=false&include-titles=false&include-chapter-numbers=false&include-verse-numbers=false&fums-version=3"
        let data = try await getAPIBible(path, key: key)
        struct Response: Decodable {
            struct Passage: Decodable { let content: String; let copyright: String? }
            struct Meta: Decodable { let fumsToken: String? }
            let data: Passage
            let meta: Meta?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw OnlineBibleError.unexpected("the passage couldn't be read") }
        if let token = response.meta?.fumsToken { reportUsage(token) }
        let text = collapse(response.data.content.replacingOccurrences(of: "¶", with: ""))
        guard !text.isEmpty else { throw OnlineBibleError.notFound }
        return (text, response.data.copyright.map(collapse) ?? OnlineProviderID.apiBible.attribution)
    }

    private func getAPIBible(_ path: String, key: String) async throws -> Data {
        var lastError: Error = OnlineBibleError.network("no host answered")
        for host in Self.apiBibleHosts {
            do {
                let (data, status) = try await http.get(URL(string: host + path)!, headers: ["api-key": key])
                try Self.check(status, provider: .apiBible)
                return data
            } catch let error as OnlineBibleError {
                // Try the other host only when this one couldn't be reached.
                guard case .network = error else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /// API.Bible's Fair Use Management System: an anonymous count of each display.
    private func reportUsage(_ token: String) {
        var components = URLComponents(string: "https://fums.api.bible/f3")!
        components.queryItems = [URLQueryItem(name: "t", value: token), URLQueryItem(name: "dId", value: deviceID), URLQueryItem(name: "sId", value: sessionID)]
        guard let url = components.url else { return }
        let http = http
        Task.detached { _ = try? await http.get(url, headers: [:]) }
    }

    static func check(_ status: Int, provider: OnlineProviderID) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw OnlineBibleError.invalidKey(provider)
        case 404, 400: throw OnlineBibleError.notFound
        case 429: throw OnlineBibleError.rateLimited
        default: throw OnlineBibleError.unexpected("status \(status)")
        }
    }
}
