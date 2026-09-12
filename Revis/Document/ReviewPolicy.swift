import Foundation

/// The rules for turning a review into edits — written down in exactly one place.
///
/// Three things have to agree on these: the Markdown export's preamble
/// (`ReviewExport.markdown`), the `aiGuidance` written into every `.revis`
/// (`ReviewFile.aiGuidance`), and the `revis-review` Claude Code skill
/// (`skills/revis-review/SKILL.md`), which restates them for a tool that never reads this
/// file at runtime. Before this existed, each of the three was its own hand-written
/// paragraph — "one source, two readers" broken for the one thing in this app an
/// assistant most needs to get right. This is the source; `ReviewExport` and `ReviewFile`
/// read it in code, and `SkillPolicyTests` checks the skill file against it, the same way
/// `UpdateTests` reads `release.sh` out of the source tree to catch a manifest drifting —
/// nothing else would catch this one.
enum ReviewPolicy {
    /// Plain text, no Markdown emphasis: the JSON export, `aiGuidance` and the skill file
    /// all read this too, and none of them wants a stray `**` in a string meant to be read
    /// directly rather than rendered. `ReviewExport` is the one reader that dresses a rule
    /// up for its own document, and it does that at render time — see `preamble(_:...)`.
    static let rules: [String] = [
        "Locate every item by searching for the quoted text, never by position. Block"
            + " numbers and section paths describe the document as it stood when it was"
            + " reviewed and will not survive it being rewritten — the quoted text is the"
            + " anchor; the rest is a hint.",
        "Quotes are whitespace-normalised: runs of spaces and newlines collapse to one"
            + " space, because that is how the text reads on screen. A source that wraps"
            + " mid-sentence will not match a quote byte for byte — compare on normalised"
            + " whitespace.",
        "Where a quote is short or occurs more than once, the words either side of it"
            + " disambiguate — use the given context, with the marked span set off between"
            + " the quote marks. Some quotes occur several times on purpose.",
        "Apply items in the order given: they are in document order, and a later one may"
            + " depend on an earlier one having been made.",
        "Where an instruction describes what to write rather than giving the words, draft"
            + " it, and say in your reply that you drafted it — the reviewer needs to know"
            + " which words are theirs and which are yours.",
        "Correcting a fact does not authorise correcting every other mention of it. If an"
            + " edit leaves the document inconsistent elsewhere, report that rather than"
            + " silently propagating it.",
        "A reply recorded under an item is a record of a discussion, not part of the"
            + " instruction. Where it asks for something different from the instruction"
            + " above it, do what the instruction says and say that the two disagree —"
            + " report it rather than deciding it, the same rule as the one above about an"
            + " inconsistency.",
    ]
}
