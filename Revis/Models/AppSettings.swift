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

    /// Whether a document is shown with its own stylesheet.
    ///
    /// True by default and meant to stay that way: you are reviewing what was sent, and a
    /// viewer with opinions about typography is showing you a different document. The
    /// switch exists because generated HTML is sometimes genuinely hard to read — a
    /// condensed face, colour on colour, a measure the width of the window — and being
    /// unable to read it is being unable to review it.
    @Published var useDocumentStyle: Bool { didSet { save(.useDocumentStyle, useDocumentStyle) } }

    /// The zoom a newly opened document starts at. Zero means "fit the window", which is
    /// what most people want and what no fixed percentage can be.
    @Published var defaultZoom: Double { didSet { save(.defaultZoom, defaultZoom) } }

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
        case useDocumentStyle, defaultZoom
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
        useDocumentStyle = defaults.object(forKey: Key.useDocumentStyle.rawValue) as? Bool ?? true
        defaultZoom = defaults.object(forKey: Key.defaultZoom.rawValue) as? Double ?? 0
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
