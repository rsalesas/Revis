import Foundation
import ApexC

/// The one place Revis talks to Apex.
///
/// Apex ships a Swift wrapper and this deliberately does not use it. `ApexOptions` there
/// exposes twelve flags; the C `apex_options` struct carries about ninety, and every
/// switch this app puts in front of a reviewer lives in the second set. (The wrapper also
/// cannot be depended on by version at all — its targets carry `.unsafeFlags`, which
/// SwiftPM refuses. See the note in `project.yml`.)
///
/// Keeping the crossing to one file is the point. Everything above it deals in
/// `MarkdownOptions`, which is a Swift value that can be stored in a review; nothing above
/// it has to know that `apex_options` is a struct with a hundred fields, or which of them
/// are pointers this app must never set.
enum MarkdownRenderer {

    /// One document at a time through Apex.
    ///
    /// **Not caution — a measured crash.** Two threads calling `apex_markdown_to_html` at
    /// once abort inside libsystem_c, reliably enough that a parallel test run found it
    /// three times running and a sequential run of the same tests never did. cmark-gfm
    /// registers its extensions in a process-wide table on first use, and nothing in that
    /// path is guarded.
    ///
    /// A lock rather than an actor because the callers are synchronous and one of them is
    /// the window's own `prepare`, which must have the document before it can show it;
    /// making that asynchronous would spread the fix across four files to no benefit.
    /// Rendering is a few milliseconds, and nothing else contends for this.
    private static let apex = NSLock()

    /// HTML for `markdown`, as a fragment.
    ///
    /// Output goes on to `HTMLSanitizer` exactly as a document read off the disk does —
    /// see `DocumentPrep.prepare(markdown:)`. That is why `unsafe` is set below: raw HTML
    /// inside a Markdown document is part of the document under review, and the layer that
    /// makes it safe is the sanitizer and the page's CSP, not a flag here. A `<figure>`
    /// silently replaced by an HTML comment is not the document somebody sent.
    static func html(for markdown: String, options: MarkdownOptions) -> String {
        var c = apex_options_for_mode(mode(options.mode))

        // A preset is a starting point, not the answer: `apex_options_for_mode` turns on
        // what the dialect implies, and these are the reviewer's overrides on top of it.
        c.enable_tables = options.tables
        c.relaxed_tables = options.relaxedTables
        c.enable_grid_tables = options.gridTables
        c.enable_definition_lists = options.definitionLists
        c.enable_footnotes = options.footnotes
        c.enable_task_lists = options.taskLists
        c.enable_callouts = options.callouts
        c.enable_strikethrough = options.strikethrough
        c.enable_sup_sub = options.supSub
        c.enable_math = options.math
        c.enable_wiki_links = options.wikiLinks
        c.enable_autolink = options.autolink
        c.enable_critic_markup = options.criticMarkup
        c.enable_smart_typography = options.smartTypography
        c.hardbreaks = options.hardBreaks
        c.strip_metadata = !options.showMetadata

        c.output_format = APEX_OUTPUT_HTML
        c.unsafe = true             // see the note above; the sanitizer is the layer
        c.validate_utf8 = true
        c.standalone = false        // a fragment: `DocumentShell` owns the page
        c.pretty = false

        // MARK: - The ones that are off because the document would be choosing
        //
        // Everything above is a reviewer's decision about how to read a file. These are
        // not: each one lets the *document* — untrusted input, the whole premise — reach
        // something outside itself, and a reviewer who turned one on would be answering a
        // question they were never asked.

        // Reads other files from the disk, at paths the document names. This is
        // `DocumentPrep.resolve`'s `src="../../../.ssh/id_rsa"` again, one layer earlier
        // and without the containment check, because the read happens inside Apex where
        // this app cannot see it. If document includes are ever wanted, they need
        // resolving here, by Revis, under the same rule images already follow.
        c.enable_file_includes = false
        // Both read bibliography and concordance files the document names. Same reason.
        c.enable_citations = false
        c.enable_indices = false
        // Downloads and loads external code. Release Revis ships without the network
        // entitlement, and the entire design of this app is that opening a document cannot
        // cause anything to execute. Not a setting, and not one to make a setting.
        c.enable_plugins = false
        c.allow_external_plugin_detection = false

        apex.lock()
        defer { apex.unlock() }
        return markdown.withCString { source -> String in
            guard let out = apex_markdown_to_html(source, strlen(source), &c) else { return "" }
            defer { apex_free_string(out) }
            return String(cString: out)
        }
    }

    /// Apex's version, for the inspector's provenance report. A document rendered by one
    /// version and reopened under another can legitimately differ, and the report is where
    /// a reviewer finds out why.
    static var version: String {
        apex.lock()
        defer { apex.unlock() }
        return String(cString: apex_version_string())
    }

    private static func mode(_ mode: MarkdownMode) -> apex_mode_t {
        switch mode {
        case .commonmark:    return APEX_MODE_COMMONMARK
        case .gfm:           return APEX_MODE_GFM
        case .multimarkdown: return APEX_MODE_MULTIMARKDOWN
        case .kramdown:      return APEX_MODE_KRAMDOWN
        case .unified:       return APEX_MODE_UNIFIED
        case .quarto:        return APEX_MODE_QUARTO
        }
    }
}
