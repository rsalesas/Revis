import SwiftUI
import AppKit

/// Opens each new window at the size the last one was left at.
///
/// `.defaultSize` only covers the first run: after that, somebody who has widened a review
/// window to read a wide table should not have to widen the next one too. A zero-sized,
/// invisible representable is how a SwiftUI scene gets at its `NSWindow` — there is no
/// scene-level API for this, and the alternative is an `NSWindowDelegate` bolted onto an
/// app that otherwise has none.
struct WindowSizeMemory: NSViewRepresentable {
    private static let key = "app.revis.lastWindowSize"

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not attached during `makeNSView`, so this waits a turn for it.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.observe(window)
            guard let stored = UserDefaults.standard.string(forKey: Self.key) else { return }
            let size = NSSizeFromString(stored)
            guard size.width > 200, size.height > 200 else { return }
            // Anchored at the top-left, which is where macOS's own cascade puts a window:
            // setting the frame from the origin would walk each new window down the screen.
            var frame = window.frame
            frame.origin.y += frame.height - size.height
            frame.size = size
            window.setFrame(frame, display: false)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        private var token: Any?

        func observe(_ window: NSWindow) {
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { note in
                    guard let window = note.object as? NSWindow else { return }
                    UserDefaults.standard.set(NSStringFromSize(window.frame.size),
                                              forKey: WindowSizeMemory.key)
                }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
