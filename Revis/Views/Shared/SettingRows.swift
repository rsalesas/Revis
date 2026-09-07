import SwiftUI

/// Rows for a column of settings: label at the leading edge, control at the trailing one.
///
/// Deliberately the same shapes as Vaelora's `InspectorControls`, down to the sizes. These
/// are two halves of one workflow and a reviewer moves between them; a switch that sits in
/// a different place in each is the kind of difference nobody can name and everybody feels.
///
/// The alignment is the whole point. A plain `Toggle("Tables", isOn:)` puts its switch
/// immediately after its own label, so a column of them has the controls at a dozen
/// different offsets — ragged down the right-hand side, and impossible to run an eye down
/// to find the one that is on.

/// A small "?" after a label. Click reveals a popover explaining the control.
///
/// Quiet at rest so a column of them does not clutter, brighter on hover, accent while its
/// popover is open. The row's own label is repeated as the popover's title, because once a
/// row has its control on the right the mark can sit a long way from the words it explains.
struct HelpMark: View {
    let title: String
    let text: String
    @State private var shown = false
    @State private var hovering = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(shown ? AnyShapeStyle(Theme.accent)
                                       : AnyShapeStyle(hovering ? Color.secondary
                                                       : Color(nsColor: .tertiaryLabelColor)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .motion(.hover, value: hovering)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 228, alignment: .leading)
            .padding(12)
        }
    }
}

/// Label and its help mark, tight together, for the leading edge of a row.
private struct RowLabel: View {
    let title: String
    var help: String?

    var body: some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 12))
            if let help { HelpMark(title: title, text: help) }
        }
    }
}

/// A labelled switch: label pinned left, a small switch at the trailing edge.
/// `.disabled(_:)` on this view reaches the switch.
struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool
    var help: String? = nil

    var body: some View {
        HStack {
            RowLabel(title: title, help: help)
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(minHeight: 24)
    }
}

/// A labelled row with something other than a switch on the right.
struct SettingRow<Content: View>: View {
    let title: String
    var help: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            RowLabel(title: title, help: help)
            Spacer(minLength: 12)
            content
        }
        .frame(minHeight: 24)
    }
}
