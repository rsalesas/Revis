import Foundation

/// What a drag on the document does.
///
/// Two, not more. The distinction that matters is whether the reviewer is pointing at
/// *words* or at *an area of the page*, because that is the distinction the anchor has to
/// record — a text selection knows its own offsets and a region has to be told what it
/// covers. Everything else people reach for on a review (a highlight, a strike-through,
/// an arrow) is one of these two with an intent attached, and is better expressed as the
/// intent than as a third tool.
enum ReviewTool: String, CaseIterable, Identifiable, Sendable {
    /// Select text. The document behaves like a document.
    case select
    /// Drag a box. Used for figures, tables, layout and whitespace — the places where the
    /// thing being commented on is not a run of words.
    case region

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .region: return "Region"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .region: return "rectangle.dashed"
        }
    }

    var help: String {
        switch self {
        case .select: return "Select text to annotate it"
        case .region: return "Drag a box over part of the page"
        }
    }
}

/// Which annotations the pane and the export are showing.
enum AnnotationFilter: String, CaseIterable, Identifiable, Sendable {
    case open, all, resolved

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open:     return "Open"
        case .all:      return "All"
        case .resolved: return "Resolved"
        }
    }

    func admits(_ annotation: Annotation) -> Bool {
        switch self {
        case .all:      return true
        case .open:     return annotation.status == .open
        case .resolved: return annotation.status == .resolved
        }
    }
}

/// The inspector's tabs.
enum InspectorTab: String, CaseIterable, Identifiable, Sendable {
    /// The document's headings, so a long spec can be navigated without scrolling.
    case outline
    /// What the document is, where it came from, and what the sanitizer took out of it.
    case document

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outline:  return "Outline"
        case .document: return "Document"
        }
    }

    var symbol: String {
        switch self {
        case .outline:  return "list.bullet.indent"
        case .document: return "doc.text"
        }
    }
}
