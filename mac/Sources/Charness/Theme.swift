// The app's look in one place: colors, fonts and spacing. Neutral grays (a gray sidebar, a white conversation,
// near-black for the send button and highlights) and the fonts and sizes T3 Code uses on a Mac: the system font
// (SF Pro) for text, SF Mono for code, 14 pt replies with a relaxed line height. Every color has a light and a
// dark variant.

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI
import CharnessCore

enum Theme {
    // MARK: colors (light / dark)

    /// The conversation (and the message box).
    static let chat = color(0xFFFFFF, 0x1C1C1E)
    /// The sidebar.
    static let sidebar = color(0xF4F4F5, 0x151517)
    /// The selected thread in the sidebar, and hover.
    static let selection = color(0xE4E4E7, 0x2C2C2F)
    /// Text.
    static let text = color(0x18181B, 0xF4F4F5)
    /// Claude's replies: a little softer than `text`.
    static let replyText = color(0x3F3F46, 0xD4D4D8)
    /// Quieter text: hints, labels, project names.
    static let secondaryText = color(0x71717A, 0xA1A1AA)
    /// Your messages.
    static let bubble = color(0xF4F4F5, 0x2C2C2F)
    /// Code blocks, command output, tool cards.
    static let code = color(0xFAFAFA, 0x232326)
    /// Hairlines and outlines.
    static let border = color(0xE4E4E7, 0x333336)
    /// The send button and other highlights: the text color (near-black, near-white in dark mode).
    static let accent = color(0x18181B, 0xF4F4F5)
    /// Links in messages (blue, not underlined, as in T3 Code).
    static let link = color(0x2563EB, 0x60A5FA)
    /// Behind `inline code`: the text color at about 10%.
    static let inlineCode = color(0xECECEE, 0x34343A)

    static var nsText: NSColor { nsColor(0x18181B, 0xF4F4F5) }
    static var nsLink: NSColor { nsColor(0x2563EB, 0x60A5FA) }
    static var nsInlineCode: NSColor { nsColor(0xECECEE, 0x34343A) }
    /// The same as `replyText`, for AppKit (replies with links in them). Keep the two in step.
    static var nsReplyText: NSColor { nsColor(0x3F3F46, 0xD4D4D8) }
    /// The same as `secondaryText` (list markers in replies).
    static var nsSecondaryText: NSColor { nsColor(0x71717A, 0xA1A1AA) }

    /// Code colors, as T3 Code shows them: its "readable" Pierre Light (Pierre Light darkened until it reads well
    /// on a light code background) and Pierre Dark. The categories are CharnessCore/Syntax.swift's.
    static let syntax: [SyntaxKind: Color] = [
        .comment: color(0x5C5C5C, 0x737373),
        .string: color(0x106A2B, 0x5ECC71),
        .number: color(0x0B5267, 0x68CDF2),
        .keyword: color(0xB12251, 0xFF678D),
        .function: color(0x693ACF, 0x9D6AFB),
        .type: color(0x912BA7, 0xD568EA),
        .variable: color(0x8F4E17, 0xFFA359),
        .special: color(0x7E540E, 0xFFAB16),
        .operator: color(0x006781, 0x08C0EF),
        .punctuation: color(0x4B4B4B, 0x8A8A8A),
        .tag: color(0xA43D23, 0xFF855E),
        .attribute: color(0x0E6944, 0x60D199),
        .property: color(0x006781, 0x08C0EF),
        .value: color(0x735B02, 0xFFD452),
        .regexp: color(0x0D6971, 0x64D1DB),
    ]

    // MARK: fonts and spacing

    /// Claude's replies (and their lists): T3 Code's 14 px with its "relaxed" line height (1.625).
    static let replySize: CGFloat = 14
    static let replyLineSpacing: CGFloat = 6
    /// Your messages and the message box.
    static let userSize: CGFloat = 14
    static let userLineSpacing: CGFloat = 6
    /// Sidebar rows.
    static let sidebarSize: CGFloat = 13.5
    /// Everything else (labels, panels).
    static let uiSize: CGFloat = 13
    /// Commands, output, code (SF Mono).
    static let monoSize: CGFloat = 13

    // Markdown, after T3 Code's chat styles (its sizes are for 15 px prose; these keep the same proportions
    // to `replySize`).
    /// Headings: # ## ### and the rest.
    static var headingSizes: [CGFloat] { [replySize * 1.333, replySize * 1.2, replySize * 1.067, replySize * 0.933].map { ($0 * 2).rounded() / 2 } }
    /// Tables: one step under the text.
    static var tableSize: CGFloat { ((replySize * 0.933) * 2).rounded() / 2 }
    /// Space between paragraphs, lists, code blocks and tables; above and below headings.
    static var blockGap: CGFloat { (replySize * 0.69).rounded() }
    static var headingGapAbove: CGFloat { (replySize * 1.33).rounded() }
    static var headingGapBelow: CGFloat { (replySize * 0.53).rounded() }
    /// Between list items, and the room for a list's markers.
    static let listItemGap: CGFloat = 4
    static var listGutter: CGFloat { (replySize * 1.33).rounded() }
    /// The widest a table cell gets before its text wraps.
    static let tableCellMaxWidth: CGFloat = 330
    /// Width of the conversation column.
    static let columnWidth: CGFloat = 760

    /// The system font (SF Pro), as T3 Code uses on a Mac.
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

    /// The same for AppKit (the message box, text with links).
    static func nsFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }

    // MARK: helpers

    private static func nsColor(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light)
        }
    }

    private static func color(_ light: UInt32, _ dark: UInt32) -> Color { Color(nsColor: nsColor(light, dark)) }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif
