import SwiftUI
import WebKit

/// The document under review.
///
/// **Why the runtime lives in its own content world.** Everything the app puts into the
/// page — the stamping, the anchor maths, the message bridge — is injected into
/// `WKContentWorld.world(name: "revis")`, not into the page's own world. Three things
/// follow, and each one closes a hole the others do not:
///
/// - The page's Content Security Policy can be `script-src 'none'`, because a *user
///   script* is not subject to it. So the document is denied JavaScript outright while
///   ours still runs. That is not achievable with an inline `<script>`.
/// - A script that somehow survived the sanitizer could not see `window.rvCaptureSelection`
///   or `window.webkit.messageHandlers.revis`: they do not exist in its world. It cannot
///   fake an anchor, and it cannot post a message pretending to be the reviewer.
/// - Conversely, nothing the page defines can shadow what the runtime relies on.
///
/// Around that sit the layers that assume none of it worked: the sanitizer that ran before
/// a byte reached WebKit, the navigation delegate below that cancels every navigation, and
/// a release build with no network entitlement.
struct DocumentWebView: NSViewRepresentable {
    /// The complete page. Loaded once; everything after is pushed in place.
    let html: String
    /// Annotations to draw, as the wire shape the runtime understands.
    var annotations: String
    /// Which mark is current — an annotation's id, or the draft's.
    var currentMark: String
    var tool: ReviewTool

    /// Bumped to ask for the current selection. The answer arrives through `onAnchor`,
    /// since reading the DOM is a round trip.
    var captureToken: Int
    /// The zoom to apply; zero asks the page to work out what fits.
    var requestedZoom: Double
    var zoomToken: Int
    /// Bumped to scroll to `currentMark`.
    var revealToken: Int
    var revealBlock: Int?
    var revealBlockToken: Int

    var onReady: ((Int, [OutlineItem]) -> Void)?
    var onSelectionChanged: ((Bool) -> Void)?
    var onPick: ((String) -> Void)?
    var onAnchor: ((Anchor?) -> Void)?
    /// The page reporting the zoom it settled on, and what "fit" currently means.
    var onZoom: ((Double) -> Void)?
    var onFit: ((Double) -> Void)?
    /// A region drag finished. It carries a complete anchor, so there is nothing to ask
    /// for afterwards.
    var onRegion: ((Anchor) -> Void)?

