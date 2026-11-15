import SwiftData
import SwiftUI

/// Three panes: sessions, the live transcript, and an inspector for jumping to songs, verses, and headers.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SessionListView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 340)
        } detail: {
            if let session = model.selectedSession {
                TranscriptView(session: session)
                    .id(session.id)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.detailWidth = $0 }
            } else {
                ContentUnavailableView {
                    Label("No Session Selected", systemImage: "waveform")
                } description: {
                    Text("Press Record (⌘R) to start transcribing a service, or pick a session from the sidebar.")
                } actions: {
                    Button("Record") { Task { await model.toggleRecording() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .inspector(isPresented: $model.showInspector) {
            Group {
                if let session = model.selectedSession {
                    InspectorView(session: session)
                } else {
                    ContentUnavailableView("Nothing to Show", systemImage: "sidebar.right")
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 520)
            // The inspector's own button lives in the inspector's part of the toolbar, so the
            // main buttons never sit across its edge.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.showInspector.toggle() } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                    .help("Show or hide the inspector (⌥⌘I)")
                }
            }
        }
        .toolbar { RecordingToolbar() }
        // The service title is already shown large above the transcript.
        .toolbar(removing: .title)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.windowWidth = $0 }
        .sheet(isPresented: $model.isChoosingInput) { InputChooserSheet() }
        #if DEBUG
        .modifier(DebugLibraryOpener())
        #endif
        #if DEBUG
        .onAppear { LaunchTiming.windowAppeared(model) }
        #endif
        .sheet(isPresented: $model.isExporting) {
            if let session = model.selectedSession {
                ExportSheet(session: session)
            }
        }
        .sheet(isPresented: $model.isInsertingVerse) {
            if let session = model.selectedSession {
                InsertVerseSheet(session: session)
            }
        }
        .alert(
            model.recorder.problem?.title ?? "",
            isPresented: Binding(get: { model.recorder.problem != nil }, set: { if !$0 { model.recorder.problem = nil } }),
            presenting: model.recorder.problem
        ) { problem in
            Button("Open System Settings") { problem.openSettings() }
            Button("Cancel", role: .cancel) {}
        } message: { problem in
            Text(problem.message)
        }
        .alert(
            "Recording Problem",
            isPresented: Binding(get: { model.recorder.errorMessage != nil }, set: { if !$0 { model.recorder.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.recorder.errorMessage ?? "")
        }
    }
}

#if DEBUG
/// Lets the screenshot tour open the song library window.
private struct DebugLibraryOpener: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onChange(of: model.debugOpenLibrary) { openWindow(id: WindowID.songLibrary) }
    }
}
#endif
