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
        .frame(height: 26)
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
                if !model.prepared.report.isClean {
                    Divider().frame(height: 10)
                    Label("\(removedCount) removed", systemImage: "checkmark.shield")
                        .labelStyle(.titleAndIcon)
                        .help(removedSummary)
                }
                if !model.prepared.missingImages.isEmpty {
                    Divider().frame(height: 10)
                    Label(count(model.prepared.missingImages.count, "image") + " missing",
                          systemImage: "photo.badge.exclamationmark")
                        .help(model.prepared.missingImages.prefix(6).joined(separator: "\n"))
                }
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// "1 image", "3 images". A status bar that says "1 images missing" reads as
    /// something nobody looked at, which undermines the one job this strip has — being
    /// believed about what was done to the document.
    private func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
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
    private var styleToggle: some View {
        Button {
            withMotion(.reveal) { model.useDocumentStyle.toggle() }
        } label: {
            Label(model.useDocumentStyle ? "Document style" : "Reading style",
                  systemImage: model.useDocumentStyle ? "doc.richtext" : "textformat")
                .font(.system(size: 10.5))
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

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button { model.zoomOut() } label: { Image(systemName: "minus") }
                .disabled(model.zoom <= 0.36)
            // A menu on the percentage, so the common sizes are one click away and the
            // buttons do not have to be walked ten times to get from fit to 200%.
            Menu {
                Button("Fit Width") { model.zoomToFit() }
                Divider()
                ForEach(ReviewModel.zoomStops, id: \.self) { stop in
                    Button(percentage(stop)) { model.setZoom(stop) }
                }
            } label: {
                Text(percentage(model.zoom))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .rollingNumber(model.zoom)
                    .frame(width: 38)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { model.zoomIn() } label: { Image(systemName: "plus") }
                .disabled(model.zoom >= 2.99)
            Button { model.zoomToFit() } label: {
                Image(systemName: "arrow.left.and.right")
            }
            .help("Fit the page to the window")
            // Not hidden when it would do nothing — a control that vanishes as you reach
            // the state it produces reads as the window losing a button.
            .disabled(model.isFitted)
        }
        .font(.system(size: 9, weight: .semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(model.isEmpty)
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
