import Foundation
import SongMatcher
import SwiftData

/// A song in the library. Lyrics are stored as JSON so sections keep their order.
@Model
final class StoredSong {
    var id: UUID = UUID()
    var title: String = ""
    var artist: String = ""
    var sectionsData: Data?
    var isBundled: Bool = false
    var addedAt: Date = Date()

    init(record: SongRecord, isBundled: Bool = false) {
        self.id = record.id
        self.title = record.title
        self.artist = record.artist
        self.isBundled = isBundled
        self.sections = record.sections
    }

    var sections: [SongSection] {
        get { sectionsData.flatMap { try? JSONDecoder().decode([SongSection].self, from: $0) } ?? [] }
        set { sectionsData = try? JSONEncoder().encode(newValue) }
    }

    var record: SongRecord {
        SongRecord(id: id, title: title, artist: artist, sections: sections)
    }
}
