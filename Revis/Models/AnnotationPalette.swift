import SwiftUI
import AppKit

/// The colours annotations are drawn in — one per intent.
///
/// Vaelora colours a comment by whoever signed it, because there the question a margin
/// mark answers is "who said this". Here it is "what is being asked": a page of marks
/// should say at a glance that three things are being cut and one is only a question,
/// without a single note being read. Authorship is still shown, on the row's byline,
/// where a second colour axis would only compete.
///
/// One tone throughout — the same saturation and lightness, different hue — so a margin
/// full of marks reads as a set rather than as decoration.
enum AnnotationPalette {

    static func hex(for intent: Intent) -> String {
        switch intent {
        case .change:   return "#e0a03a"   // amber — the commonest, and the warmest
        case .insert:   return "#4d9e97"   // teal
        case .remove:   return "#d4704f"   // terracotta, not a stoplight red: this is
                                           // a request, not an error
        case .move:     return "#8e7bc4"   // violet
        case .question: return "#5b8fc4"   // blue
        case .comment:  return "#9a9a9e"   // grey — not a request, so not a hue
        }
    }

    static func color(for intent: Intent) -> Color { Color(hex: hex(for: intent)) }

    /// The intent's colour as a bare glyph on the title bar — the palette's own colour in
    /// Dark, and the same hue taken `toolbarDeepening` toward black in Light.
    ///
    /// The palette is mid-tone because its main job is a filled disc on white paper, and
    /// that is a job it does in either appearance. A thin stroke straight on the light
    /// title bar is a different job: measured against it, amber was 1.8:1 and not one of
    /// the six reached 3:1, and a disabled button — which is how they spend most of their
    /// time, with nothing selected — dimmed that to about 1.1:1, a faint smudge where a
    /// pencil should be. In Dark the same colours sit at 4 to 6.5 and needed nothing.
    ///
    /// Deepened, not re-picked: a second set of hexes is a second opinion about what
    /// "critical" looks like, and this is still the one colour, carried to another surface.
    static func toolbarColor(for intent: Intent) -> Color {
        let colour = NSColor(hex: hex(for: intent))
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? colour : colour.darkened(by: toolbarDeepening)
        })
    }

    /// How far Light takes a toolbar glyph toward black. 0.3 puts every intent above 3.4:1
    /// on `revisWindowBackground`; 0.24, the ring's step, left amber at exactly 3.0.
    static let toolbarDeepening: CGFloat = 0.3

    /// Intent → colour as JSON, for pushing at the document runtime so the margin and the
    /// pane cannot drift apart. Assigned here rather than in JavaScript for exactly that
    /// reason: one source, two readers.
    static func json() -> String {
        let map = Dictionary(uniqueKeysWithValues:
            Intent.allCases.map { ($0.rawValue, hex(for: $0)) })
        return (try? JSONSerialization.data(withJSONObject: map))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// The colour helpers live beside the palette so there is one place that knows how a hex
// string becomes a colour, and one definition of what "darkened" means — the margin marks
// and the pane rows have to agree, and they are drawn by different code.
extension NSColor {
    convenience init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self.init(white: 0.6, alpha: 1)
            return
        }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// Toward black, in sRGB — these are fixed palette colours rather than anything the
    /// system appearance should be allowed to reinterpret.
    func darkened(by amount: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: c.redComponent * (1 - amount),
                       green: c.greenComponent * (1 - amount),
                       blue: c.blueComponent * (1 - amount), alpha: c.alphaComponent)
    }
}

extension Color {
    func darkened(by amount: CGFloat) -> Color {
        Color(nsColor: NSColor(self).darkened(by: amount))
    }

    /// `#rrggbb`. Only ever fed the palette above, so a malformed string is a programming
    /// error rather than input — it falls back to grey rather than crashing a window.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self = .gray
            return
        }
        self = Color(.sRGB,
                     red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}
