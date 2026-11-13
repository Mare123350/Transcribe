import Foundation
import SQLite3

/// Finds bundled translations and manages the ones the user imports.
public enum TranslationLibrary {
    /// Opens every `.sqlite` translation in the given folders. Bundled ones come first.
    public static func load(bundled: [URL], importedDirectory: URL?) -> [BibleTranslation] {
        var result: [BibleTranslation] = []
        var seen = Set<String>()
        let order = ["kjv", "web", "bsb", "asv", "ylt"]
        let bundledTranslations = bundled.compactMap { try? BibleTranslation(url: $0, isBundled: true) }
            .sorted { (order.firstIndex(of: $0.info.id) ?? 99, $0.info.id) < (order.firstIndex(of: $1.info.id) ?? 99, $1.info.id) }
        for translation in bundledTranslations where seen.insert(translation.info.id).inserted {
            result.append(translation)
        }
        if let importedDirectory, let files = try? FileManager.default.contentsOfDirectory(at: importedDirectory, includingPropertiesForKeys: nil) {
            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "sqlite" {
                if let translation = try? BibleTranslation(url: url, isBundled: false), seen.insert(translation.info.id).inserted {
                    result.append(translation)
                }
            }
        }
        return result
    }

    /// Imports a translation the user is licensed to use: a `.sqlite` file in the documented schema,
    /// or a `.json` file (converted to SQLite). Returns the installed file's URL.
    @discardableResult
    public static func importTranslation(from source: URL, into directory: URL, existingIDs: Set<String>) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch source.pathExtension.lowercased() {
        case "sqlite", "db", "sqlite3":
            let probe = try BibleTranslation(url: source, isBundled: false)
            guard !existingIDs.contains(probe.info.id) else { throw TranslationError.duplicate(probe.info.abbreviation) }
            let destination = directory.appendingPathComponent("\(probe.info.id).sqlite")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        case "json":
            let data = try Data(contentsOf: source)
            let document: JSONTranslation
            do {
                document = try JSONDecoder().decode(JSONTranslation.self, from: data)
            } catch {
                throw TranslationError.invalidJSON(String(describing: error))
            }
            let id = (document.id ?? document.abbreviation).lowercased()
            guard !existingIDs.contains(id) else { throw TranslationError.duplicate(document.abbreviation) }
            let destination = directory.appendingPathComponent("\(id).sqlite")
            try writeSQLite(document, id: id, to: destination)
            return destination
        default:
            throw TranslationError.invalidSchema("expected a .sqlite or .json file")
        }
    }

    /// The JSON import format. `book` may be a USFM id ("JHN") or a name ("John", "1 Corinthians").
    struct JSONTranslation: Decodable {
        struct Entry: Decodable {
            let book: String
            let chapter: Int
            let verse: Int
            let text: String
        }
        let id: String?
        let abbreviation: String
        let name: String
        let license: String?
        let verses: [Entry]
    }

    static func writeSQLite(_ document: JSONTranslation, id: String, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw TranslationError.cannotOpen(url.lastPathComponent) }
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE verses(book TEXT NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL, text TEXT NOT NULL,
                                PRIMARY KEY(book, chapter, verse)) WITHOUT ROWID;
            BEGIN;
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw TranslationError.cannotOpen(String(cString: sqlite3_errmsg(db))) }

        func insert(_ sql: String, _ values: [Any]) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            for (index, value) in values.enumerated() {
                if let int = value as? Int { sqlite3_bind_int(statement, Int32(index + 1), Int32(int)) }
                else { sqlite3_bind_text(statement, Int32(index + 1), "\(value)", -1, SQLITE_TRANSIENT) }
            }
            sqlite3_step(statement)
        }

        for (key, value) in [("id", id), ("abbreviation", document.abbreviation), ("name", document.name), ("license", document.license ?? "Imported by the user"), ("schema_version", "1")] {
            insert("INSERT INTO meta VALUES (?, ?)", [key, value])
        }
        var unknownBooks = Set<String>()
        for entry in document.verses {
            let book = Books.book(entry.book.uppercased())?.id ?? Books.resolve(name: entry.book)
            guard let book else { unknownBooks.insert(entry.book); continue }
            insert("INSERT OR REPLACE INTO verses VALUES (?, ?, ?, ?)", [book, entry.chapter, entry.verse, entry.text])
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        if !unknownBooks.isEmpty && unknownBooks.count == Set(document.verses.map(\.book)).count {
            try? FileManager.default.removeItem(at: url)
            throw TranslationError.invalidJSON("no book names were recognized (for example “\(unknownBooks.first!)”)")
        }
    }
}
