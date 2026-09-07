import AppKit

/// The margin's marks, drawn as SF Symbols and handed to the page as images.
///
/// **Why they are not drawn in CSS.** They were. A circle built from a border, an inset
/// shadow for the white core and an outer shadow for the chosen state — and it could not
/// be made to look right. Every dimension was a fraction of a device pixel once the page's
/// own zoom was applied, and each box snapped to the pixel grid on its own, so one edge
/// rounded up while the opposite edge rounded down. That is not a bug with a fix; it is
/// what hand-assembling a fifteen-pixel control out of independently-laid-out boxes does.
/// Vaelora learned this first and wrote it down; this file exists because the lesson was
/// available and got ignored anyway.
///
/// A symbol is one shape, drawn by Apple, rasterised once and scaled as a unit. It cannot
/// be internally asymmetric, and it is the same mark the rest of the app would draw.
enum AnnotationSymbols {

    /// The disc every mark is drawn on.
    static let disc = "circle.fill"
    /// A settled or refused one: the same circle, hollow. It is still on the page, because
    /// the review records that it was answered, but it must not read as outstanding.
    static let hollow = "circle"
    /// An annotation being written but not yet in the review.
    ///
    /// DASHED, where a settled one is a plain ring. They were the same circle — same
    /// symbol, same weight, same colour — so a mark being written and one that had been
    /// dealt with were the same picture, and the margin could not tell you which it was
    /// looking at. A broken outline is the conventional way to draw something provisional
    /// and it costs nothing to say.
    static let pending = "circle.dashed"

    /// Saying something back. Not drawn on the page — a thread is read in the pane — but it
    /// lives here with the others so there is one list of the symbol names this app relies
    /// on, and one test that they all still resolve.
    static let reply = "arrowshape.turn.up.left"

    /// The two colours a hollow mark is drawn in.
    static func palette(for hex: String) -> [NSColor] {
        let colour = NSColor(hex: hex)
        return [colour, colour.darkened(by: 0.24)]
    }

