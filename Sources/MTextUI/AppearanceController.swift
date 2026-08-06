import AppKit
import MTextCore

/// Applies the app's light/dark appearance and hands every editor the matching brand scheme.
///
/// Three states, not a boolean: `.system` follows the OS and keeps following it, which is a
/// different thing from picking `.light` and happening to match.
///
/// **Why this re-applies colours rather than relying on dynamic `NSColor`s.** The usual
/// AppKit advice is to resolve colours through `NSColor(name:dynamicProvider:)` so the system
/// re-resolves them per appearance. That does not work in this editor: `LayoutCache` shapes
/// each line into a `CTLine` with `kCTForegroundColorAttributeName` set to a **concrete**
/// `CGColor`, so an already-shaped line keeps whatever colour it was built with no matter what
/// the appearance does afterwards. Anything cached would silently keep the old palette while
/// freshly shaped lines used the new one — a half-recoloured buffer.
///
/// So the switch is explicit: set the appearance, rebuild the scheme, and let
/// `setColorScheme` invalidate the layout cache. That is also why this observes the
/// *effective* appearance rather than only the preference — flipping the OS theme while the
/// app is open in `.system` mode has to repaint too, and that is the case that silently
/// breaks if you only handle the menu command.
public final class AppearanceController {

    public static let shared = AppearanceController()

    /// Posted after the appearance has been applied, so windows can restyle their own chrome.
    public static let didChangeNotification = Notification.Name("m_text.appearanceDidChange")

    private static let defaultsKey = "MTextAppearance"

    public private(set) var preference: AppearancePreference

    /// Editors are registered weakly: a tab closing must not keep its editor alive, and a
    /// stale entry must not be handed a scheme.
    private final class WeakEditor {
        weak var editor: EditorView?
        init(_ editor: EditorView) { self.editor = editor }
    }
    private var editors: [WeakEditor] = []
    private var observation: NSKeyValueObservation?

    private init() {
        preference = AppearancePreference(
            settingValue: UserDefaults.standard.string(forKey: AppearanceController.defaultsKey))
    }

    /// Applies the stored preference and starts watching the effective appearance. Call once,
    /// as early as the app has an `NSApplication`.
    public func start() {
        apply(preference, persist: false)
        // Fires when the OS theme changes under `.system`, which no menu command would catch.
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            // The notification arrives *while* AppKit is updating; re-resolving on the next
            // turn keeps `isDarkNow` from reading the appearance that is on its way out.
            DispatchQueue.main.async { self?.refreshForEffectiveAppearance() }
        }
    }

    public func register(_ editor: EditorView) {
        editors.removeAll { $0.editor == nil }
        editors.append(WeakEditor(editor))
        editor.setColorScheme(currentScheme())
    }

    /// The scheme for whatever appearance is in force right now.
    public func currentScheme() -> ColorScheme { .brand(BrandTheme.theme(dark: isDarkNow)) }

    public var isDarkNow: Bool {
        switch preference {
        case .light: return false
        case .dark: return true
        case .system:
            return NSApp.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    public func setPreference(_ new: AppearancePreference) {
        apply(new, persist: true)
    }

    private func apply(_ new: AppearancePreference, persist: Bool) {
        preference = new
        if persist {
            UserDefaults.standard.set(new.rawValue, forKey: AppearanceController.defaultsKey)
        }
        // nil means "follow the system" — the whole reason this is not a boolean.
        switch new {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        restyleEditors()
    }

    private func refreshForEffectiveAppearance() {
        guard preference == .system else { return }
        restyleEditors()
    }

    private func restyleEditors() {
        let scheme = currentScheme()
        editors.removeAll { $0.editor == nil }
        for entry in editors { entry.editor?.setColorScheme(scheme) }
        NotificationCenter.default.post(name: AppearanceController.didChangeNotification, object: nil)
    }

    // MARK: - Smoke-test hooks

    /// Editors currently registered, for `MTEXT_SMOKE_TEST`.
    public var smokeTestRegisteredEditorCount: Int {
        editors.removeAll { $0.editor == nil }
        return editors.count
    }
}
