import Foundation

/// A dotted numeric version ("0.2.10"), compared component-wise.
///
/// String comparison is wrong here — "0.2.10" sorts *before* "0.2.9" — and this is the
/// one piece of the update check that silently does nothing when it is wrong, so it is a
/// type of its own with tests rather than an inline `<`.
///
/// Named for what it is rather than `AppVersion`, which this app already uses for the
/// running build's own numbers. Two different questions: `AppVersion.marketing` is "what
/// am I", this is "which of these two is newer".
struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]

    /// Nil for anything that is not dot-separated numbers, so a malformed manifest cannot
    /// be read as "newer".
    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(part), n >= 0 else { return nil }
            parsed.append(n)
        }
        guard !parsed.isEmpty else { return nil }
        components = parsed
    }

    /// Missing trailing components read as zero, so "0.2" == "0.2.0".
    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    var description: String { components.map(String.init).joined(separator: ".") }
}