    /// The symbol as a PNG data URL, ready to be a `background-image`.
    ///
    /// Rasterised well above the size it is shown at — the page scales it down with
    /// `background-size`, and one image scaled as a unit stays symmetric however the
    /// fractional edges land, which is the entire point.
    static func dataURL(_ symbol: String, palette: [NSColor], side: CGFloat = 88,
                        weight: NSFont.Weight = .regular) -> String? {
        let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: palette))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        image.isTemplate = false

        let size = image.size
        let canvas = max(size.width, size.height).rounded(.up)
        guard canvas > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(canvas * 2), pixelsHigh: Int(canvas * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: canvas, height: canvas)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2,
                              width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()

        // Cropped to the ink, then squared off. A symbol image carries its own alignment
        // padding, and that padding is NOT symmetric — drawing it as it comes leaves the
        // circle off-centre in its box, which is the same lopsidedness this file exists to
        // be rid of, just Apple's spacing rather than mine.
        guard let squared = squaredToInk(rep),
              let png = squared.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    /// The drawn pixels, centred in a square canvas.
    private static func squaredToInk(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard let bounds = inkBounds(rep), let cropped = rep.cgImage?.cropping(to: bounds)
        else { return nil }
        let side = Int(max(bounds.width, bounds.height).rounded(.up))
        guard side > 0,
              let out = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        out.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.cgContext.draw(
            cropped,
            // Whole pixels: a half-pixel offset here is antialiasing on one edge and not
            // the other, which is the difference between a mark that looks centred and one
            // that does not.
            in: CGRect(x: CGFloat((side - Int(bounds.width)) / 2),
                       y: CGFloat((side - Int(bounds.height)) / 2),
                       width: bounds.width, height: bounds.height))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// The tightest box around anything that is not fully transparent.
    private static func inkBounds(_ rep: NSBitmapImageRep) -> CGRect? {
        guard let data = rep.bitmapData, rep.samplesPerPixel == 4 else { return nil }
        let width = rep.pixelsWide, height = rep.pixelsHigh, stride = rep.bytesPerRow
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = data + y * stride
            for x in 0..<width where row[x * 4 + 3] > 8 {   // ignore stray antialiasing
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Rasterising a symbol costs a few milliseconds and the same handful recur on every
    /// render, so they are kept. Keyed by everything that changes the pixels.
    @MainActor private static var cache: [String: String] = [:]

    @MainActor
    private static func cached(_ symbol: String, palette: [NSColor], key: String,
                               weight: NSFont.Weight = .regular) -> String {
        if let hit = cache[key] { return hit }
        let url = dataURL(symbol, palette: palette, weight: weight) ?? ""
        cache[key] = url
        return url
    }

    /// How much of a ringed mark's canvas the disc occupies. The rest is the gap and the
    /// ring. The page divides by this to draw a ringed mark at a size that keeps its DISC
    /// the same as an unringed one — otherwise choosing a mark would appear to shrink it.
    static let discFraction: CGFloat = 0.70

    /// A mark: the intent's own glyph, in white, on a disc of the intent's colour.
    ///
    /// **Why not one shape for all of them, as Vaelora has.** There, a mark's colour says
    /// WHO wrote the comment, and a person has no glyph — so one shape in several colours
    /// is the whole vocabulary. Here the colour says WHAT is being asked, and what is being
    /// asked already has a glyph: the one on the row in the pane, and the one on the button
    /// in the toolbar. Leaving the margin as plain coloured dots meant the only thing tying
    /// a mark to its card was a colour you had to have learned.
    ///
    /// White on a filled disc rather than the glyph alone, because a fifteen-point
    /// `arrow.up.arrow.down` in a thin stroke is a smudge on paper.
    @MainActor
    private static func mark(_ intent: Intent, ringed: Bool) -> String {
        let hex = AnnotationPalette.hex(for: intent)
        let key = "m\(intent.rawValue)\(hex)\(ringed ? "-ring" : "")"
        if let hit = cache[key] { return hit }
        let url = composed(glyph: intent.symbol, on: NSColor(hex: hex), ringed: ringed) ?? ""
        cache[key] = url
        return url
    }

    /// The disc, the glyph and — for the chosen mark — the ring around it, rasterised
    /// well above the size they are shown at and composited as ONE image.
    ///
    /// **The ring is part of the picture, not a `box-shadow` on the element.** It was a
    /// shadow, and the two would not line up: the element is a fraction of a point wide
    /// once the page's zoom has divided it, the background image is centred in it by the
    /// browser, and the shadow is drawn from the border box — three roundings, each
    /// snapping on its own, so the ring sat up and to the left of the mark inside it. That
    /// is the same failure as building the mark out of CSS boxes, one layer out. One
    /// image cannot be off-centre from itself.
    static func composed(glyph: String, on colour: NSColor, ringed: Bool,
                         side: CGFloat = 88) -> String? {
        let discSide = ringed ? side * discFraction : side
        guard let disc = symbolImage(disc, palette: [colour], side: discSide,
                                     weight: .regular),
              let mark = symbolImage(glyph, palette: [.white], side: discSide * 0.46,
                                     weight: .bold)
        else { return nil }
        // The ring is the same circle stroked, at the full canvas, so its centre IS the
        // canvas centre and so is the disc's.
        let ring = ringed ? symbolImage(hollow, palette: [colour], side: side,
                                        weight: .semibold) : nil

        let canvas = max(ring?.size.width ?? disc.size.width,
                         ring?.size.height ?? disc.size.height).rounded(.up)
        guard canvas > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(canvas * 2), pixelsHigh: Int(canvas * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = NSSize(width: canvas, height: canvas)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        func centre(_ image: NSImage) {
            image.draw(in: NSRect(x: (canvas - image.size.width) / 2,
                                  y: (canvas - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height))
        }
        if let ring { centre(ring) }
        centre(disc)
        centre(mark)
        NSGraphicsContext.restoreGraphicsState()

        guard let squared = squaredToInk(rep),
              let png = squared.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    private static func symbolImage(_ name: String, palette: [NSColor], side: CGFloat,
                                    weight: NSFont.Weight) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: palette))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }

    /// Every image the page needs, keyed the way the runtime asks for them.
    ///
    /// Built here rather than in JavaScript for the reason everything shared is: one
    /// source, two readers. The pane's row and the margin's mark are drawn by different
    /// code and must not be able to disagree about what an intent looks like.
    @MainActor
    static func images() -> [String: String] {
        var out: [String: String] = [:]
        for intent in Intent.allCases {
            let hex = AnnotationPalette.hex(for: intent)
            out[intent.rawValue] = mark(intent, ringed: false)
            out["\(intent.rawValue):current"] = mark(intent, ringed: true)
            // Hollow, and drawn bold: a plain ring at nineteen points is a hairline and
            // reads as a smudge rather than as a mark.
            out["\(intent.rawValue):resolved"] = cached(
                hollow, palette: [NSColor(hex: hex)], key: "r\(hex)", weight: .bold)
            // A mark being written, in the colour the annotation will BE. It was always
            // amber — the colour of Change — whatever kind was being written, so a draft
            // announced itself as the wrong thing until the moment it was added.
            out["\(intent.rawValue):pending"] = cached(
                pending, palette: [NSColor(hex: hex)], key: "p\(hex)", weight: .bold)
        }
        return out
    }

    /// The images as JSON, for pushing at the page.
    @MainActor
    static func json() -> String {
        (try? JSONSerialization.data(withJSONObject: images()))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
