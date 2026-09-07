import Foundation
import AppKit
import UniformTypeIdentifiers

/// A Markdown document, and the settings it was read under.
///
/// Both, together, because either alone is useless: the same file read as CommonMark and
/// as Kramdown is two different documents on the screen, and the annotations were made
/// against one of them. This is what makes reopening a review show what was reviewed.
struct MarkdownSource: Codable, Equatable, Sendable {
    /// The file, byte for byte as it arrived. Never rewritten — it is the thing an
    /// assistant acting on the review will be editing, and `MarkdownLocator` searches it.
    var text: String
    var options: MarkdownOptions
}

/// A document that has been made safe to show, together with what that cost.
struct PreparedDocument: Codable, Equatable, Sendable {
    /// Body markup, scrubbed, with local images inlined.
    var body: String
    /// The document's own CSS, scrubbed.
    var css: String
    var title: String?
    var report: SanitizationReport
    /// Images that could not be inlined, by their original reference — shown in the
    /// inspector so a missing figure is explained rather than just missing.
    var missingImages: [String]

    /// The Markdown behind `body`, when the document arrived as Markdown rather than HTML.
    ///
    /// **Optional, and it has to stay Optional.** This type is decoded by the synthesised
    /// decoder, which falls back to nil for a missing Optional key and *throws* for a
    /// missing one of any other kind — and `ReviewDocument.init(configuration:)` turns a
    /// throw into "these bytes must be HTML". A non-optional field added here would not
    /// fail loudly; it would make every review saved before it existed reopen as a review
    /// of its own JSON. The same trap is written up at length in `Annotation.init(from:)`.
    var markdown: MarkdownSource?

    static let empty = PreparedDocument(body: "", css: "", title: nil,
                                        report: SanitizationReport(), missingImages: [],
                                        markdown: nil)
}

/// Takes raw HTML off the disk and turns it into something the review window can show.
///
/// Sanitizing is only half of it. The other half is that a document loaded with no base
/// URL cannot resolve `images/diagram.png` — and a spec whose figures are all broken is
/// not a document anyone can review. So local images are read here, by the app, under the
/// app's own file access, and embedded as data URLs. Nothing about that goes through
/// WebKit, which means the page never gets to ask for a file: it is handed the ones the
/// app decided to hand it.
enum DocumentPrep {

