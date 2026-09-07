import Foundation

/// Which dialect a Markdown document is written in.
///
/// Markdown is not one language, and a reviewer finds out which one a file is in by
/// looking at it: a pipe table renders as a table or as a row of pipes, `~~struck~~`
/// renders as a deletion or as two tildes. So this is a per-document choice with an app
/// default behind it, not a preference set once.
enum MarkdownMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case commonmark
    case gfm
    case multimarkdown
    case kramdown
    case unified
    case quarto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commonmark:    return "CommonMark"
        case .gfm:           return "GitHub Flavored"
        case .multimarkdown: return "MultiMarkdown"
        case .kramdown:      return "Kramdown"
        case .unified:       return "Unified"
        case .quarto:        return "Quarto"
        }
    }

    /// What picking this costs the reader, in the terms a reviewer thinks in.
    var detail: String {
        switch self {
        case .commonmark:
            return "The specification and nothing else. No tables, no footnotes."
        case .gfm:
            return "CommonMark plus tables, task lists and strikethrough."
        case .multimarkdown:
            return "Footnotes, definition lists, metadata, citations."
        case .kramdown:
            return "Attribute lists, definition lists, relaxed tables."
        case .unified:
            return "Everything Revis knows how to read. The safest guess for an"
                + " unfamiliar document."
        case .quarto:
            return "Pandoc and Quarto: fenced divs, callouts, cross-references."
        }
    }

    /// Read leniently, so a review written against a mode this build no longer has still
    /// opens — the same policy as `Intent.init(from:)`, for the same reason.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MarkdownMode(rawValue: raw) ?? .unified
    }
}

/// How a Markdown document is turned into the page a reviewer marks up.
///
/// **Stored in the review, not just in the preferences.** A review holds a snapshot of the
/// document it is a review of; when the document is Markdown, the snapshot is the source
/// *and the settings it was rendered under*, because those two together are what produced
/// the page the annotations were made against. Reopening a review under whatever the app's
/// defaults happen to be a month later would show a different document from the one that
/// was marked, and every anchor would be measured against something nobody reviewed.
///
/// Deliberately a subset of the ninety-odd flags `apex_options` carries. The test for
/// being here is whether flipping it changes *what a reviewer reads* — a switch that only
/// changes how the HTML is indented is not a reviewing decision, and a settings pane that
/// does not distinguish those two things is a settings pane nobody can use.
struct MarkdownOptions: Codable, Equatable, Hashable, Sendable {
    var mode: MarkdownMode = .unified

    // Block-level syntax: whether a construct is read as itself or as literal punctuation.
    var tables: Bool = true
    var gridTables: Bool = true

    /// Tables written without the `|---|---|` separator row under the header.
    ///
    /// **Off, and off deliberately against the mode presets, which turn it on for
    /// Kramdown, Unified and Quarto.** With it on, an ordinary pipe table that *does* have
    /// a separator row loses its header: `<th>` cells come out as `<td>` in a `<tbody>`
    /// with no `<thead>` at all. Measured against apex 1.1.21. A reviewer reading a
    /// specification whose table headings have quietly become data is reviewing a document
    /// nobody wrote, so this is a thing to ask for rather than a thing to be given.
    var relaxedTables: Bool = false
    var definitionLists: Bool = true
    var footnotes: Bool = true
    var taskLists: Bool = true
    var callouts: Bool = true

    // Inline syntax.
    var strikethrough: Bool = true
    var supSub: Bool = true
    var math: Bool = true
    var wikiLinks: Bool = true
    var autolink: Bool = true

    /// Change tracking — `{++inserted++}`, `{--deleted--}` — shown as marks rather than as
    /// braces. On by default in a review app, where a document arriving with somebody
    /// else's tracked changes still in it is a thing that happens and a thing worth seeing.
    var criticMarkup: Bool = true

