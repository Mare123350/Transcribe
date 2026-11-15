import SwiftUI

/// One set of spacing, corner radii and semantic colours for the whole app.
enum Design {
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    enum Palette {
        static let scripture = Color.orange
        static let song = Color.purple
        static let live = Color.red
        static let recording = Color.red
        static let paused = Color(nsColor: .systemOrange)
        static let warning = Color(nsColor: .systemOrange)
        static let good = Color.green
    }

    /// Toolbar density for the transcript column's width, so nothing truncates or overflows.
    enum ToolbarDensity {
        case full, medium, narrow
        init(detailWidth: CGFloat) {
            self = detailWidth >= 1000 ? .full : detailWidth >= 760 ? .medium : .narrow
        }
    }
}
