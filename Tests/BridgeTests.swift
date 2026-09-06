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

/// The per-window model's own rules.
@MainActor
struct ReviewModelTests {

    private func model(defaultIntent: Intent) -> ReviewModel {
        let defaults = UserDefaults(suiteName: "app.revis.tests.\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.defaultIntent = defaultIntent
        let file = ReviewFile(
            source: SourceInfo(name: "s", path: nil, capturedAt: .reviewStamp, digest: ""),
            document: .empty)
        return ReviewModel(file: file, appSettings: settings)
    }

    private var anchor: Anchor {
        Anchor(blocks: [0], path: "", role: "paragraph", quote: "hello",
               prefix: "", suffix: "", start: 0, end: 5, rect: nil)
    }

    /// The preference has to reach BOTH ways of making an annotation. It reached one:
    /// a dragged region honoured it and selected text did not, because the region call
    /// site passed it in and the text one fell through to a hard-coded default.
    @Test func aNewAnnotationStartsAtThePreferredIntent() {
        for intent in Intent.allCases {
            let model = model(defaultIntent: intent)
            model.openDraft(on: anchor)
            #expect(model.draft?.intent == intent)
        }
    }

    /// Which operations stand on their own, and the rule being in ONE place.
    ///
    /// The pane's Add button and the model asked this question separately, in two
    /// different phrasings — which is how a control comes to offer something the model
    /// then refuses. They ask `Intent.needsInstruction` now, and this pins what it says.
    @Test func onlySelfContainedOperationsCanBeCommittedEmpty() {
        for intent in Intent.allCases {
            let model = model(defaultIntent: intent)
            model.openDraft(on: anchor)
            model.commitDraft()
            #expect(model.annotations.isEmpty == intent.needsInstruction,
                    "empty \(intent.rawValue) was \(intent.needsInstruction ? "accepted" : "refused")")
        }
        // "Delete this" is a complete instruction; the span says which text. "Rewrite
        // this" is not — rewrite it to say what?
        #expect(!Intent.remove.needsInstruction)
        #expect(Intent.change.needsInstruction)
        #expect(Intent.insert.needsInstruction)
        #expect(Intent.move.needsInstruction)
        #expect(Intent.question.needsInstruction)
        #expect(Intent.comment.needsInstruction)
    }

    /// The prompt is what tells the reviewer whether words are needed — it is the only
    /// thing that does, now that the hint beside the buttons is gone — and an intent that
    /// can be committed empty has to say what it means with no words in it.
    @Test func thePromptSaysWhetherWordsAreNeeded() {
        for intent in Intent.allCases {
            if intent.needsInstruction {
                #expect(!intent.prompt.hasSuffix("(optional)"),
                        "\(intent.rawValue) needs words but its prompt says otherwise")
            } else {
                #expect(intent.prompt.hasSuffix("(optional)"),
                        "\(intent.rawValue) can be empty and never says so")
                #expect(!intent.standsAlone.isEmpty,
                        "\(intent.rawValue) can be empty but the export says nothing")
            }
        }
    }

    /// Resolving keeps the annotation — a review records that a thing was dealt with, not
    /// that it never happened.
    @Test func resolvingDoesNotDelete() {
        let model = model(defaultIntent: .change)
        model.openDraft(on: anchor)
        model.draft?.note = "please"
        model.commitDraft()
        let id = try! #require(model.annotations.first?.id)
        model.resolve(id)
        #expect(model.annotations.count == 1)
        #expect(model.annotations.first?.status == .resolved)
        #expect(model.visibleAnnotations.isEmpty)   // the pane defaults to Open
    }

    /// A verdict is final, and it settles the annotation it is about.
    @Test func aVerdictIsFinalAndLocksWhatItDecided() {
        let model = model(defaultIntent: .change)
        model.openDraft(on: anchor)
        model.draft?.note = "please"
        model.commitDraft()
        let id = try! #require(model.annotations.first?.id)

        model.decide(.declined, for: id)
        #expect(model.annotations.first?.verdict == .declined)
        #expect(model.annotations.first?.verdictBy?.isEmpty == false)
        // A declined request is not outstanding work.
        #expect(!(model.annotations.first?.isActionable ?? true))
        #expect(model.openCount == 0)

        // Final: neither reversed nor overwritten. A decision you can quietly undo is not
        // on the record at all.
        model.decide(.approved, for: id)
        #expect(model.annotations.first?.verdict == .declined)

        // And what was decided is now settled — an agreement to one thing is not an
        // agreement to whatever it is later changed into.
        model.setNote("something else entirely", for: id)
        #expect(model.annotations.first?.note == "please")
        model.setIntent(.remove, for: id)
        #expect(model.annotations.first?.intent == .change)
        model.delete(id)
        #expect(model.annotations.count == 1)
        #expect(model.annotations.first?.editingRefusal(for: model.author) != nil)
    }

    /// Yours or nobody's. Rewriting another reviewer's words leaves their name on a
    /// sentence they did not write.
    @Test func anotherReviewersAnnotationIsNotYoursToChange() {
        let model = model(defaultIntent: .change)
        let mine = Annotation(author: model.author, intent: .change, note: "mine",
                              anchor: anchor)
        let theirs = Annotation(author: "Someone Else", intent: .change, note: "theirs",
                                anchor: anchor)
        let unsigned = Annotation(author: "", intent: .change, note: "unsigned",
                                  anchor: anchor)
        model.annotations = [mine, theirs, unsigned]

        #expect(model.canEdit(mine))
        #expect(!model.canEdit(theirs))
        #expect(model.canEdit(unsigned))          // nobody's name is on it

        model.setNote("changed", for: theirs.id)
        #expect(model.annotation(theirs.id)?.note == "theirs")
        model.delete(theirs.id)
        #expect(model.annotations.count == 3)

        // …but responding to it is exactly what a second reviewer is for.
        model.resolve(theirs.id)
        #expect(model.annotation(theirs.id)?.status == .resolved)
        model.decide(.approved, for: theirs.id)
        #expect(model.annotation(theirs.id)?.verdict == .approved)

        // The refusal says whose it is, so a disabled control can explain itself.
        #expect(theirs.editingRefusal(for: model.author)?.contains("Someone Else") == true)
    }

    /// Reviews written before approving became a verdict must still open.
    @Test func legacyIntentsAreReadAsComments() throws {
        for legacy in ["note", "approve"] {
            let json = Data("\"\(legacy)\"".utf8)
            #expect(try JSONDecoder().decode(Intent.self, from: json) == .comment)
        }
        #expect(try JSONDecoder().decode(Intent.self, from: Data("\"remove\"".utf8)) == .remove)
    }
}
