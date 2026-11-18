import SwiftData
import SwiftUI

@main
struct TranscribeApp: App {
    private let container: ModelContainer
    @State private var model: AppModel

    init() {
        let container = Self.makeContainer()
        self.container = container
        _model = State(initialValue: AppModel(container: container))
    }

    var body: some Scene {
        Window("Transcribe", id: WindowID.main) {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 560)
        }
        .modelContainer(container)
        .commands { TranscribeCommands(model: model) }

        Window("Live Transcript", id: WindowID.presentation) {
            PresentationView()
                .environment(model)
        }
        .modelContainer(container)
        .defaultSize(width: 1280, height: 720)

        Window("Output", id: WindowID.output) {
            OutputWindowView()
                .environment(model)
        }
        .modelContainer(container)
        .defaultSize(width: 960, height: 540)

        Window("Song Library", id: WindowID.songLibrary) {
            SongLibraryView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .modelContainer(container)

        Settings {
            SettingsView()
                .environment(model)
        }
        .modelContainer(container)
    }

    private static func makeContainer() -> ModelContainer {
        let schema = Schema([Session.self, TranscriptItem.self, StoredSong.self])
        #if DEBUG
        if CommandLine.arguments.contains("-SoakSelfTest") {
            // Its own store on disk, so saving is measured too, without touching the real library.
            SoakSelfTest.removeStore()
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: SoakSelfTest.storeURL))
        }
        if CommandLine.arguments.contains("-PipelineSelfTest") || CommandLine.arguments.contains("-PerformanceSelfTest") || CommandLine.arguments.contains("-OutputSelfTest") || CommandLine.arguments.contains("-UIScreenshots") {
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        }
        #endif
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema))
        } catch {
            // The store couldn't be opened. Keep the app usable rather than crashing; nothing will persist.
            NSLog("Transcribe: couldn't open the session store (\(error)). Using a temporary store.")
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        }
    }
}

enum WindowID {
    static let main = "main"
    static let presentation = "presentation"
    static let songLibrary = "song-library"
    static let output = "output"
}
