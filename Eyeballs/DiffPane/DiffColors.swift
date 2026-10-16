import AppKit
import SwiftUI

/// Every colour the review window draws with, each with a light and a dark variant.
///
/// The diff colours follow GitHub's Primer palette. Translucent colours are drawn over the line's
/// own background, so they read the same on any pane background.
@MainActor
enum DiffColors {
    static let paneBackground = NSColor.textBackgroundColor

    static let addedLine = adaptive(light: rgb(0xE6FFEC), dark: rgba(46, 160, 67, 0.15))
    static let addedGutter = adaptive(light: rgb(0xCCFFD8), dark: rgba(63, 185, 80, 0.30))
    static let addedWord = adaptive(light: rgb(0xABF2BC), dark: rgba(46, 160, 67, 0.40))
    static let addedText = adaptive(light: rgb(0x1A7F37), dark: rgb(0x3FB950))

    static let deletedLine = adaptive(light: rgb(0xFFEBE9), dark: rgba(248, 81, 73, 0.15))
    static let deletedGutter = adaptive(light: rgb(0xFFD7D5), dark: rgba(248, 81, 73, 0.30))
    static let deletedWord = adaptive(light: rgba(255, 129, 130, 0.40), dark: rgba(248, 81, 73, 0.40))
    static let deletedText = adaptive(light: rgb(0xD1242F), dark: rgb(0xF85149))

    static let hunkBand = adaptive(light: rgb(0xDDF4FF), dark: rgba(56, 139, 253, 0.15))
    static let hunkGutter = adaptive(light: rgba(84, 174, 255, 0.40), dark: rgba(56, 139, 253, 0.30))
    static let gapBand = adaptive(light: rgb(0xF1F8FF), dark: rgba(56, 139, 253, 0.08))
    static let gapGutter = adaptive(light: rgba(84, 174, 255, 0.22), dark: rgba(56, 139, 253, 0.18))

    /// See-through, so an added or deleted line keeps its colour inside a thread's range.
    static let selectedLine = adaptive(light: rgba(212, 167, 44, 0.18), dark: rgba(210, 153, 34, 0.15))
    static let selectedBar = adaptive(light: rgb(0xBF8700), dark: rgb(0xD29922))

    /// "Needs you" words. The light orange is dark enough for 4.5:1 on the sidebar and on its
    /// grey selection; system orange there is about 2:1.
    static let needsYouText = adaptive(light: rgb(0x944A00), dark: rgb(0xFF9F0A))

    /// Primer's muted grey, for context lines only: on a tinted gutter it falls below 4.5:1.
    static let lineNumber = adaptive(light: rgb(0x59636E), dark: rgb(0x9198A1))
    static let marker = adaptive(light: rgba(31, 35, 40, 0.55), dark: rgba(240, 246, 252, 0.50))
    static let code = adaptive(light: rgb(0x1F2328), dark: rgb(0xE6EDF3))
    static let commentButton = adaptive(light: rgb(0x0969DA), dark: rgb(0x1F6FEB))

    static let fileHeader = adaptive(light: rgb(0xF6F8FA), dark: rgb(0x272727))
    static let border = adaptive(light: rgb(0xD1D9E0), dark: rgb(0x3D3D3D))
    static let cardBackground = adaptive(light: rgb(0xFFFFFF), dark: rgb(0x242424))
    static let cardHeader = adaptive(light: rgb(0xF6F8FA), dark: rgb(0x2B2B2B))
    static let codeBlock = adaptive(light: rgb(0xF6F8FA), dark: rgb(0x1A1A1A))
    static let checkerLight = adaptive(light: rgb(0xFFFFFF), dark: rgb(0x2A2A2A))
    static let checkerDark = adaptive(light: rgb(0xEEF1F4), dark: rgb(0x353535))

    static let keyword = adaptive(light: rgb(0xCF222E), dark: rgb(0xFF7B72))
    static let string = adaptive(light: rgb(0x0A3069), dark: rgb(0xA5D6FF))
    static let comment = adaptive(light: rgb(0x6E7781), dark: rgb(0x8B949E))
    static let constant = adaptive(light: rgb(0x0550AE), dark: rgb(0x79C0FF))
    static let function = adaptive(light: rgb(0x8250DF), dark: rgb(0xD2A8FF))
    static let key = adaptive(light: rgb(0x116329), dark: rgb(0x7EE787))
    static let type = adaptive(light: rgb(0x953800), dark: rgb(0xFFA657))

    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
            return match == .darkAqua || match == .accessibilityHighContrastDarkAqua ? dark : light
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }

    private static func rgba(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }
}

extension Color {
    @MainActor static let diffAddedText = Color(nsColor: DiffColors.addedText)
    @MainActor static let diffDeletedText = Color(nsColor: DiffColors.deletedText)
    @MainActor static let diffBorder = Color(nsColor: DiffColors.border)
    @MainActor static let cardBackground = Color(nsColor: DiffColors.cardBackground)
    @MainActor static let cardHeader = Color(nsColor: DiffColors.cardHeader)
    @MainActor static let codeBlock = Color(nsColor: DiffColors.codeBlock)
    @MainActor static let paneBackground = Color(nsColor: DiffColors.paneBackground)
    @MainActor static let needsYouText = Color(nsColor: DiffColors.needsYouText)
    /// Text on an emphasized selection, such as a list row selected while its list has focus.
    @MainActor static let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
}
