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

    /// Imports a translation the user is licensed to use, in any supported format, keeping the
    /// abbreviation and name found in the file. Returns the installed file's URL.
    @discardableResult
    public static func importTranslation(from source: URL, into directory: URL, existingIDs: Set<String>) throws -> URL {
        let parsed = try TranslationImporter.parse(source)
        return try TranslationImporter.install(parsed, abbreviation: parsed.abbreviation, name: parsed.name, license: parsed.license, into: directory, existingIDs: existingIDs)
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

    static func writeSQLite(meta: [String: String], verses: [Verse], to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: temporary)
        var db: OpaquePointer?
        guard sqlite3_open(temporary.path, &db) == SQLITE_OK, let db else { throw TranslationError.cannotOpen(url.lastPathComponent) }
        let schema = """
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE verses(book TEXT NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL, text TEXT NOT NULL,
                                PRIMARY KEY(book, chapter, verse)) WITHOUT ROWID;
            BEGIN;
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw TranslationError.cannotOpen(message)
        }
        func run(_ sql: String, _ bind: (OpaquePointer) -> Void) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            bind(statement)
            sqlite3_step(statement)
        }
        for (key, value) in meta.sorted(by: { $0.key < $1.key }) {
            run("INSERT INTO meta VALUES (?, ?)") { s in
                sqlite3_bind_text(s, 1, key, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(s, 2, value, -1, SQLITE_TRANSIENT)
            }
        }
        var insert: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO verses VALUES (?, ?, ?, ?)", -1, &insert, nil)
        for verse in verses {
            sqlite3_reset(insert)
            sqlite3_bind_text(insert, 1, verse.book, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(insert, 2, Int32(verse.chapter))
            sqlite3_bind_int(insert, 3, Int32(verse.verse))
            sqlite3_bind_text(insert, 4, verse.text, -1, SQLITE_TRANSIENT)
            sqlite3_step(insert)
        }
        sqlite3_finalize(insert)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}
