import Foundation
import SwiftData

/// One recorded service.
@Model
final class Session {
    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Seconds of recorded audio.
    var duration: TimeInterval = 0
    var localeIdentifier: String = ""
    var engineName: String = ""
    /// True while recording. Still true at launch means the app quit unexpectedly mid-service.
    var isRecording: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \TranscriptItem.session)
    var items: [TranscriptItem] = []

    init(title: String, localeIdentifier: String) {
        self.title = title
        self.localeIdentifier = localeIdentifier
    }

    var orderedItems: [TranscriptItem] {
        items.sorted { $0.sortIndex < $1.sortIndex }
    }

    var nextSortIndex: Double {
        (items.map(\.sortIndex).max() ?? 0) + 1
    }

    /// A sort index that places a new item directly before `item`.
    func sortIndex(before item: TranscriptItem) -> Double {
        let previous = items.map(\.sortIndex).filter { $0 < item.sortIndex }.max() ?? (item.sortIndex - 1)
        return (previous + item.sortIndex) / 2
    }

    /// A sort index that places a new item directly after `item`.
    func sortIndex(after item: TranscriptItem) -> Double {
        let next = items.map(\.sortIndex).filter { $0 > item.sortIndex }.min() ?? (item.sortIndex + 1)
        return (item.sortIndex + next) / 2
    }

    static func defaultTitle(for date: Date = .now) -> String {
        "Service — " + date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
    }
}
