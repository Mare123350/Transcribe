import Foundation

public struct SongSection: Codable, Hashable, Sendable {
    /// "Verse 1", "Chorus", "Bridge"…
    public var name: String
    public var lyrics: String

    public init(name: String, lyrics: String) {
        self.name = name
        self.lyrics = lyrics
    }
}

public struct SongRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var artist: String
    public var sections: [SongSection]

    public init(id: UUID = UUID(), title: String, artist: String = "", sections: [SongSection]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.sections = sections
    }

    enum CodingKeys: String, CodingKey { case id, title, artist, sections }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        sections = try container.decodeIfPresent([SongSection].self, forKey: .sections) ?? []
    }
}
