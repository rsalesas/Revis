import Foundation

/// What colour the document believes its page is, and whether that is a dark one.
///
/// **Why this exists.** Revis honoured a document's foreground and overrode its
/// background, and the two decisions lived far enough apart that nobody noticed they
/// disagreed. `#rv-sheet` is an ANCESTOR of the document, so its opaque white paint is
/// something the document has no way to reach: a `body { background: … }` in the guest's
/// stylesheet could only ever tint the desk in the strip around the sheet, never the paper
/// its own text lands on. For a document designed light that is invisible — both are
/// white. For one designed dark it is fatal: the author's near-white ink, faithfully
/// applied, on our white paper.
///
/// `review.css` already states the rule this broke — "a document under review is a
/// document as it will be read, and re-tinting it would mean marking up something nobody
/// else will ever see". The white sheet was doing exactly that to a dark document. So the
/// answer is not to override the text as well; it is to stop overriding the background.
///
/// The value is read here and handed to the shell verbatim. It is NOT resolved: this
/// document's canvas is `var(--canvas)` → `var(--brand-primary-900)` → `oklch(…)`, and
/// following that chain in Swift means writing a custom-property resolver and an oklch
/// converter to answer a question WebKit answers for free. The page computes it and
/// reports back; `isDark` below is given the resolved `rgb(…)` and only decides what it
/// means.
enum PageBackground {

    /// The page-level `background` a stylesheet declares, or nil if it declares none worth
    /// honouring.
    ///
    /// Only TOP-LEVEL rules count. A `body { background: … }` inside `@media
    /// (prefers-color-scheme: dark)` is deliberately ignored, because the web view is
    /// pinned to a light appearance so the guest resolves its light palette — that rule is
    /// not what the page renders, and taking it would paint the sheet a colour the text on
    /// it was never chosen against.
    ///
    /// Later wins, which is source order rather than specificity. Predictable, and right
    /// for the overwhelmingly common shape: one `body` rule, or a `:root`/`html` pair.
    static func declared(in css: String) -> String? {
        var found: String?
        for rule in topLevelRules(css) where isPageSelector(rule.selector) {
            if let value = background(in: rule.body) { found = value }
        }
        return found.flatMap(honourable)
    }

    /// Whether paper of this colour needs the chrome's dark variant.
    ///
    /// Takes a resolved `rgb()`/`rgba()` string — what `getComputedStyle` reports, and the
    /// only form the page ever sends. Nil for anything unparseable, so an unrecognised
    /// answer leaves the paper light rather than guessing at it.
    ///
    /// The threshold is WCAG relative luminance at 0.18, which is the point where white
    /// text starts to beat black text on the same ground. That is exactly the question
    /// being asked: not "is this a dark colour" as a matter of taste, but "do the washes
    /// and rules in `review.css` need to be light-on-dark".
    static func isDark(_ cssColor: String) -> Bool? {
        guard let (r, g, b, a) = components(cssColor) else { return nil }
        // A transparent sheet shows the desk, not the document. Treat it as no answer.
        guard a > 0.5 else { return nil }
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance < 0.18
    }

    // MARK: - Reading the stylesheet

    struct Rule { let selector: String; let body: String }

