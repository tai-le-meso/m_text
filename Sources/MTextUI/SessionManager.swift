import AppKit
import MTextCore

/// App-level glue for session persistence (T84) and hot exit (T85): captures every
/// window into a `SessionState`, writes it (plus hot-exit buffer files for dirty
/// tabs) through `SessionStore`, and rebuilds the windows on the next launch.
///
/// Owned by the app delegate, which is also what knows the live window list — passed
/// in as a closure rather than retained, so this class needs no lifecycle coupling to
/// the delegate beyond it.
///
/// Inherits `NSObject` because the selector-based `NotificationCenter` observation
/// below requires an Objective-C-representable observer (`@objc` members only exist
/// on NSObject-derived classes).
public final class SessionManager: NSObject {

    /// Posted by `MainWindowController.refreshChrome()` whenever anything session-
    /// relevant may have changed. High-frequency by design (every keystroke posts);
    /// the observer below debounces to one disk write per quiet period.
    public static let stateDidChange = Notification.Name("MText.SessionManager.stateDidChange")

    private let store: SessionStore
    private let windows: () -> [MainWindowController]
    private var debounceTimer: Timer?

    public init(store: SessionStore = SessionStore(),
                windows: @escaping () -> [MainWindowController]) {
        self.store = store
        self.windows = windows
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(stateDidChangeNotification),
                                               name: SessionManager.stateDidChange,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        debounceTimer?.invalidate()
    }

    // MARK: - Save

    /// Debounced crash protection: a burst of changes writes one snapshot a few
    /// seconds after it quiets down, so even a crash or force-quit loses at most a
    /// few seconds of session state (the documents themselves are only ever written
    /// by explicit saves and by `saveNow` stashing dirty buffers).
    @objc private func stateDidChangeNotification() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.saveNow()
        }
    }

    /// Captures and writes the whole session synchronously — called from the debounce
    /// above and, critically, from `applicationShouldTerminate`, where it's the entire
    /// hot-exit mechanism: stash everything, then quit with no prompts.
    public func saveNow() {
        debounceTimer?.invalidate()
        var bufferIndex = 0
        var keptBuffers: Set<String> = []
        let windowStates = windows().compactMap { controller -> SessionWindow? in
            guard controller.window != nil else { return nil }
            return controller.captureSessionWindow { text in
                guard let name = try? self.store.writeBuffer(text, index: bufferIndex) else {
                    return nil
                }
                bufferIndex += 1
                keptBuffers.insert(name)
                return name
            }
        }
        try? store.save(SessionState(windows: windowStates))
        // Buffers from tabs that were saved or closed since the last snapshot are now
        // unreferenced; without this they'd accumulate forever.
        store.pruneBuffers(keeping: keptBuffers)
    }

    // MARK: - Restore

    /// Rebuilds every window from the last session. nil when there is no session (or
    /// an empty one) — the caller opens its default blank window instead. (Exact
    /// z-order across multiple windows isn't recorded; they reappear in capture order,
    /// with whichever was shown last frontmost.)
    public func restoreWindows() -> [MainWindowController]? {
        guard let state = store.load(), !state.windows.isEmpty else { return nil }
        var controllers: [MainWindowController] = []
        for windowState in state.windows {
            let controller = MainWindowController()
            controller.restoreSessionWindow(windowState, store: store)
            controller.showWindow(nil)
            controllers.append(controller)
        }
        return controllers
    }
}
