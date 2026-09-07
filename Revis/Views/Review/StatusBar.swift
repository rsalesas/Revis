import SwiftUI

/// The strip along the bottom of a review window.
///
/// Two jobs, and they are the two things a reviewer keeps glancing at while reading:
/// *how big is this* and *what am I actually looking at*. The zoom controls are on the
/// right because that is where a document viewer puts them; the provenance is on the left
/// because it is a statement about the document rather than a control.
///
/// Deliberately quiet — small type, secondary colour, one hairline. A status bar that
/// competes with the page is a status bar that gets switched off.
struct StatusBar: View {
    @ObservedObject var model: ReviewModel

    var body: some View {
        HStack(spacing: 10) {
            provenance
            Spacer(minLength: 12)
            styleToggle
            Divider().frame(height: 12)
            zoomControls
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    // MARK: - Left

    /// What the document is, and what had to be taken out of it.
    ///
    /// On screen the whole time rather than only in the inspector, because the app rewrote
    /// the file before showing it and the reviewer should not have to go looking for that.
    @ViewBuilder private var provenance: some View {
        HStack(spacing: 6) {
            if model.isPreparing {
                Text("Preparing…")
            } else {
                Text(count(model.blockCount, "block"))
                    .monospacedDigit()
                // Both of these are a summary of something the inspector says in full, so
                // both go there. A count of what was taken out of the document, with no way
                // to find out WHAT, is the app saying "I changed this and I am not telling
                // you" — and the panel that answers it was two clicks away behind a pane
                // that is closed by default.
                if !model.prepared.report.isClean {
                    Divider().frame(height: 10)
                    provenanceButton("\(removedCount) removed", symbol: "checkmark.shield",
                                     help: removedSummary)
                }
                if !model.prepared.missingImages.isEmpty {
                    Divider().frame(height: 10)
                    provenanceButton(
                        count(model.prepared.missingImages.count, "image") + " missing",
                        symbol: "photo.badge.exclamationmark",
                        help: model.prepared.missingImages.prefix(6).joined(separator: "\n"))
                }
            }
        }
        // 11pt medium, the size Vaelora's status bar uses. It was 10.5 regular, which is
        // smaller than anything else in the window and was being read as a mistake — and
        // it is not decoration: this line is the app telling you it rewrote your document
        // before showing it.
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// "1 image", "3 images". A status bar that says "1 images missing" reads as
    /// something nobody looked at, which undermines the one job this strip has — being
    /// believed about what was done to the document.
    private func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    /// A count that takes you to the thing it counts.
    ///
    /// Opens the inspector if it is shut — through `setPane`, like every other route to a
    /// pane, so the document gives the room up before the pane takes it rather than being
    /// clipped for the length of the animation. See the note in CLAUDE.md.
    private func provenanceButton(_ title: String, symbol: String, help: String) -> some View {
        Button {
            withMotion(.panel) {
                model.inspectorTab = .document
                model.setPane(.outline, open: true)
            }
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help + "\n\nClick to see the full report.")
    }

    private var removedCount: Int {
        model.prepared.report.lines.reduce(0) { $0 + $1.count }
    }

    private var removedSummary: String {
        "Removed before the document was shown:\n"
            + model.prepared.report.lines.map { "\($0.count) × \($0.label)" }
                .joined(separator: "\n")
    }

    // MARK: - Right

    /// One control, two states. A separate "reading style" button and "document style"
    /// button would be two ways of saying one thing, and the reviewer would have to read
    /// both to work out which was on.
    @ViewBuilder private var styleToggle: some View {
        // Only where the document has a stylesheet to be faithful to — see
        // `ReviewModel.hasDocumentStyle`. A control that switches between one appearance
        // and the same appearance is worse than no control.
        if model.hasDocumentStyle {
            styleButton
        }
    }

    private var styleButton: some View {
        Button {
            withMotion(.reveal) { model.useDocumentStyle.toggle() }
        } label: {
            Label(model.useDocumentStyle ? "Document style" : "Reading style",
                  systemImage: model.useDocumentStyle ? "doc.richtext" : "textformat")
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.useDocumentStyle ? AnyShapeStyle(.secondary)
                                                : AnyShapeStyle(Theme.accent))
        .help(model.useDocumentStyle
              ? "Showing the document with its own stylesheet, as it was sent."
                + " Click to switch to a plain reading style."
              : "Showing a plain reading style — this is NOT how the document looks."
                + " Click to go back to the document's own stylesheet.")
        .disabled(model.isEmpty)
    }

    /// Built the way Vaelora's is, because Vaelora's works and this one did not.
    ///
    /// The difference is one line: the glyph gets a frame and a content shape. Without
    /// them a `Button` wrapping a nine-point `Image` is the size of the ink — the minus
    /// measured eight points by two — so the control was there, drawn, enabled, and
    /// essentially impossible to hit. It read as a button that did not work.
    private var zoomControls: some View {
        HStack(spacing: 0) {
            zoomButton("minus", "Zoom out") { model.zoomOut() }
                .disabled(model.zoom <= 0.36)
            Menu {
                Button("Fit Width") { model.zoomToFit() }
                Divider()
                ForEach(ReviewModel.zoomPresets, id: \.self) { stop in
                    Button("\(Int(stop * 100))%") { model.setZoom(stop) }
                }
            } label: {
                Text(model.zoomLabel)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .rollingNumber(model.rollingZoom)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()          // hug the text rather than expanding to fill the bar
            .frame(width: 46)     // …but hold a slot wider than "100%", so nothing shifts
            .help("Zoom")
            zoomButton("plus", "Zoom in") { model.zoomIn() }
                .disabled(model.zoom >= 2.99)
            // Fit is in the menu too, as it is in Vaelora — but it is also the way BACK,
            // and here that matters more than it does there. Zooming past the fit makes
            // the sheet wider than the window, and the control that undoes it should not
            // be inside a menu you have to know is there.
            zoomButton("arrow.left.and.right", "Fit the page to the window") {
                model.zoomToFit()
            }
            .disabled(model.isFitted)
        }
        .background(Color.primary.opacity(0.06), in: Capsule())
        .disabled(model.isEmpty)
    }

    private func zoomButton(_ symbol: String, _ help: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                // The whole point. A frame the pointer can find, and a content shape so
                // the transparent parts of it are hittable too.
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

}
