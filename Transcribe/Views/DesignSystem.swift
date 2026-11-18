import SwiftUI

/// The operator window's tokens: spacing, layout, radii, colour, type, elevation and motion.
/// Views use these instead of literal numbers and colours (`Tools/lint_design.sh` checks).
/// The output slide canvas and the presentation window are exempt: their sizes scale with the
/// theme's font size on a 1920×1080 canvas, not with this scale.
enum Design {
    /// A 4-point scale. Stack spacing and padding come from here.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Measurements of containers rather than gaps between things.
    enum Layout {
        /// Inside a song or verse card.
        static let cardPadding: CGFloat = 14
        /// The coloured bar on the leading edge of a song or verse card.
        static let cardStripe: CGFloat = 4
        /// Left and right margin of the transcript.
        static let pageGutter: CGFloat = 28
        /// The transcript's line length stays readable on a wide window.
        static let readingWidth: CGFloat = 900
        /// Settings-style sheets.
        static let sheetWidth: CGFloat = 520
        static let sheetPadding: CGFloat = 20
    }

    /// Concentric where nested: a control inside a card uses `small`.
    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    /// Category colours carry meaning (orange is scripture, purple is song, red is live);
    /// everything else uses the system accent and greys.
    enum Palette {
        static let accent = Color.accentColor
        static let scripture = Color.orange
        static let song = Color.purple
        static let live = Color.red
        static let recording = Color.red
        static let paused = Color(nsColor: .systemOrange)
        static let warning = Color(nsColor: .systemOrange)
        static let good = Color.green
        static let error = Color.red
        static let favorite = Color.yellow
    }

    /// The few strengths a tint or border is used at.
    enum Opacity {
        /// A card or panel washed with its category colour.
        static let wash = 0.08
        /// A selected row or a highlighted state.
        static let tint = 0.14
        /// Hairline borders in secondary grey.
        static let border = 0.35
        /// Text or a focus ring that should recede.
        static let muted = 0.6
    }

    /// The type roles used across the operator window, on top of the system text styles.
    enum Typography {
        /// A small label over a group ("Preview", "Recent", a song's "Chorus").
        static let label = Font.caption.weight(.semibold)
        /// Times and counts that change while you watch, so the digits don't jitter.
        static let timestamp = Font.caption.monospacedDigit()
        /// The icon at the top of an empty state.
        static let emptyIcon = Font.system(size: 36)
    }

    /// Elevation. Only things that float over content get a shadow.
    enum Elevation {
        static let floatingColor = Color.black.opacity(0.12)
        static let floatingRadius: CGFloat = 6
        static let floatingY: CGFloat = 2
    }

    /// Short and purposeful: ease-out for things arriving, nothing over 300 ms.
    enum Motion {
        /// A banner or row arriving.
        static let enter = Animation.easeOut(duration: 0.22)
        /// A cross-fade; also what Reduce Motion falls back to.
        static let fade = Animation.easeOut(duration: 0.15)
        /// Scrolling to a place the user asked for.
        static let scroll = Animation.easeInOut(duration: 0.25)
        /// How a slide moves from Preview to Live.
        static let slide = Animation.snappy(duration: 0.28)
        /// How far a custom button shrinks while pressed.
        static let pressScale: CGFloat = 0.97
    }

    /// How a slide moves from Preview to Live.
    static let slideAnimation = Motion.slide

    /// Toolbar density for the transcript column's width, so nothing truncates or overflows.
    enum ToolbarDensity {
        case full, medium, narrow
        init(detailWidth: CGFloat) {
            self = detailWidth >= 1000 ? .full : detailWidth >= 760 ? .medium : .narrow
        }
    }
}

extension View {
    /// The shadow for something floating over content, like the detected-song banner.
    func floatingShadow() -> some View {
        shadow(color: Design.Elevation.floatingColor, radius: Design.Elevation.floatingRadius, y: Design.Elevation.floatingY)
    }

    /// A song or verse card: washed in its category colour, with a bar of it on the leading edge.
    func categoryCard(_ color: Color) -> some View {
        padding(Design.Layout.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(Design.Opacity.wash), in: RoundedRectangle(cornerRadius: Design.Radius.medium))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: Design.Radius.medium, bottomLeadingRadius: Design.Radius.medium)
                    .fill(color)
                    .frame(width: Design.Layout.cardStripe)
            }
    }

    /// A form sheet: fixed width, standard padding.
    func sheetLayout() -> some View {
        padding(Design.Layout.sheetPadding).frame(width: Design.Layout.sheetWidth)
    }
}

/// The small label over a group ("Preview", "Recent", a song's "Chorus").
struct GroupLabel: View {
    let title: String
    var color: Color = .secondary

    init(_ title: String, color: Color = .secondary) {
        self.title = title
        self.color = color
    }

    var body: some View {
        Text(title).font(Design.Typography.label).foregroundStyle(color).textCase(.uppercase)
    }
}