    /// One name for the world, the message handler and the script — they have to agree,
    /// and three string literals that have to agree is three chances to be wrong.
    static let worldName = "revis"

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let world = WKContentWorld.world(name: Self.worldName)
        let controller = WKUserContentController()
        controller.add(context.coordinator, contentWorld: world, name: Self.worldName)
        controller.addUserScript(WKUserScript(
            source: DocumentShell.bundleString(named: "review", ext: "js"),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // The document is untrusted, and nothing about reviewing it involves storing
        // anything. A non-persistent store means no cookies, no local storage, and nothing
        // left behind for the next document to read.
        configuration.websiteDataStore = .nonPersistent()

        let webView = ReviewWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.setValue(false, forKey: "drawsBackground")

        context.coordinator.webView = webView
        context.coordinator.world = world
        context.coordinator.adopt(self)

        if !html.isEmpty {
            // No base URL. The document then has no origin to resolve anything against, so
            // even a reference the sanitizer let through has nowhere to resolve it to.
            webView.loadHTMLString(html, baseURL: nil)
            context.coordinator.loaded = true
            context.coordinator.lastHTML = html
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let c = context.coordinator
        c.adopt(self)

        if !c.loaded || c.lastHTML != html {
            guard !html.isEmpty else { return }
            c.loaded = true
            c.lastHTML = html
            c.hasStamped = false
            webView.loadHTMLString(html, baseURL: nil)
            return
        }
        // Nothing is pushed until the runtime has stamped the document: a call that
        // arrives first lands on a page with no blocks in it and silently draws nothing.
        guard c.hasStamped else { return }

        if c.lastTool != tool {
            c.lastTool = tool
            c.run("window.rvSetTool && window.rvSetTool(\(jsQuoted(tool.rawValue)));")
        }
        // Which mark is current goes BEFORE the list, and in the same script: a mark is
        // built already knowing whether it is the chosen one, so pushed after it would be
        // drawn plain for the frame between the two calls.
        if c.lastAnnotations != annotations || c.lastCurrent != currentMark {
            c.lastAnnotations = annotations
            c.lastCurrent = currentMark
            c.run("window.rvSelect && window.rvSelect(\(jsQuoted(currentMark)));"
                + "window.rvSetAnnotations && window.rvSetAnnotations(\(jsQuoted(annotations)));")
        }
        if c.lastZoomToken != zoomToken {
            c.lastZoomToken = zoomToken
            c.pendingZoom = requestedZoom
            c.run("window.rvSetZoom && window.rvSetZoom(\(requestedZoom));")
        }
        if c.lastCaptureToken != captureToken {
            c.lastCaptureToken = captureToken
            let report = onAnchor
            c.run("window.rvCaptureSelection ? window.rvCaptureSelection() : null") { value in
                report?(Anchor.decode(value as? String))
            }
        }
        if c.lastRevealToken != revealToken {
            c.lastRevealToken = revealToken
            c.run("window.rvScrollTo && window.rvScrollTo(\(jsQuoted(currentMark)));")
        }
        if c.lastRevealBlockToken != revealBlockToken, let block = revealBlock {
            c.lastRevealBlockToken = revealBlockToken
            c.run("window.rvScrollToBlock && window.rvScrollToBlock(\(block));")
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        var world: WKContentWorld = .page
        var loaded = false
        var hasStamped = false
        var lastHTML = ""
        var lastAnnotations = ""
        var lastCurrent = ""
        var lastTool: ReviewTool?
        var lastCaptureToken = 0
        var lastZoomToken = 0
        var pendingZoom: Double = 0
        var lastRevealToken = 0
        var lastRevealBlockToken = 0

        /// Pending state to re-apply once the runtime reports in. A document is stamped
        /// after it loads, and a review being reopened already has its annotations — they
        /// have to be pushed at that moment or the page would come up blank until
        /// something else changed.
        var pendingAnnotations = ""
        var pendingCurrent = ""
        var pendingTool: ReviewTool = .select

        var onZoom: ((Double) -> Void)?
        var onFit: ((Double) -> Void)?

        var onReady: ((Int, [OutlineItem]) -> Void)?
        var onSelectionChanged: ((Bool) -> Void)?
        var onPick: ((String) -> Void)?
        var onRegion: ((Anchor) -> Void)?

        func adopt(_ view: DocumentWebView) {
            onReady = view.onReady
            onSelectionChanged = view.onSelectionChanged
            onPick = view.onPick
            onRegion = view.onRegion
            onZoom = view.onZoom
            onFit = view.onFit
            pendingZoom = view.requestedZoom
            pendingAnnotations = view.annotations
            pendingCurrent = view.currentMark
            pendingTool = view.tool
        }

        /// Evaluate a script in the review's own content world.
        ///
        /// The failure is REPORTED, not swallowed. It was swallowed — `try? result.get()`
        /// — and that cost an afternoon: a script that failed to parse silently did none
        /// of the several things it carried, so the margin had no marks, the zoom never
        /// fitted, and the page looked like code that had simply not been written. A
        /// pushed script failing is not a rare edge; it is the normal consequence of
        /// building JavaScript out of interpolated Swift, and it has to be audible.
        func run(_ script: String, then: (@MainActor (Any?) -> Void)? = nil) {
            webView?.evaluateJavaScript(script, in: nil, in: world) { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let value):
                        then?(value)
                    case .failure(let error):
                        // Head and length, not the whole thing: one of these scripts
                        // carries every margin symbol as a data URL and is a quarter of a
                        // megabyte, which is not a log line.
                        PageLog.write("script failed (\(script.count) chars):"
                            + " \(error.localizedDescription) — \(script.prefix(90))")
                        then?(nil)
                    }
                }
            }
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let kind = dict["kind"] as? String else { return }
            switch kind {
            case "ready":
                hasStamped = true
                PageLog.write("ready \(dict["blocks"] ?? "?") blocks")
                let blocks = (dict["blocks"] as? Int) ?? 0
                onReady?(blocks, OutlineItem.decode(dict["outline"]))
                // Everything the model already knew about, now that there is a document
                // to draw it on.
                //
                // One call each, deliberately. They were a single script, and when it
                // failed it took all five with it — no marks, no zoom, no tool — which
                // presents as an app that does not work rather than as one call that did
                // not parse. Five calls cost five round trips into a web view that is
                // already loaded; that is nothing next to being unable to tell which of
                // five things broke.
                run("window.rvSetColours && window.rvSetColours(\(AnnotationPalette.json()),"
                    + " \(AnnotationSymbols.json()));")
                run("window.rvSetZoom && window.rvSetZoom(\(pendingZoom));")
                run("window.rvSetTool && window.rvSetTool(\(jsQuoted(pendingTool.rawValue)));")
                run("window.rvSelect && window.rvSelect(\(jsQuoted(pendingCurrent)));")
                run("window.rvSetAnnotations && window.rvSetAnnotations("
                    + "\(jsQuoted(pendingAnnotations)));")
                lastAnnotations = pendingAnnotations
                lastCurrent = pendingCurrent
                lastTool = pendingTool
            case "selection":
                onSelectionChanged?((dict["has"] as? Bool) ?? false)
            case "pick":
                if let id = dict["id"] as? String { onPick?(id) }
            case "zoom":
                if let value = dict["value"] as? Double { onZoom?(value) }
            case "fit":
                if let value = dict["value"] as? Double { onFit?(value) }
            case "debug":
                PageLog.write(String(describing: dict))
            case "error":
                // The page cannot report a problem any other way: there is no console to
                // open on a WKWebView inside an app, so a drawing failure would otherwise
                // present as "the margin is empty" with nothing to go on.
                let stage = (dict["stage"] as? String) ?? "?"
                let message = (dict["message"] as? String) ?? "?"
                PageLog.write("error while painting \(stage): \(message)")
            case "region":
                if let raw = dict["anchor"], let anchor = Anchor.decode(json: raw) {
                    onRegion?(anchor)
                }
            default:
                break
            }
        }

        /// Only the initial in-memory load is allowed. Every link, every redirect, every
        /// form post is cancelled — including ones the sanitizer decided were harmless,
        /// because "harmless to render" and "worth navigating to" are different questions.
        nonisolated func webView(_ webView: WKWebView,
                                 decidePolicyFor navigationAction: WKNavigationAction,
                                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }

        /// A document is not allowed to open windows, ask questions, or upload files. All
        /// three are refused rather than left to WebKit's defaults.
        nonisolated func webView(_ webView: WKWebView,
                                 createWebViewWith configuration: WKWebViewConfiguration,
                                 for navigationAction: WKNavigationAction,
                                 windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}

/// A `WKWebView` that reads as a document you can select from but not act on.
///
/// It takes first responder — ⌘C has to reach the web view to copy anything — and keeps
/// the context menu, filtered. A menu offering Reload and Back on a document that
/// navigates nowhere is nonsense; Copy and Look Up are exactly what a right-click on
/// selected text should offer.
private final class ReviewWebView: WKWebView {
    /// Matched on WebKit's own identifiers rather than on titles, which are localized.
    /// Deliberately a denylist: the identifiers are not declared in any public header, so
    /// if one is renamed this degrades to WebKit's default menu — merely untidy — where an
    /// allowlist would degrade to no menu at all.
    private static let suppressed: Set<String> = [
        "WKMenuItemIdentifierGoBack",
        "WKMenuItemIdentifierGoForward",
        "WKMenuItemIdentifierReload",
        "WKMenuItemIdentifierOpenLink",
        "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierCopyLink",
        "WKMenuItemIdentifierCopyLinkWithHighlight",
        "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierOpenImageInNewWindow",
        "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierOpenFrameInNewWindow",
        "WKMenuItemIdentifierInspectElement",
        "WKMenuItemIdentifierPaste",
        "WKMenuItemIdentifierAddHighlightToNewQuickNote",
        "WKMenuItemIdentifierAddHighlightToCurrentQuickNote",
    ]

    override func mouseDown(with event: NSEvent) {
        if let window, window.firstResponder !== self { window.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items.reversed()
        where Self.suppressed.contains(item.identifier?.rawValue ?? "") {
            menu.removeItem(item)
        }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        while let first = menu.items.first, first.isSeparatorItem { menu.removeItem(first) }
        if menu.items.isEmpty { menu.cancelTracking() }
    }
}

/// A Swift string as a JavaScript string literal, safe to interpolate into evaluated JS.
///
/// Through `JSONEncoder` rather than by escaping quotes by hand: it is the same problem
/// as escaping HTML, and hand-rolled escaping is how a document's own text ends up
/// terminating the string it was being passed inside.
func jsQuoted(_ value: String) -> String {
    (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

extension Anchor {
    /// An anchor as the runtime returns it: a JSON string, or the literal `null` when
    /// there was nothing selected.
    static func decode(_ json: String?) -> Anchor? {
        guard let json, json != "null", let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Anchor.self, from: data)
    }

    /// An anchor that arrived as part of a posted message, so already deserialised into
    /// Foundation objects.
    static func decode(json object: Any) -> Anchor? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Anchor.self, from: data)
    }
}

extension OutlineItem {
    static func decode(_ object: Any?) -> [OutlineItem] {
        guard let object, let data = try? JSONSerialization.data(withJSONObject: object),
              let items = try? JSONDecoder().decode([OutlineItem].self, from: data)
        else { return [] }
        return items
    }
}


/// A file the page can be made to talk into.
///
/// A `WKWebView` inside an app has no console anybody can open, and `NSLog` from a document
/// window did not reach `log show` reliably enough to debug against. A file always works,
/// and "the margin is empty and nothing said why" is a bad enough afternoon to be worth one.
/// Off unless `REVIS_PAGE_LOG` names a path, so a shipped build writes nothing.
enum PageLog {
    private static let url: URL? = ProcessInfo.processInfo.environment["REVIS_PAGE_LOG"]
        .map { URL(fileURLWithPath: $0) }

    /// Whether anything is listening. The page's own diagnostics are switched on to match,
    /// so a shipped build neither writes nor computes them.
    static var isOn: Bool { url != nil }

    static func write(_ message: String) {
        guard let url else { return }
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
