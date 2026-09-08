import SwiftUI
import AppKit

/// A slim notice across the top of a review window when a newer build has been published.
/// Passive by design: the daily check never interrupts with a dialog, it just surfaces
/// this, and it can be set aside for that version.
///
/// Where it can, "Update and Relaunch" installs in place (see `AppUpdater`); otherwise it
/// falls back to opening the disk image in the browser.
struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        // The animation is applied HERE rather than at the call site, and it has to be:
        // `.animation(value:)` only fires for a view that can see the value change, and
        // the review window observes `AppState`, not the checker inside it. Attached one
        // level up from the `if`, it re-runs whenever this view's own body does.
        Group {
            content
        }
        .motion(.reveal, value: checker.pendingUpdate?.version)
    }

    @ViewBuilder private var content: some View {
        if let update = checker.pendingUpdate {
            // Bar and hairline as one view, so they arrive and leave together — this
            // banner decides for itself whether it has anything to show, so the
            // transition has to live here rather than at the call site.
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Theme.accent)
                    Text("Revis \(update.version) is available")
                        .font(.system(size: 12, weight: .medium))
                    if let failure = checker.installFailure {
                        Text(failure)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .lineLimit(1)
                            .help(failure)
                    } else if let notes = update.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    // No inline progress here. The update reports itself in its own window
                    // (see `UpdateProgressWindow`), which is the only place that can show
                    // it when the install was started from the menu with no review open.
                    // Two indicators for one operation is how they drift apart.
                    if checker.isInstalling {
                        Text("Updating…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else if case .install = UpdateAlert.offer(for: checker.state) {
                        // In place, and only when we know we can finish: an archive with a
                        // checksum and a writable location. The same decision the menu
                        // makes, so the two cannot drift apart.
                        Button("Update and Relaunch") { UpdateAlert.install(with: checker) }
                            .controlSize(.small)
                    } else {
                        // Everything else keeps the manual route rather than offering a
                        // button that would fail. Labelled for what it does: next to a
                        // version number, a bare "Download" reads as "install".
                        Button("Download Disk Image…") { NSWorkspace.shared.open(update.url) }
                            .controlSize(.small)
                            .help((AppUpdater.ineligibilityReason().map { "\($0) " } ?? "")
                                  + "Drag Revis to your Applications folder to install it.")
                    }
                    Button {
                        checker.dismissCurrent()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss until the next version")
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(.thinMaterial)
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
            // Down from under the toolbar, which is where it came from. `.top` alone
            // would have it fade in place, which reads as something that was always
            // there and is only now being noticed.
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// The "an update is available" dialog.
///
/// Not an `NSAlert`, which sets its title a little below the top of the 64pt icon and
/// offers no way to change that. On a one-line "Are you sure?" nobody notices; beside three
/// paragraphs of release notes the eye has a long left edge to compare the two against, and
/// the title reads as hanging off a floating icon.
///
/// Hosted the same way `UpdateProgressWindow` is, and for the same reason: "Check for
/// Updates…" can be used with no review window open, so there is no live view to present a
/// sheet from. Run modally so the caller can just ask and get an answer.
@MainActor
enum UpdateDialog {

    /// Shows the dialog and returns the index of the button pressed. `buttons[0]` is the
    /// default (rightmost, Return); the last also answers to Escape, and is what a closed
    /// window counts as.
    static func run(title: String, body: String, buttons: [String]) -> Int {
        var choice = buttons.count - 1

        // A hosting *controller* rather than a hosting view: it sizes the window to the
        // SwiftUI content. Setting a content view and a size separately leaves the window
        // taller than the layout, and SwiftUI then centres the content in the slack.
        let controller = NSHostingController(rootView: UpdateDialogView(
            title: title, message: body, buttons: buttons,
            choose: { index in
                choice = index
                NSApp.stopModal()
            }))
        // The window has no visible titlebar, so the content should not keep clear of where
        // one would be. Told to the controller rather than the view: `.ignoresSafeArea()`
        // moves the content up but leaves the inset in the size it reports, so the window
        // keeps the height and the slack reappears under the buttons.
        controller.safeAreaRegions = []

        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = controller

        window.title = title              // what VoiceOver and the Window menu read
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // The way out is a button, so that the caller always gets a real answer.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        controller.view.layoutSubtreeIfNeeded()
        window.setContentSize(controller.view.fittingSize)
        window.center()

        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return choice
    }
}

/// Icon beside the text, buttons under it — the shape `NSAlert` uses, with the title's top
/// on the icon's top.
struct UpdateDialogView: View {
    let title: String
    let message: String
    let buttons: [String]
    let choose: (Int) -> Void

    var body: some View {
        // `.top` is the whole reason this is hand-built: the icon and the heading share an
        // edge because they are laid out to, not because a value was tuned until they
        // looked like they did.
        HStack(alignment: .top, spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    // Three buttons is the platform's "two actions and a way out": the way
                    // out goes to the left, apart from the choice being offered, so it
                    // cannot be hit by someone aiming for the one next to it.
                    if buttons.count > 2, let last = buttons.last {
                        button(last, at: buttons.count - 1)
                    }
                    Spacer()
                    // Rightmost is the default, matching the platform.
                    ForEach(Array(buttons.enumerated()).reversed(), id: \.offset) { index, label in
                        if buttons.count <= 2 || index != buttons.count - 1 {
                            button(label, at: index)
                        }
                    }
                }
                .padding(.top, 10)
            }
            .frame(width: 400, alignment: .leading)
            // A macOS app icon is drawn inside its canvas with a margin, so matching the
            // two frames leaves the title a few points above the artwork it is meant to
            // line up with. This is that margin.
            .padding(.top, 6)
        }
        .padding(20)
    }

    @ViewBuilder private func button(_ label: String, at index: Int) -> some View {
        let action = { choose(index) }
        if index == 0 {
            Button(label, action: action).keyboardShortcut(.defaultAction)
        } else if index == buttons.count - 1 {
            Button(label, action: action).keyboardShortcut(.cancelAction)
        } else {
            Button(label, action: action)
        }
    }
}

/// Feedback for an explicit "Check for Updates…" — unlike the daily check, the user asked,
/// so every outcome gets an answer.
@MainActor
enum UpdateAlert {

    /// What to offer for a given check result.
    ///
    /// A value rather than a branch inside `present`, for two reasons. The dialog is a
    /// modal, so the choice can only be tested if it is separable from showing it. And the
    /// banner asks the same question — asked separately, the two would drift, one offering
    /// the in-place install and the other quietly sending people to the disk image.
    enum Offer: Equatable {
        /// Installable in place; the download stays as a second choice.
        case install(UpdateManifest)
        case download(UpdateManifest)
        case upToDate
        case failed(String)
        case none
    }

    static func offer(for state: UpdateChecker.State,
                      canInstallInPlace: Bool = AppUpdater.canUpdateInPlace()) -> Offer {
        switch state {
        case .available(let update):
            return update.installableArchive != nil && canInstallInPlace
                ? .install(update) : .download(update)
        case .upToDate: return .upToDate
        case .failed(let why): return .failed(why)
        case .idle, .checking: return .none
        }
    }

    static func present(for checker: UpdateChecker) {
        switch offer(for: checker.state) {
        case .install(let update):
            switch UpdateDialog.run(
                title: "Revis \(update.version) is available",
                body: update.notes
                    ?? "A newer version is available. Revis can install it and relaunch.",
                buttons: ["Update and Relaunch", "Download", "Later"]) {
            case 0: install(with: checker)
            case 1: NSWorkspace.shared.open(update.url)
            default: break
            }
        case .download(let update):
            // Say what the button does. "Download" next to a version number reads as
            // "install it", and the disk image appearing instead is a surprise.
            var text = update.notes ?? "A newer version is available."
            text += "\n\n" + (AppUpdater.ineligibilityReason().map { "\($0) " } ?? "")
                + "Downloading opens the disk image — drag Revis to your Applications "
                + "folder to finish installing it."
            if UpdateDialog.run(title: "Revis \(update.version) is available", body: text,
                                buttons: ["Download Disk Image…", "Later"]) == 0 {
                NSWorkspace.shared.open(update.url)
            }
        case .upToDate:
            let alert = NSAlert()
            alert.messageText = "You're up to date"
            alert.informativeText = "Revis \(AppVersion.marketing) is the latest version."
            alert.runModal()
        case .failed(let message):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = message
            alert.runModal()
        case .none:
            break
        }
    }

    /// Start an install, from wherever it was asked for.
    ///
    /// One entry point for the banner and the menu alike, so both get the progress window
    /// and neither can quietly go without one. A failure still gets its own alert: the menu
    /// can be used with no review window open, and then there is no banner to put it in
    /// either.
    static func install(with checker: UpdateChecker) {
        UpdateProgressWindow.shared.show(checker: checker)
        Task {
            let failure = await checker.installAvailableUpdate()
            UpdateProgressWindow.shared.close()
            // Cancelling reports nothing: the user asked for it and already knows.
            guard let failure, failure != .cancelled else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install the update"
            alert.informativeText = failure.errorDescription
                ?? "The update couldn't be installed. Your copy of Revis is unchanged."
            alert.runModal()
        }
    }
}