    /// Per-image ceiling. A single photograph blown up to a data URL costs its own size
    /// again in base64, and a document is not more reviewable for having a 40MB figure in
    /// it — past this it is better to say the image was left out than to make the window
    /// take a minute to open.
    static let maximumImageBytes = 8 * 1024 * 1024
    /// Total across the document, for the same reason at document scale.
    static let maximumTotalImageBytes = 64 * 1024 * 1024

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "bmp", "tiff", "tif",
    ]

    /// Prepare `html` for review. `baseURL` is the folder the file came from, used to
    /// resolve relative image references; nil means there is nowhere to resolve against
    /// and every relative image is reported missing.
    static func prepare(html: String, baseURL: URL?) -> PreparedDocument {
        let clean = HTMLSanitizer.sanitize(html)
        var missing: [String] = []
        let body = inlineImages(in: clean.body, baseURL: baseURL, missing: &missing)
        return PreparedDocument(body: body, css: clean.css, title: clean.title,
                                report: clean.report, missingImages: missing, markdown: nil)
    }

    /// Prepare a Markdown document: render it, then treat the result exactly as any other
    /// untrusted HTML.
    ///
    /// The order is the point. Apex's output is not trusted because Apex produced it — a
    /// Markdown file may contain raw HTML, and `MarkdownRenderer` deliberately lets it
    /// through so that the document under review is the document that was sent. What makes
    /// it safe is the same sanitizer and the same CSP that a `.html` goes through, with
    /// nothing added and nothing skipped.
    static func prepare(markdown: String, baseURL: URL?,
                        options: MarkdownOptions) -> PreparedDocument {
        let html = MarkdownRenderer.html(for: markdown, options: options)
        var document = prepare(html: html, baseURL: baseURL)
        // A rendered fragment has no `<title>`; its name is its first heading, which is
        // what a reader would call it too.
        document.title = document.title ?? firstHeading(in: document.body)
        document.markdown = MarkdownSource(text: markdown, options: options)
        return document
    }

    /// The text of the first `<h1>`, for a document that has no title of its own.
    private static func firstHeading(in body: String) -> String? {
        guard let open = body.range(of: "<h1", options: .caseInsensitive),
              let gt = body[open.upperBound...].firstIndex(of: ">"),
              let close = body.range(of: "</h1", options: .caseInsensitive,
                                     range: gt..<body.endIndex) else { return nil }
        let inner = body[body.index(after: gt)..<close.lowerBound]
        // Tags out: a heading with a `<code>` span in it is still a name.
        var text = ""
        var depth = 0
        for ch in inner {
            if ch == "<" { depth += 1 } else if ch == ">" { depth -= 1 } else if depth == 0 {
                text.append(ch)
            }
        }
        let name = HTMLSanitizer.decodeEntities(text)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    // MARK: - Images

    /// Rewrites every `src` that names a local file into a data URL.
    ///
    /// Deliberately confined to the folder the document was opened from and its
    /// descendants. A document is untrusted input, and `src="../../../.ssh/id_rsa"` is
    /// the whole reason: resolving a path the document chose, without checking where it
    /// landed, is how a viewer becomes a way of reading files. Anything that resolves
    /// outside is reported missing rather than read.
    private static func inlineImages(in body: String, baseURL: URL?,
                                     missing: inout [String]) -> String {
        guard body.range(of: "<img", options: .caseInsensitive) != nil else { return body }
        let root = baseURL?.standardizedFileURL
        var budget = maximumTotalImageBytes
        var cache: [String: String] = [:]

        var out = ""
        var rest = Substring(body)
        while let tagStart = rest.range(of: "<img", options: .caseInsensitive) {
            out += rest[rest.startIndex..<tagStart.lowerBound]
            guard let tagEnd = rest[tagStart.upperBound...].firstIndex(of: ">") else {
                out += rest[tagStart.lowerBound...]
                return out
            }
            let tag = String(rest[tagStart.lowerBound...tagEnd])
            out += rewriteImageTag(tag, root: root, budget: &budget,
                                   cache: &cache, missing: &missing)
            rest = rest[rest.index(after: tagEnd)...]
        }
        return out + rest
    }

    private static func rewriteImageTag(_ tag: String, root: URL?, budget: inout Int,
                                        cache: inout [String: String],
                                        missing: inout [String]) -> String {
        guard let src = attribute("src", in: tag), !src.isEmpty else { return tag }
        // Already inline (the sanitizer only lets image data URLs through), or nothing we
        // can resolve.
        if src.lowercased().hasPrefix("data:") { return tag }
        guard let root else {
            missing.append(src)
            return mark(tag, missing: src)
        }
        if let hit = cache[src] { return replaceSource(tag, with: hit) }
        guard let url = resolve(src, under: root) else {
            missing.append(src)
            return mark(tag, missing: src)
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              data.count <= maximumImageBytes, data.count <= budget else {
            missing.append(src)
            return mark(tag, missing: src)
        }
        budget -= data.count
        let dataURL = "data:\(mime(for: url));base64,\(data.base64EncodedString())"
        cache[src] = dataURL
        return replaceSource(tag, with: dataURL)
    }

    /// A document-supplied path resolved against the document's folder, or nil if it is
    /// not a plain local image inside that folder.
    static func resolve(_ src: String, under root: URL) -> URL? {
        let decoded = src.removingPercentEncoding ?? src
        // A path the document wrote as absolute is not ours to follow: it names a place on
        // the reviewer's disk that has nothing to do with the document.
        guard !decoded.hasPrefix("/"), !decoded.contains("://") else { return nil }
        let candidate = URL(fileURLWithPath: decoded, relativeTo: root)
            .standardizedFileURL   // resolves the `..` segments before the check below
        guard imageExtensions.contains(candidate.pathExtension.lowercased()) else { return nil }
        // Escaped the folder — the standardisation above is what makes this check mean
        // something, since `a/../../b` only becomes `../b` once it has been done.
        guard candidate.path.hasPrefix(root.path) else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    private static func mime(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension.lowercased()),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    private static func replaceSource(_ tag: String, with dataURL: String) -> String {
        guard let range = attributeRange("src", in: tag) else { return tag }
        return tag.replacingCharacters(in: range, with: "src=\"\(dataURL)\"")
    }

    /// An image that could not be read keeps its place on the page, as a labelled gap.
    ///
    /// A figure that silently vanishes changes the document being reviewed; a gap that
    /// says "diagram.png" tells the reviewer that something was there and lets them
    /// annotate the fact.
    private static func mark(_ tag: String, missing src: String) -> String {
        guard let range = attributeRange("src", in: tag) else { return tag }
        var out = tag.replacingCharacters(
            in: range, with: "data-rv-missing=\"\(HTMLSanitizer.escapeAttribute(src))\"")
        if !out.lowercased().contains(" class=") {
            out = out.replacingOccurrences(of: "<img", with: "<img class=\"rv-missing\"",
                                           options: .caseInsensitive)
        }
        return out
    }

    // MARK: - Small attribute reader
    //
    // Deliberately separate from the sanitizer's tokenizer: this runs over markup the
    // sanitizer has already rewritten, where attribute values are known to be quoted and
    // escaped. It does not need to be defensive, and pretending otherwise would mean two
    // parsers to keep in step.

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = attributeRange(name, in: tag) else { return nil }
        let text = tag[range]
        guard let equals = text.firstIndex(of: "=") else { return nil }
        let value = text[text.index(after: equals)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return HTMLSanitizer.decodeEntities(value)
    }

    private static func attributeRange(_ name: String, in tag: String) -> Range<String.Index>? {
        var search = tag.startIndex
        while let found = tag.range(of: name + "=", options: .caseInsensitive,
                                    range: search..<tag.endIndex) {
            // Preceded by whitespace, so `data-src=` does not match a search for `src=`.
            let before = tag.index(before: found.lowerBound)
            guard found.lowerBound > tag.startIndex, tag[before].isWhitespace else {
                search = found.upperBound
                continue
            }
            var i = found.upperBound
            guard i < tag.endIndex else { return nil }
            if tag[i] == "\"" || tag[i] == "'" {
                let quote = tag[i]
                i = tag.index(after: i)
                while i < tag.endIndex, tag[i] != quote { i = tag.index(after: i) }
                if i < tag.endIndex { i = tag.index(after: i) }
            } else {
                while i < tag.endIndex, !tag[i].isWhitespace, tag[i] != ">" {
                    i = tag.index(after: i)
                }
            }
            return found.lowerBound..<i
        }
        return nil
    }
}
