import Foundation
import SQLite3

public struct TranslationInfo: Sendable, Hashable, Identifiable, Codable {
    /// Lowercase identifier, e.g. "kjv".
    public let id: String
    /// Shown to the congregation, e.g. "KJV".
    public let abbreviation: String
    public let name: String
    public let license: String
    public let isBundled: Bool
}

public struct Verse: Sendable, Hashable {
    public let book: String
    public let chapter: Int
    public let verse: Int
    public let text: String
}

public enum TranslationError: LocalizedError, Sendable {
    case cannotOpen(String)
    case invalidSchema(String)
    case invalidJSON(String)
    case duplicate(String)
    case unrecognizedFormat(String)
    case noVerses(String)
    case malformed(format: String, location: String, detail: String)
    case unknownBooks([String])

    public var errorDescription: String? {
        switch self {
        case .unrecognizedFormat(let file): "“\(file)” isn't a Bible format Transcribe can read. Use OSIS, USFM, USX, Zefania XML, or the JSON or SQLite format in docs/TRANSLATION_FORMAT.md."
        case .noVerses(let detail): "Nothing to import: \(detail)."
        case .malformed(let format, let location, let detail): "This \(format) file has a problem (\(location)): \(detail)."
        case .unknownBooks(let names): "None of the book names were recognized (for example “\(names.prefix(3).joined(separator: "”, “"))”). Use USFM codes like JHN or names like John."
        case .cannotOpen(let detail): "Couldn't open the translation: \(detail)"
        case .invalidSchema(let detail): "This file isn't a Transcribe translation database: \(detail). See docs/TRANSLATION_FORMAT.md."
        case .invalidJSON(let detail): "This JSON isn't in the Transcribe translation format: \(detail). See docs/TRANSLATION_FORMAT.md."
        case .duplicate(let abbreviation): "A translation called \(abbreviation) is already installed. Remove it first to replace it."
        }
    }
}

/// A read-only translation stored as SQLite (see docs/TRANSLATION_FORMAT.md):
///   meta(key, value)                       — id, abbreviation, name, license
///   verses(book, chapter, verse, text)     — USFM book ids
public final class BibleTranslation: @unchecked Sendable {
    public let info: TranslationInfo
    public let url: URL
    private let db: OpaquePointer
    private let lock = NSLock()

    public init(url: URL, isBundled: Bool) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw TranslationError.cannotOpen(message)
        }
        self.db = handle
        self.url = url

        var meta: [String: String] = [:]
        let tables = Self.query(handle, "SELECT name FROM sqlite_master WHERE type='table'") { String(cString: sqlite3_column_text($0, 0)) }
        guard tables.contains("verses") else {
            sqlite3_close(handle)
            throw TranslationError.invalidSchema("no verses table")
        }
        if tables.contains("meta") {
            for (key, value) in Self.query(handle, "SELECT key, value FROM meta", row: { (String(cString: sqlite3_column_text($0, 0)), String(cString: sqlite3_column_text($0, 1))) }) {
                meta[key] = value
            }
        }
        let fallback = url.deletingPathExtension().lastPathComponent
        let abbreviation = meta["abbreviation"] ?? fallback.uppercased()
        self.info = TranslationInfo(
            id: (meta["id"] ?? abbreviation).lowercased(),
            abbreviation: abbreviation,
            name: meta["name"] ?? abbreviation,
            license: meta["license"] ?? "",
            isBundled: isBundled
        )
    }

    deinit {
        sqlite3_close(db)
    }

    /// The text of a passage, verses joined with spaces. Nil if the translation lacks it.
    public func text(of reference: BibleReference) -> String? {
        let verses = self.verses(of: reference)
        return verses.isEmpty ? nil : verses.map(\.text).joined(separator: " ")
    }

    public func verses(of reference: BibleReference) -> [Verse] {
        let range = reference.verseNumbers
        lock.lock(); defer { lock.unlock() }
        return Self.query(
            db, "SELECT verse, text FROM verses WHERE book = ? AND chapter = ? AND verse BETWEEN ? AND ? ORDER BY verse",
            bind: { statement in
                sqlite3_bind_text(statement, 1, reference.book, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 2, Int32(reference.chapter))
                sqlite3_bind_int(statement, 3, Int32(range.lowerBound))
                sqlite3_bind_int(statement, 4, Int32(range.upperBound))
            },
            row: { Verse(book: reference.book, chapter: reference.chapter, verse: Int(sqlite3_column_int($0, 0)), text: String(cString: sqlite3_column_text($0, 1))) }
        )
    }

    /// Calls `body` with every verse, in storage order.
    public func forEachVerse(_ body: (Verse) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT book, chapter, verse, text FROM verses", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            body(Verse(
                book: String(cString: sqlite3_column_text(statement, 0)),
                chapter: Int(sqlite3_column_int(statement, 1)),
                verse: Int(sqlite3_column_int(statement, 2)),
                text: String(cString: sqlite3_column_text(statement, 3))
            ))
        }
    }

    static func query<T>(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void = { _ in }, row: (OpaquePointer) -> T) -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { results.append(row(statement)) }
        return results
    }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