    /// Split a stylesheet into its top-level rules, skipping at-rule blocks whole.
    ///
    /// Brace and quote aware, because a `{` inside a string or a data URI is not the start
    /// of anything. Not a CSS parser and not trying to be — it answers one question, and
    /// anything it cannot read confidently it declines to answer at all.
    static func topLevelRules(_ css: String) -> [Rule] {
        var rules: [Rule] = []
        var selector = ""
        var body = ""
        var depth = 0
        var quote: Character?
        var skippingAtRule = false

        for character in css {
            if let q = quote {
                if depth == 0 { selector.append(character) } else { body.append(character) }
                if character == q { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                if depth == 0 { selector.append(character) } else { body.append(character) }
                continue
            }

            switch character {
            case "{":
                depth += 1
                if depth == 1 {
                    skippingAtRule = selector.trimmingCharacters(in: .whitespacesAndNewlines)
                        .hasPrefix("@")
                    body = ""
                } else if !skippingAtRule {
                    body.append(character)
                }
            case "}":
                depth -= 1
                if depth == 0 {
                    if !skippingAtRule {
                        rules.append(Rule(selector: selector, body: body))
                    }
                    selector = ""
                    body = ""
                    skippingAtRule = false
                } else if depth > 0, !skippingAtRule {
                    body.append(character)
                } else if depth < 0 {
                    // Unbalanced. The rest cannot be trusted, so nothing more is read.
                    return rules
                }
            default:
                if depth == 0 { selector.append(character) } else if !skippingAtRule {
                    body.append(character)
                }
            }
        }
        return rules
    }

    /// Whether a selector list names the page itself.
    ///
    /// Exact matches only. `body.dark` or `body > main` describe a narrower thing than
    /// "the page", and a stylesheet that paints the page conditionally is one whose
    /// condition we have not evaluated.
    private static func isPageSelector(_ selector: String) -> Bool {
        for part in selector.split(separator: ",") {
            let one = part.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if one == "html" || one == "body" || one == ":root" || one == "html body" {
                return true
            }
        }
        return false
    }

    /// The last `background` or `background-color` in a declaration block.
    ///
    /// Split on `;` at paren depth zero, so a `url("data:image/svg+xml;…")` keeps the
    /// semicolon that is part of its own value rather than being cut in half by it.
    private static func background(in body: String) -> String? {
        var found: String?
        for declaration in declarations(body) {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let property = declaration[..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard property == "background" || property == "background-color" else { continue }
            var value = declaration[declaration.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let bang = value.range(of: "!important", options: .caseInsensitive) {
                value = String(value[..<bang.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            found = value
        }
        return found
    }

    private static func declarations(_ body: String) -> [String] {
        var out: [String] = []
        var current = ""
        var parens = 0
        var quote: Character?
        for character in body {
            if let q = quote {
                current.append(character)
                if character == q { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character; current.append(character)
            case "(": parens += 1; current.append(character)
            case ")": parens = max(0, parens - 1); current.append(character)
            case ";" where parens == 0: out.append(current); current = ""
            default: current.append(character)
            }
        }
        out.append(current)
        return out
    }

    /// Whether a declared value is one worth painting the sheet with.
    ///
    /// The keywords below all mean "show what is behind me", and what is behind the sheet
    /// is the desk — which the document does not get to paint. Anything carrying a brace,
    /// an at-rule or a stray semicolon is refused outright: the value is emitted into a
    /// rule of ours, and a value that can close that rule can write a new one.
    /// Internal rather than private so the refusals can be tested directly. Constructing
    /// a stylesheet that reaches each of them through `declared` is possible but reads as a
    /// puzzle; the guard is the thing under test.
    static func honourable(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 400 else { return nil }
        let keyword = trimmed.lowercased()
        let passThrough = ["transparent", "none", "inherit", "initial",
                           "unset", "revert", "revert-layer", "currentcolor"]
        guard !passThrough.contains(keyword) else { return nil }
        guard !trimmed.contains(where: { "{}@<>".contains($0) }) else { return nil }
        // Balanced, and no semicolon left loose outside a function.
        var parens = 0
        for character in trimmed {
            if character == "(" { parens += 1 }
            if character == ")" { parens -= 1; if parens < 0 { return nil } }
            if character == ";", parens == 0 { return nil }
        }
        guard parens == 0 else { return nil }
        return trimmed
    }

    // MARK: - Reading a computed colour

    /// `rgb(r, g, b)` / `rgba(r, g, b, a)` as 0…1 components. Nil for anything else —
    /// including the modern space-separated form, which `getComputedStyle` does not
    /// currently produce for these and which would be a guess if it did.
    static func components(_ cssColor: String) -> (Double, Double, Double, Double)? {
        let text = cssColor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.hasPrefix("rgb"), let open = text.firstIndex(of: "("),
              let close = text.lastIndex(of: ")") else { return nil }
        let parts = text[text.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2])
        else { return nil }
        let alpha = parts.count > 3 ? (Double(parts[3]) ?? 1) : 1
        return (r / 255, g / 255, b / 255, alpha)
    }
}