    /// Curly quotes, en and em dashes, ellipses.
    ///
    /// Worth knowing that this one is not only cosmetic here: it is the difference between
    /// the text on screen and the text in the file, and so the thing most likely to make a
    /// quote fail to be found in the source. `MarkdownShadow` folds it back out for
    /// matching, which is why leaving it on is safe.
    var smartTypography: Bool = true

    /// Every newline a line break, as a chat window does it. Off, because a document whose
    /// source is wrapped at 90 columns then renders one ragged line per source line.
    var hardBreaks: Bool = false

    /// Whether a `---` metadata block at the top is shown or set aside.
    ///
    /// Set aside by default: frontmatter is machinery — a template name, a date, a status
    /// field — and a reviewer opening a specification did not come to read it. It is still
    /// in the source, and the inspector still reports that it was there.
    var showMetadata: Bool = false

    static let `default` = MarkdownOptions()

    /// Decoded by hand, for the reason recorded at length in `Annotation.init(from:)`:
    /// Swift's synthesised decoder throws on a missing key even where the property has a
    /// default, and `ReviewDocument` turns a decode failure into "this must be HTML". So a
    /// flag added here without this line does not fail loudly — it makes every review
    /// saved by an older build reopen empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys, _ fallback: Bool) throws -> Bool {
            try c.decodeIfPresent(Bool.self, forKey: key) ?? fallback
        }
        mode = try c.decodeIfPresent(MarkdownMode.self, forKey: .mode) ?? .unified
        tables          = try flag(.tables, true)
        relaxedTables   = try flag(.relaxedTables, false)
        gridTables      = try flag(.gridTables, true)
        definitionLists = try flag(.definitionLists, true)
        footnotes       = try flag(.footnotes, true)
        taskLists       = try flag(.taskLists, true)
        callouts        = try flag(.callouts, true)
        strikethrough   = try flag(.strikethrough, true)
        supSub          = try flag(.supSub, true)
        math            = try flag(.math, true)
        wikiLinks       = try flag(.wikiLinks, true)
        autolink        = try flag(.autolink, true)
        criticMarkup    = try flag(.criticMarkup, true)
        smartTypography = try flag(.smartTypography, true)
        hardBreaks      = try flag(.hardBreaks, false)
        showMetadata    = try flag(.showMetadata, false)
    }

    /// Written back out by hand only because writing `init(from:)` cost the synthesised
    /// memberwise initialiser.
    init(mode: MarkdownMode = .unified, tables: Bool = true, relaxedTables: Bool = false,
         gridTables: Bool = true,
         definitionLists: Bool = true, footnotes: Bool = true, taskLists: Bool = true,
         callouts: Bool = true, strikethrough: Bool = true, supSub: Bool = true,
         math: Bool = true, wikiLinks: Bool = true, autolink: Bool = true,
         criticMarkup: Bool = true, smartTypography: Bool = true,
         hardBreaks: Bool = false, showMetadata: Bool = false) {
        self.mode = mode
        self.tables = tables
        self.relaxedTables = relaxedTables
        self.gridTables = gridTables
        self.definitionLists = definitionLists
        self.footnotes = footnotes
        self.taskLists = taskLists
        self.callouts = callouts
        self.strikethrough = strikethrough
        self.supSub = supSub
        self.math = math
        self.wikiLinks = wikiLinks
        self.autolink = autolink
        self.criticMarkup = criticMarkup
        self.smartTypography = smartTypography
        self.hardBreaks = hardBreaks
        self.showMetadata = showMetadata
    }

    /// How the export names the settings a document was read under, so a reader knows
    /// which dialect the source it is editing was interpreted as.
    var summary: String {
        var parts = [mode.title]
        if !tables { parts.append("no tables") }
        if relaxedTables { parts.append("headerless tables") }
        if !footnotes { parts.append("no footnotes") }
        if smartTypography { parts.append("smart punctuation") }
        if hardBreaks { parts.append("hard line breaks") }
        return parts.joined(separator: ", ")
    }
}
