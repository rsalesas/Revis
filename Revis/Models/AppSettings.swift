import Foundation
import Combine
import AppKit

/// App-wide preferences, backed by `UserDefaults`.
///
/// Deliberately short. Most of what Vaelora keeps here is about producing a PDF — page
/// size, margins, stylesheets — and none of it applies to a viewer that renders a document
/// exactly as it was sent. What is left is who the reviewer is, what a new mark defaults
/// to, and the shape the window was left in.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    /// Who annotations are signed by.
    ///
    /// Defaults to the account's full name rather than to an empty box: an unsigned review
    /// is less useful to whoever receives it, and asking somebody to type their own name
    /// into a preference before they can start is a poor first run.
    @Published var reviewerName: String { didSet { save(.reviewerName, reviewerName) } }

    /// What a new annotation starts as. `change` because it is far and away the commonest
    /// thing a review says, and a default that is usually right costs one click less than
    /// a default that is neutral.
    @Published var defaultIntent: Intent { didSet { save(.defaultIntent, defaultIntent.rawValue) } }

    /// Which tool a window opens in.
    @Published var defaultTool: ReviewTool { didSet { save(.defaultTool, defaultTool.rawValue) } }

    /// Whether the export writes the JSON sidecar beside the Markdown.
    @Published var exportSidecar: Bool { didSet { save(.exportSidecar, exportSidecar) } }

    // Window shape. Deliberately NOT @Published — these are read only when a window is
    // created, and publishing here would re-render every open window whenever one of them
    // opened a pane.
    var lastAnnotationsVisible: Bool {
        get { defaults.object(forKey: Key.annotationsVisible.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.annotationsVisible.rawValue) }
    }

    /// Defaults to closed, unlike the annotations pane: the inspector holds an outline and
    /// a provenance report, which are things you go looking for rather than things you
    /// work in.
    var lastInspectorVisible: Bool {
        get { defaults.object(forKey: Key.inspectorVisible.rawValue) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.inspectorVisible.rawValue) }
    }

    private enum Key: String {
        case reviewerName, defaultIntent, defaultTool, exportSidecar
        case annotationsVisible, inspectorVisible
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedName = defaults.string(forKey: Key.reviewerName.rawValue)
        reviewerName = storedName ?? Self.systemName
        defaultIntent = Intent(rawValue: defaults.string(forKey: Key.defaultIntent.rawValue) ?? "")
            ?? .change
        defaultTool = ReviewTool(rawValue: defaults.string(forKey: Key.defaultTool.rawValue) ?? "")
            ?? .select
        exportSidecar = defaults.object(forKey: Key.exportSidecar.rawValue) as? Bool ?? true
    }

    private func save(_ key: Key, _ value: Any) {
        defaults.set(value, forKey: key.rawValue)
    }

    /// The account's full name, trimmed to something that reads as a byline. Falls back to
    /// the short user name, and then to nothing — an unsigned review still works.
    static var systemName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        if !full.isEmpty { return full }
        let short = NSUserName().trimmingCharacters(in: .whitespaces)
        return short
    }
}
