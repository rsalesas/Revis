import Foundation

/// What the sanitizer took out, so the app can say so rather than quietly changing the
/// document under the reviewer.
///
/// This is shown in the inspector. A reviewer who is told "3 scripts and 2 remote images
/// were removed" can judge whether what they are looking at is still the document they
/// were sent; a reviewer who is told nothing cannot. It matters more here than in most
/// apps because the HTML arrives from a generator, and a generator that emitted a script
/// probably meant the page to do something.
struct SanitizationReport: Codable, Equatable, Sendable {
    var scripts = 0
    var eventHandlers = 0
    var frames = 0
    var interactive = 0
    var remoteResources = 0
    var dangerousURLs = 0

    var isClean: Bool {
        scripts == 0 && eventHandlers == 0 && frames == 0
            && interactive == 0 && remoteResources == 0 && dangerousURLs == 0
    }

    /// One line per thing removed, for the inspector.
    var lines: [(label: String, count: Int)] {
        [("Scripts", scripts), ("Event handlers", eventHandlers), ("Embedded frames", frames),
         ("Form controls", interactive), ("Remote resources", remoteResources),
         ("Unsafe links", dangerousURLs)].filter { $0.1 > 0 }
    }
}

/// The result of scrubbing a document.
struct SanitizedHTML: Equatable, Sendable {
    /// Body markup only — no `<html>`, `<head>` or `<body>`. The shell is ours.
    var body: String
    /// The document's own `<style>` rules, concatenated and scrubbed. Kept, because a
    /// generated document's appearance is part of what is being reviewed: stripping the
    /// stylesheet would mean reviewing a different document from the one that was sent.
    var css: String
    /// The `<title>`, if it had one.
    var title: String?
    var report: SanitizationReport
}

/// Turns untrusted HTML into something inert.
///
/// **Why this is written by hand rather than done in the web view.** The obvious approach
/// is to load the document and clean it up with JavaScript afterwards. That is backwards:
/// by the time a script can run to remove the scripts, the scripts have run. Everything
/// here happens before a single byte reaches WebKit.
///
/// **Why a tokenizer and not a regular expression.** Regular expressions do not parse
/// HTML, and every "strip tags with a regex" is eventually got past — a quote inside an
/// attribute, a null byte, a `<scr<script>ipt>`. This walks the string once with a small
/// state machine that has the same idea of where a tag starts and ends that a browser
/// does, and it is a *denylist over elements* combined with an *allowlist over
/// attributes*: anything unrecognised keeps its shape and loses its powers.
///
/// **What is left.** Structure, text, tables, images and the document's own CSS. What is
/// gone: every script (including the raw text inside one), every `on…` handler, every
/// frame and object, every form control, and every URL whose scheme can execute. The
/// remaining defences live outside this file — a Content Security Policy in the shell, a
/// navigation delegate that cancels everything, no network entitlement — and none of them
/// is trusted to be the only one.
enum HTMLSanitizer {

    /// Elements dropped along with everything inside them. Content included, because the
    /// content of a `<script>` is the danger and the content of an `<iframe>` is not ours
    /// to render.
    private static let dropWithContent: Set<String> = [
        "script", "iframe", "object", "embed", "applet", "frame", "frameset",
        "noframes", "noscript", "template", "button", "select", "textarea", "datalist",
    ]

    /// Elements whose tag is dropped but whose contents stay — wrappers we replace with
    /// our own, or that would put the page in charge of something it should not be.
    private static let unwrap: Set<String> = [
        "html", "head", "body", "form", "fieldset", "legend", "label", "output",
    ]

    /// Void elements dropped outright: they load or redirect, and nothing they do is
    /// worth keeping. `<link>` and `<meta>` are here because between them they can pull a
    /// remote stylesheet and refresh the page to another URL.
    private static let dropVoid: Set<String> = [
        "base", "meta", "link", "input", "source", "track", "param", "keygen",
    ]

