import Testing
import Foundation
@testable import Revis

/// `skills/revis-review/SKILL.md` is a separate file a different tool reads, and nothing
/// in the build forces it to agree with `ReviewPolicy`, which is the actual source of the
/// "how to apply a review" rules baked into every export and every `.revis`. This is the
/// check that stands in for that: it reads the skill file out of the source tree, the same
/// way `UpdateTests` reads `release.sh`, and fails if a rule changed in one place and not
/// the other.
struct SkillPolicyTests {

    /// `#filePath` rather than an environment variable, for the reason `FileFormatTests`
    /// gives for its own build directory: `xcodebuild` runs the test host as its own
    /// process and does not inherit the invoking shell's environment.
    private func skillText() throws -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("skills/revis-review/SKILL.md")
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// Whitespace-normalised — the same rule `ReviewPolicy.rules` itself states about a
    /// quote — because SKILL.md hard-wraps its numbered list at a column width the way the
    /// rest of this repository's Markdown does, and a hard-wrapped rule is still the same
    /// words.
    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test func everyPolicyRuleIsQuotedWordForWordInTheSkill() throws {
        let skill = normalized(try skillText())
        for (index, rule) in ReviewPolicy.rules.enumerated() {
            #expect(skill.contains(normalized(rule)), """
                rule \(index + 1) is not quoted verbatim in SKILL.md — update the skill's \
                "How to apply one, in order" section to match ReviewPolicy.rules
                """)
        }
    }

    /// The same rules, reachable from the artifact an assistant is actually handed — a
    /// `.revis` file, not the source tree.
    @Test func aiGuidanceQuotesEveryRuleTooAndItIsNotStoredAsANumberedList() throws {
        for rule in ReviewPolicy.rules {
            #expect(ReviewFile.aiGuidance.contains(rule))
        }
    }
}
