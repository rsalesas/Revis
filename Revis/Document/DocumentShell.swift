import Foundation

/// Assembles the page the review web view actually loads.
///
/// The shell is ours and the document is a guest inside it. That separation is the point:
/// the guest's markup has been scrubbed, its stylesheet has been scrubbed, and what it is
/// dropped into then refuses, at the browser's own level, everything a scrubber could have
/// missed.
enum DocumentShell {

    /// The last line of defence, and the one that does not depend on the sanitizer being
    /// perfect.
    ///
    /// `default-src 'none'` starts from nothing and adds back only what a document needs
    /// to be *read*: inline styles, and images that are already in the file. Notably
    /// absent, and absent on purpose:
    ///
    /// - `script-src` is `'none'`. Not "only ours" — none at all. The review runtime is
    ///   injected by the app as a user script, and a user script is not subject to the
    ///   page's policy, so this can be absolute. A `<script>` that somehow survived the
    ///   sanitizer would still not run.
    /// - No `connect-src`, so there is no fetch, no XHR, no WebSocket, no beacon. A
    ///   document cannot report that it was opened.
    /// - No `font-src` beyond data, so a webfont cannot be used as a tracking pixel.
    /// - `form-action 'none'` and `base-uri 'none'`: nothing can be submitted, and nothing
    ///   can move the document's base out from under the relative paths.
    ///
    /// Underneath this sit two more layers with no overlap in what they assume: the
    /// navigation delegate cancels every navigation the initial load, and the release
    /// build ships with no network entitlement at all.
    static let contentSecurityPolicy = [
        "default-src 'none'",
        "img-src data:",
        "style-src 'unsafe-inline'",
        "font-src data:",
        "media-src data:",
        "script-src 'none'",
        "object-src 'none'",
        "frame-src 'none'",
        "child-src 'none'",
        "connect-src 'none'",
        "form-action 'none'",
        "base-uri 'none'",
        "sandbox allow-same-origin",
    ].joined(separator: "; ")