    /// Attributes kept as-is on any element. Everything not named here — or matched by the
    /// `data-` and `aria-` prefixes, or handled as a URL below — is dropped.
    private static let safeAttributes: Set<String> = [
        "id", "class", "title", "alt", "lang", "dir", "role",
        "colspan", "rowspan", "headers", "scope", "span",
        "width", "height", "start", "reversed", "value", "type", "datetime",
        "align", "valign", "cite", "abbr", "loading", "decoding",
    ]

    /// Attributes holding a URL, checked against `isSafeURL` rather than allowed outright.
    private static let urlAttributes: Set<String> = [
        "href", "src", "srcset", "poster", "action", "data", "background",
        "formaction", "xlink:href", "longdesc", "usemap", "profile", "manifest",
    ]

    /// Void elements, so `<br>` does not swallow the rest of the document looking for a
    /// closing tag it will never find.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr",
    ]

    // MARK: - Entry point

    static func sanitize(_ html: String) -> SanitizedHTML {
        var report = SanitizationReport()
        var out = ""
        var css = ""
        var title: String?

        let scalars = Array(html)
        var i = 0
        /// How deep inside a dropped element we are. Non-zero means everything — text
        /// included — is thrown away until it closes.
        var suppressDepth = 0
        var suppressTag = ""

        while i < scalars.count {
            guard scalars[i] == "<" else {
                if suppressDepth == 0 { out.append(scalars[i]) }
                i += 1
                continue
            }

            // Comments. Dropped entirely: a conditional comment is markup to some parsers,
            // and nothing in a review depends on one surviving.
            if matches(scalars, at: i, "<!--") {
                i = skip(scalars, from: i + 4, until: "-->") ?? scalars.count
                continue
            }
            // Doctype and other declarations. We write our own shell, so these go.
            if matches(scalars, at: i, "<!") {
                i = skip(scalars, from: i + 2, until: ">") ?? scalars.count
                continue
            }
            // Processing instructions (`<?xml … ?>`), which some generators still emit.
            if matches(scalars, at: i, "<?") {
                i = skip(scalars, from: i + 2, until: ">") ?? scalars.count
                continue
            }

            guard let tag = readTag(scalars, from: i) else {
                // A `<` that does not start a tag is text. Escaped, so it stays text: left
                // raw it could combine with what follows to become one.
                if suppressDepth == 0 { out.append("&lt;") }
                i += 1
                continue
            }
            i = tag.end

            let name = tag.name

            // While suppressing, the only thing that matters is finding the way out.
            if suppressDepth > 0 {
                if name == suppressTag {
                    if tag.isClosing { suppressDepth -= 1 }
                    else if !tag.isSelfClosing && !voidElements.contains(name) { suppressDepth += 1 }
                }
                continue
            }

            // `<style>` and `<title>` hold raw text rather than markup, so they are read
            // whole here rather than left to the tag loop.
            if !tag.isClosing, name == "style" {
                let (text, next) = rawText(scalars, from: i, closing: "style")
                css += scrubCSS(text, report: &report) + "\n"
                i = next
                continue
            }
            if !tag.isClosing, name == "title" {
                let (text, next) = rawText(scalars, from: i, closing: "title")
                if title == nil {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { title = decodeEntities(trimmed) }
                }
                i = next
                continue
            }

            // Counted before the element is disposed of, whichever way it goes. An
            // `onload` on `<body>` is removed either way — the tag is unwrapped — but a
            // report that did not mention it would tell the reviewer their document was
            // clean when it had tried to run code the moment it opened. What was removed
            // is worth saying even when removing it was free.
            countHandlers(tag, into: &report)

            if dropWithContent.contains(name) {
                count(name, into: &report)
                // A closing tag with no opener is stray — ignore it rather than going into
                // a suppression that nothing will ever close.
                if !tag.isClosing, !tag.isSelfClosing, !voidElements.contains(name) {
                    suppressDepth = 1
                    suppressTag = name
                }
                continue
            }
            if dropVoid.contains(name) {
                if name == "input" { report.interactive += 1 }
                continue
            }
            if unwrap.contains(name) { continue }
            if tag.isClosing {
                out += "</\(name)>"
                continue
            }

            out += rebuild(tag, report: &report)
        }

        return SanitizedHTML(body: out, css: css, title: title, report: report)
    }

    /// Event handlers on a tag that is about to be thrown away. `rebuild` counts them for
    /// every tag that survives; this covers the ones that do not, so the two paths cannot
    /// report different totals for the same document.
    private static func countHandlers(_ tag: Tag, into report: inout SanitizationReport) {
        guard dropWithContent.contains(tag.name) || dropVoid.contains(tag.name)
                || unwrap.contains(tag.name) else { return }
        for attribute in tag.attributes where attribute.name.lowercased().hasPrefix("on") {
            report.eventHandlers += 1
        }
    }

    private static func count(_ name: String, into report: inout SanitizationReport) {
        switch name {
        case "script", "noscript": report.scripts += 1
        case "iframe", "frame", "frameset", "noframes", "object", "embed", "applet":
            report.frames += 1
        default: report.interactive += 1
        }
    }

    // MARK: - Rebuilding a start tag

    /// Writes the tag back out with only the attributes that survived the policy.
    private static func rebuild(_ tag: Tag, report: inout SanitizationReport) -> String {
        var out = "<" + tag.name
        for attribute in tag.attributes {
            let key = attribute.name.lowercased()

            // Every `on…` attribute, without exception and without a list to fall behind.
            // A list of known handler names is a list that a new one is not on yet.
            if key.hasPrefix("on") {
                report.eventHandlers += 1
                continue
            }
            // Our own anchors. The document is not allowed to supply these: a page that
            // stamped its own `data-rv` indices could make a marker point somewhere the
            // reviewer never marked.
            if key.hasPrefix("data-rv") { continue }

            if urlAttributes.contains(key) {
                guard let value = attribute.value else { continue }
                switch classifyURL(value) {
                case .safe:
                    out += " \(key)=\"\(escapeAttribute(value))\""
                case .remote:
                    // Kept as a *record* rather than a live reference: the shell's CSP
                    // would refuse to fetch it anyway, and rewriting it to nothing would
                    // leave an image with no sign of what it was meant to be.
                    report.remoteResources += 1
                    if key == "src" { out += " data-rv-blocked=\"\(escapeAttribute(value))\"" }
                    else if key == "href" { out += " href=\"\(escapeAttribute(value))\"" }
                case .dangerous:
                    report.dangerousURLs += 1
                }
                continue
            }
            if key == "style" {
                guard let value = attribute.value else { continue }
                var inner = SanitizationReport()
                let scrubbed = scrubCSS(value, report: &inner)
                report.remoteResources += inner.remoteResources
                report.dangerousURLs += inner.dangerousURLs
                if !scrubbed.trimmingCharacters(in: .whitespaces).isEmpty {
                    out += " style=\"\(escapeAttribute(scrubbed))\""
                }
                continue
            }
            guard safeAttributes.contains(key) || key.hasPrefix("data-") || key.hasPrefix("aria-")
            else { continue }
            if let value = attribute.value {
                out += " \(key)=\"\(escapeAttribute(value))\""
            } else {
                out += " \(key)"
            }
        }
        // Self-closing syntax is meaningless on an HTML void element and harmful on a
        // non-void one (browsers ignore the slash and the element swallows the rest of the
        // document), so it is written only where it is true.
        out += voidElements.contains(tag.name) ? " />" : ">"
        return out
    }

    // MARK: - URLs

    /// Internal rather than private so the tests can name it. This is the single most
    /// security-relevant decision the app makes — `javascript:` spelled six ways, a
    /// `data:` URL that is a whole HTML document — and a rule that cannot be tested
    /// directly is a rule that gets tested through six layers of markup, or not at all.
    enum URLVerdict { case safe, remote, dangerous }

    /// Fragments and relative paths are safe; `http(s)` and `mailto` are remote; anything
    /// that can execute is not allowed through at all.
    ///
    /// The check is done on a *decoded, whitespace-stripped, lowercased* copy, because
    /// `java&#0000115;cript:` and `java\tscript:` are both `javascript:` to a browser and
    /// neither is to a naive prefix test.
    static func classifyURL(_ raw: String) -> URLVerdict {
        let decoded = decodeEntities(raw)
            .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0)
                                     && $0.value != 0 }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .lowercased()
        if decoded.isEmpty || decoded.hasPrefix("#") { return .safe }

        // No colon before the first `/`, `?` or `#` means there is no scheme, so it is a
        // relative path — which cannot execute and cannot reach the network from a
        // document loaded with no base URL.
        guard let colon = decoded.firstIndex(of: ":") else { return .safe }
        let scheme = String(decoded[decoded.startIndex..<colon])
        if scheme.contains("/") || scheme.contains("?") || scheme.contains("#") { return .safe }

        switch scheme {
        case "http", "https", "mailto", "tel": return .remote
        case "data":
            // Only images. `data:text/html` is a whole document with a whole document's
            // powers, and it is the standard way past a naive data-URL allowance.
            let rest = decoded[decoded.index(after: colon)...]
            return rest.hasPrefix("image/") && !rest.hasPrefix("image/svg") ? .safe : .dangerous
        default:
            // javascript:, vbscript:, file:, and anything a future browser adds.
            return .dangerous
        }
    }

    // MARK: - CSS

    /// CSS cannot execute in a modern engine, but it can still *fetch* — a font, a
    /// background image, an `@import` — and a fetch is how a document phones home with
    /// the fact that it was opened. Anything that reaches outward is removed; everything
    /// that only describes appearance stays, because appearance is part of what is under
    /// review.
    static func scrubCSS(_ css: String, report: inout SanitizationReport) -> String {
        var out = css
        // Legacy execution vectors. Long dead in WebKit, removed anyway: they cost one
        // line each, and "no longer exploitable" is a claim about today's engine.
        for pattern in ["expression(", "-moz-binding", "behavior:", "javascript:"] {
            if out.range(of: pattern, options: .caseInsensitive) != nil {
                report.dangerousURLs += 1
                out = out.replacingOccurrences(of: pattern, with: "/*removed*/",
                                               options: .caseInsensitive)
            }
        }
        if out.range(of: "@import", options: .caseInsensitive) != nil {
            report.remoteResources += 1
            out = out.replacingOccurrences(of: "@import", with: "/*removed*/",
                                           options: .caseInsensitive)
        }
        // `url(` pointing anywhere but at an inline data image. Rewritten to `none` rather
        // than deleted so the declaration stays syntactically whole — a half-removed value
        // can take the rest of the rule with it.
        out = rewriteCSSURLs(out, report: &report)
        return out
    }

    private static func rewriteCSSURLs(_ css: String, report: inout SanitizationReport) -> String {
        var out = ""
        var rest = Substring(css)
        while let open = rest.range(of: "url(", options: .caseInsensitive) {
            out += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest[open.upperBound...].firstIndex(of: ")") else {
                // Unclosed: the rest of the stylesheet is unparseable, so it goes.
                report.remoteResources += 1
                return out
            }
            let inner = rest[open.upperBound..<close]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n'\""))
            if classifyURL(inner) == .safe, inner.lowercased().hasPrefix("data:") {
                out += "url(\"\(inner)\")"
            } else {
                report.remoteResources += 1
                out += "none"
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    // MARK: - The tokenizer

    private struct Attribute { var name: String; var value: String? }

    private struct Tag {
        var name: String
        var attributes: [Attribute]
        var isClosing: Bool
        var isSelfClosing: Bool
        /// Index just past the `>`.
        var end: Int
    }

    /// Reads one tag starting at `start` (which must be a `<`), or nil when what follows
    /// is not a tag name at all.
    private static func readTag(_ s: [Character], from start: Int) -> Tag? {
        var i = start + 1
        guard i < s.count else { return nil }
        var isClosing = false
        if s[i] == "/" { isClosing = true; i += 1 }
        guard i < s.count, s[i].isLetter else { return nil }

        var name = ""
        while i < s.count, s[i].isLetter || s[i].isNumber || s[i] == "-" || s[i] == ":" {
            name.append(s[i]); i += 1
        }
        name = name.lowercased()

        var attributes: [Attribute] = []
        var selfClosing = false
        while i < s.count {
            while i < s.count, s[i].isWhitespace { i += 1 }
            guard i < s.count else { break }
            if s[i] == ">" { i += 1; break }
            if s[i] == "/" {
                selfClosing = true
                i += 1
                continue
            }
            var key = ""
            while i < s.count, !s[i].isWhitespace, s[i] != "=", s[i] != ">", s[i] != "/" {
                key.append(s[i]); i += 1
            }
            if key.isEmpty { i += 1; continue }   // stray punctuation; do not spin
            while i < s.count, s[i].isWhitespace { i += 1 }
            var value: String?
            if i < s.count, s[i] == "=" {
                i += 1
                while i < s.count, s[i].isWhitespace { i += 1 }
                if i < s.count, s[i] == "\"" || s[i] == "'" {
                    let quote = s[i]
                    i += 1
                    var v = ""
                    while i < s.count, s[i] != quote { v.append(s[i]); i += 1 }
                    if i < s.count { i += 1 }
                    value = v
                } else {
                    var v = ""
                    while i < s.count, !s[i].isWhitespace, s[i] != ">" { v.append(s[i]); i += 1 }
                    value = v
                }
            }
            attributes.append(Attribute(name: key, value: value))
        }
        return Tag(name: name, attributes: attributes, isClosing: isClosing,
                   isSelfClosing: selfClosing, end: i)
    }

    /// Everything up to `</name`, and the index just past that closing tag. For the two
    /// elements whose contents a browser reads as text rather than as markup.
    private static func rawText(_ s: [Character], from start: Int,
                                closing name: String) -> (String, Int) {
        let needle = Array("</" + name)
        var i = start
        var text = ""
        while i < s.count {
            if s[i] == "<", matches(s, at: i, String(needle)) {
                let end = skip(s, from: i, until: ">") ?? s.count
                return (text, end)
            }
            text.append(s[i]); i += 1
        }
        return (text, s.count)
    }

    private static func matches(_ s: [Character], at index: Int, _ needle: String) -> Bool {
        let chars = Array(needle.lowercased())
        guard index + chars.count <= s.count else { return false }
        for (offset, c) in chars.enumerated() where Character(s[index + offset].lowercased()) != c {
            return false
        }
        return true
    }

    /// The index just past the next occurrence of `needle`, or nil if there isn't one.
    private static func skip(_ s: [Character], from start: Int, until needle: String) -> Int? {
        let chars = Array(needle)
        var i = start
        while i + chars.count <= s.count {
            if matches(s, at: i, needle) { return i + chars.count }
            i += 1
        }
        return nil
    }

    // MARK: - Text helpers

    /// Enough entity decoding to make a URL check honest. Not a general decoder and not
    /// meant to be: its only job is to stop `&#106;avascript:` from reading as safe.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<amp]
            let after = rest.index(after: amp)
            guard let semi = rest[after...].firstIndex(of: ";"),
                  rest.distance(from: after, to: semi) <= 8 else {
                out.append("&")
                rest = rest[after...]
                continue
            }
            let entity = String(rest[after..<semi])
            out += named(entity) ?? "&\(entity);"
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }

    private static func named(_ entity: String) -> String? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp": return " "
        default:
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                guard let value = UInt32(entity.dropFirst(2), radix: 16),
                      let scalar = Unicode.Scalar(value) else { return nil }
                return String(Character(scalar))
            }
            if entity.hasPrefix("#") {
                guard let value = UInt32(entity.dropFirst()),
                      let scalar = Unicode.Scalar(value) else { return nil }
                return String(Character(scalar))
            }
            return nil
        }
    }

    /// Everything that could end an attribute value early, or start a tag inside one.
    static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "\"", with: "&quot;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
    }
}
