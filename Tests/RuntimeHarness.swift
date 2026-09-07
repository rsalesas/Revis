import Testing
import Foundation
import WebKit
@testable import Revis

/// The runtime, running.
///
/// **Why a real `WKWebView` and not a stub.** Every previous attempt to reason about
/// review.js from the Swift side has checked that it *exists* — `BridgeTests` proves the
/// entry points are defined and the variables declared, and that has caught real faults.
/// What none of it can see is what the code DOES, and this session alone found five things
/// wrong in there: offsets measured against the wrong thing, a parse failure swallowed
/// whole, marks placed by a divided coordinate, a hit test that answered for the wrong
/// annotation, a zoom that could not be reasoned about. Every one presented as "the app
/// looks unfinished" rather than as an error, because a page with no console cannot
/// complain.
///
/// jsdom would be the cheap alternative and it would be worse than nothing here: it has no
/// layout, so `getBoundingClientRect` returns zeros, and half of this runtime is geometry.
/// The same engine that ships is the only place these answers mean anything.
/// A value crossing a continuation. `[String: Any]` and `Any?` are what WebKit hands back
/// and neither is `Sendable`; everything here is on the main actor, so the box is a promise
/// about isolation the compiler cannot see rather than one being broken.
private struct Boxed<Value>: @unchecked Sendable {
    let value: Value
}

@MainActor
final class RuntimeHarness: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    private let webView: WKWebView
    private let world = WKContentWorld.world(name: "revis-tests")
    /// Messages the page has posted, in order — `ready`, `error`, `pick`, and the rest.
    private(set) var posts: [(name: String, payload: [String: Any])] = []

    init(html: String) {
        let controller = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        // A real size, because everything this runtime does is measured. At zero the layout
        // is degenerate and every rect comes back empty — which reads as the runtime being
        // broken rather than as the window having no width.
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 800),
                            configuration: configuration)
        super.init()

        controller.add(self, contentWorld: world, name: "revis")
        controller.addUserScript(WKUserScript(
            source: DocumentShell.bundleString(named: "review", ext: "js"),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        webView.navigationDelegate = self
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// A harness over the sample document, prepared and shelled exactly as the app does it.
    static func spec(_ name: String = "data-retention-spec.html") -> RuntimeHarness {
        let prepared = DocumentPrep.prepare(html: ReviewFixtures.html(name), baseURL: nil)
        return RuntimeHarness(html: DocumentShell.page(
            for: prepared,
            chromeCSS: DocumentShell.bundleString(named: "review", ext: "css")))
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // `post` merges the payload into one object under `kind` — see review.js. Read it
        // the way the app reads it, or the harness is testing a bridge nobody uses.
        guard let body = message.body as? [String: Any],
              let name = body["kind"] as? String else { return }
        posts.append((name: name, payload: body))
    }

    /// Wait for the page to post something, or give up.
    ///
    /// The deadline is not politeness. A continuation that never resumes hangs the whole
    /// suite with no output and no failing test — Swift Testing has no timeout of its own,
    /// so one page that does not load takes every other test down silently with it. That
    /// happened on the first run of this harness, and cost more to diagnose than the bug
    /// it was hiding.
    @discardableResult
    func wait(for name: String, seconds: Double = 10) async -> [String: Any] {
        if let already = posts.last(where: { $0.name == name }) { return already.payload }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let arrived = posts.last(where: { $0.name == name }) { return arrived.payload }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("the page never posted \"\(name)\"")
        return [:]
    }

    /// Evaluate in the runtime's own world, so it can see `window.rv*` and the module's
    /// state — which is the whole point: from the page's world none of it exists, which is
    /// the isolation the app relies on.
    @discardableResult
    func eval(_ script: String) async throws -> Any? {
        let boxed: Boxed<Any?> = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: Boxed(value: value))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        return boxed.value
    }

    func int(_ script: String) async throws -> Int {
        (try await eval(script) as? NSNumber)?.intValue ?? -1
    }

    func string(_ script: String) async throws -> String {
        (try await eval(script) as? String) ?? ""
    }

    /// Let the page settle.
    ///
    /// A plain wait on this side, not an awaited `requestAnimationFrame` on that one.
    /// `evaluateJavaScript` cannot return a promise at all — it fails with "a result of an
    /// unsupported type" — and `callAsyncJavaScript`, which can, never called back here and
    /// hung the entire suite with no output and no failing test. Two frames is under
    /// thirty-five milliseconds; eighty is not worth being clever about.
    func settle(_ seconds: Double = 0.08) async throws {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Long enough for the sheet's own width transition to finish — `rvHold` eases rather
    /// than steps, so a measurement taken a frame later reads the width it started from.
    func settleAfterTransition() async throws {
        try await settle(Motion.panel.duration + 0.15)
    }

    /// Push a list of annotations the way `ReviewModel.annotationsJSON` does.
    func setAnnotations(_ wire: [[String: Any]]) async throws {
        let data = try JSONSerialization.data(withJSONObject: wire)
        let json = String(decoding: data, as: UTF8.self)
        try await eval("window.rvSetAnnotations(\(jsQuoted(json)));")
        try await settle()
    }
}
