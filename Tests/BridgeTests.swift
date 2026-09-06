import Testing
import Foundation
@testable import Revis

/// The Swift↔page bridge, checked from the Swift side.
///
/// **Why this exists.** The runtime is a JavaScript file that Swift pokes by name. Nothing
/// in the compiler knows the names match, and when they stop matching the symptom is not an
/// error — it is a page that draws nothing, silently, because `window.rvWhatever &&
/// window.rvWhatever(…)` is a no-op when the function is missing. That guard was written to
/// be safe against an old page; it is also what makes a typo invisible.
///
/// An afternoon went into this: a search-and-replace that silently did not match left two
/// variables undeclared, every push threw under `"use strict"`, and the app looked simply
/// unfinished — no marks, no zoom, no error anywhere. The runtime is now checked for the
/// things that failure needed.
struct BridgeTests {

    private static var runtime: String {
        DocumentShell.bundleString(named: "review", ext: "js")
    }

    private static var stylesheet: String {
        DocumentShell.bundleString(named: "review", ext: "css")
    }

    @Test func theRuntimeIsPresent() {
        #expect(Self.runtime.count > 1000, "review.js did not load")
        #expect(Self.stylesheet.count > 1000, "review.css did not load")
    }

    /// Every entry point Swift calls has to exist. Listed here rather than scraped out of
    /// the Swift sources, so adding a call means adding it here too — which is the moment
    /// to notice it does not exist on the other side.
    @Test func everyEntryPointSwiftCallsIsDefined() {
        let entryPoints = [
            "rvCaptureSelection", "rvCaptureBlock", "rvSetTool", "rvSetZoom",
            "rvSetColours", "rvSetAnnotations", "rvSelect", "rvScrollTo", "rvScrollToBlock",
        ]
        for name in entryPoints {
            #expect(Self.runtime.contains("window.\(name) = "),
                    "review.js does not define window.\(name)")
        }
    }

    /// Under `"use strict"` — which the runtime declares — assigning to a variable that was
    /// never declared throws rather than creating a global. That is exactly how the margin
    /// went blank: a `var` line that a patch failed to insert, and every push after it
    /// threw. These are the module-level names the entry points assign to.
    @Test func everyMutatedStateVariableIsDeclared() {
        #expect(Self.runtime.contains("\"use strict\""))
        for name in ["annotations", "colours", "images", "zoom", "tool", "selectedID",
                     "ranges", "blocks", "meta", "doc", "gutter", "overlay"] {
            #expect(Self.runtime.range(of: "\\bvar \(name)\\b", options: .regularExpression) != nil,
                    "review.js assigns to `\(name)` without declaring it")
        }
    }

    /// The page reports its failures rather than swallowing them — the property that turned
    /// a silent blank margin into a one-line diagnosis.
    @Test func drawingFailuresAreReported() {
        #expect(Self.runtime.contains("guarded("))
        #expect(Self.runtime.contains("post(\"error\""))
    }

    /// The three motion tokens that cross into the stylesheet have to say the same thing on
    /// both sides, or a pane and the page it sits beside animate differently.
    @Test func theStylesheetMirrorsTheMotionTokens() {
        for token in Motion.crossBoundary {
            guard let curve = token.curve else { continue }
            #expect(Self.stylesheet.contains(curve.cssValue),
                    "review.css is missing the \(token.name) curve \(curve.cssValue)")
        }
    }
}