    /// The complete page: our chrome CSS, then the document's own, then the document.
    ///
    /// That order gives the document the last word on how it looks, which is what a
    /// review needs — you are reviewing what was sent, not our idea of it. The chrome
    /// keeps its own appearance because it is addressed by ids the document does not use.
    /// - Parameter useDocumentCSS: whether the document's own stylesheet is injected.
    ///   Off, the page falls back to the chrome's own reading defaults — which is not a
    ///   cosmetic preference: a generated document can arrive in aseven-point condensed face
    ///   on a tinted ground, and being unable to read it is being unable to review it. It
    ///   is off by default nowhere, because what was sent is what is under review.
    /// - Parameter fitting: whether the document opens at Fit Width. Written into the
    ///   body's class here rather than left to the runtime to add, because the runtime runs
    ///   after the first paint: the page laid itself out at the sheet's nominal measure,
    ///   painted, and then jumped to the fitted size a frame later. Once on opening a
    ///   document is a flicker; on every change of a Markdown setting, which rebuilds the
    ///   page, it is a shrink-flash-resize on each click of a switch.
    static func page(for prepared: PreparedDocument, chromeCSS: String,
                     useDocumentCSS: Bool = true, fitting: Bool = true) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escaped(prepared.title ?? "Document"))</title>
        <style>
        \(chromeCSS)
        </style>
        <style>
        \(useDocumentCSS ? measuredAgainstTheSheet(prepared.css) : "")
        </style>
        \(sheetPaint(for: prepared, useDocumentCSS: useDocumentCSS))
        </head>
        <body class="\(bodyClass(for: prepared, useDocumentCSS: useDocumentCSS, fitting: fitting))">
        <div id="rv-page">
          <div id="rv-sheet">
            <div id="rv-doc">
        \(prepared.body)
            </div>
            <div id="rv-regions"></div>
            <div id="rv-gutter"></div>
          </div>
        </div>
        </body>
        </html>
        """
    }

    /// The document's width breakpoints, asked of the box it is laid out in rather than of
    /// the window.
    ///
    /// The sheet is 920 points of measure less its padding and the mark gutter, so the
    /// document is laid out 786 CSS pixels wide and then zoomed to fill — but a media query
    /// still measures the web view, which is wider. A document saying `@media (max-width:
    /// 900px) { one column }` therefore kept its desktop grid, a 220-pixel contents rail
    /// beside the text, squeezed into 786: its main column came out at 479 where a browser
    /// that narrow gives 750, and a two-column table with `overflow-wrap: anywhere` broke
    /// "What" into "Wha / t". The document had already said what it wants at that width; it
    /// was asking the wrong box.
    ///
    /// So a rule that asks only about WIDTH becomes a container query against `#rv-doc`
    /// (named `rv-doc` in review.css). Anything else — print, height, orientation, colour
    /// scheme, a list mixing width with any of those — is left exactly as written: the
    /// window is the right answer to those, or there is no better one. `screen` is dropped
    /// because the web view always is one. `em` and `rem` become pixels at 16 each, which is
    /// what a media query means by them; a container query would read the document's own
    /// font size instead and move the breakpoint.
    static func measuredAgainstTheSheet(_ css: String) -> String {
        var out = ""
        var i = css.startIndex
        while i < css.endIndex {
            let rest = css[i...]
            // Comments and strings are copied whole, so an `@media` inside one is text.
            if rest.hasPrefix("/*") {
                let end = rest.range(of: "*/")?.upperBound ?? css.endIndex
                out += css[i..<end]
                i = end
                continue
            }
            if css[i] == "\"" || css[i] == "'" {
                var j = css.index(after: i)
                while j < css.endIndex, css[j] != css[i] {
                    if css[j] == "\\" { j = css.index(after: j) }
                    if j < css.endIndex { j = css.index(after: j) }
                }
                let end = j < css.endIndex ? css.index(after: j) : css.endIndex
                out += css[i..<end]
                i = end
                continue
            }
            if css[i] == "@", rest.prefix(6).lowercased() == "@media",
               let brace = rest.firstIndex(where: { $0 == "{" || $0 == ";" }),
               css[brace] == "{" {
                let preludeStart = css.index(i, offsetBy: 6)
                if let condition = containerCondition(String(css[preludeStart..<brace])) {
                    out += "@container rv-doc \(condition) "
                } else {
                    out += css[i..<brace]
                }
                i = brace
                continue
            }
            out.append(css[i])
            i = css.index(after: i)
        }
        return out
    }

    /// One width test: `(max-width: 900px)`, or the range form `(width <= 900px)`. Not
    /// `device-width`, and nothing with brackets inside it, which is where a `calc` lives.
    private static let widthFeature =
        #"\(\s*(?:(?:min-|max-)?width\s*:[^()]*|[^()]*?(?<![\w-])width(?![\w-])[^()]*[<>=][^()]*)\)"#

    private static let widthOnly = try! NSRegularExpression(
        pattern: "^\(widthFeature)(?:\\s+and\\s+\(widthFeature))*$")
    private static let screenAnd = try! NSRegularExpression(
        pattern: #"^(?:only\s+)?(?:screen|all)\s+and\s+"#)
    private static let emLength = try! NSRegularExpression(pattern: #"(\d*\.?\d+)\s*r?em\b"#)

    /// The prelude of an `@media` as a container condition, or nil if it asks anything
    /// but width.
    private static func containerCondition(_ prelude: String) -> String? {
        var conditions: [String] = []
        for part in prelude.split(separator: ",") {
            var query = part.lowercased()
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            query = screenAnd.stringByReplacingMatches(
                in: query, range: NSRange(query.startIndex..., in: query), withTemplate: "")
            let whole = NSRange(query.startIndex..., in: query)
            guard !query.isEmpty, widthOnly.firstMatch(in: query, range: whole) != nil
            else { return nil }
            var pixels = query
            for match in emLength.matches(in: query, range: whole).reversed() {
                guard let range = Range(match.range, in: query),
                      let number = Range(match.range(at: 1), in: query),
                      let value = Double(query[number]) else { continue }
                let px = value * 16
                pixels.replaceSubrange(range, with: px == px.rounded()
                                       ? "\(Int(px))px" : "\(px)px")
            }
            conditions.append(pixels)
        }
        guard !conditions.isEmpty else { return nil }
        if conditions.count == 1 { return conditions[0] }
        // A media query list is an OR; a container condition says so in words, and will
        // not mix `and` with `or` without brackets.
        return conditions.map { $0.contains(" and ") ? "(\($0))" : $0 }
            .joined(separator: " or ")
    }

    /// The sheet takes the colour the document says its page is.
    ///
    /// Third stylesheet, and it has to be third. `#rv-sheet` is an id in both the chrome
    /// and here, so the two rules tie on specificity and source order is what settles it —
    /// and being after the document's own CSS is also what lets the value resolve, since a
    /// `var(--canvas)` is defined on `:root` in the stylesheet immediately above.
    ///
    /// This is the fix for the asymmetry `PageBackground` describes: the document's ink was
    /// honoured and its paper was not, which is invisible for a document designed light and
    /// fatal for one designed dark. Emitted only with the document's own stylesheet on — in
    /// the reading style there is no document CSS on the page, so there is no colour to
    /// take and nothing to be inconsistent with.
    private static func sheetPaint(for prepared: PreparedDocument,
                                   useDocumentCSS: Bool) -> String {
        guard useDocumentCSS, let background = prepared.pageBackground else { return "" }
        return "<style>\n#rv-sheet { background: \(background); }\n</style>"
    }

    /// Which of the three the page is in.
    ///
    /// `rv-reading` is the rescue — a document whose own CSS is unreadable, set aside.
    /// `rv-plain` is a document that brought no CSS at all, which is a different situation
    /// and wants a different answer: there is nothing to set aside and nothing to defer to,
    /// so this app is laying the document out and should lay it out like a document.
    private static func bodyClass(for prepared: PreparedDocument,
                                  useDocumentCSS: Bool, fitting: Bool) -> String {
        var classes: [String] = fitting ? ["rv-fitting"] : []
        if !useDocumentCSS { classes.append("rv-reading") }
        else if !prepared.hasStyle { classes.append("rv-plain") }
        return classes.joined(separator: " ")
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A resource that ships in the bundle, read as text.
    ///
    /// Falls back to walking beside the executable so a `swift build` or a test run that
    /// has no bundle to speak of still finds the stylesheet, rather than rendering a
    /// document with no chrome and leaving you to work out why.
    static func bundleString(named name: String, ext: String) -> String {
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let data = try? Data(contentsOf: url) {
            return String(decoding: data, as: UTF8.self)
        }
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // Document
            .deletingLastPathComponent()          // Revis
            .appendingPathComponent("Resources")
            .appendingPathComponent(name)
            .appendingPathExtension(ext)
        if let data = try? Data(contentsOf: here) {
            return String(decoding: data, as: UTF8.self)
        }
        return ""
    }
}
