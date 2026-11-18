import SwiftUI

/// A section header ("Worship", "Sermon: Faith in the Waiting"). Edited inline.
struct HeaderRow: View {
    @Bindable var item: TranscriptItem
    let session: Session
    @Environment(AppModel.self) private var model
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            HStack(spacing: Design.Space.s) {
                Menu {
                    ForEach(ServiceSection.allCases) { section in
                        Button { setType(section) } label: { Label(section.title, systemImage: section.symbol) }
                    }
                } label: {
                    Image(systemName: item.sectionType?.symbol ?? "number")
                        .foregroundStyle(.tint)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Change the section type")

                TextField("Section title", text: $item.title)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .focused($titleFocused)
                    .onChange(of: item.title) { if titleFocused { item.isUserEdited = true } }

                if item.isAutomatic && !item.isUserEdited {
                    Text("Auto")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, Design.Space.xs)
                        .padding(.vertical, Design.Space.xxs / 2)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                        .help(item.confidence > 0 ? "Added automatically (\(PercentFormat.string(item.confidence)) sure)" : "Added automatically")
                }
                Spacer()
                TimestampLabel(seconds: item.timestamp)
            }
            TextField("Subheader", text: $item.subtitle)
                .textFieldStyle(.plain)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 28) // design: fixed — lines the subheader up with the title after the icon
                .opacity(item.subtitle.isEmpty && !titleFocused ? 0.5 : 1)
            Divider().padding(.top, Design.Space.xs)
        }
        .padding(.top, Design.Space.l)
        .onAppear { if model.focusHeaderID == item.id { titleFocused = true; model.focusHeaderID = nil } }
        .contextMenu {
            Menu("Section Type") {
                ForEach(ServiceSection.allCases) { section in
                    Button(section.title) { setType(section) }
                }
            }
            Button("Merge with Previous Section") { model.context.delete(item) }
            Divider()
            Button("Delete Header", role: .destructive) { model.context.delete(item) }
        }
    }

    private func setType(_ section: ServiceSection) {
        let wasDefault = item.title.isEmpty || item.title == item.sectionType?.title
        item.sectionType = section
        if wasDefault { item.title = section.title }
        item.isUserEdited = true
    }
}
