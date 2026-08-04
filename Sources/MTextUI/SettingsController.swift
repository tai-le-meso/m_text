import AppKit
import MTextCore

/// App-wide owner of the settings store (T86).
///
/// Mirrors `SyntaxMenuController.shared`: one store for the whole process, watching one
/// directory, broadcasting one notification — rather than a store per window each with
/// its own file-descriptor watch on the same folder. Windows observe
/// `settingsDidChange` and re-apply to their own tabs.
public final class SettingsController {

    public static let shared = SettingsController()

    public let store = SettingsStore()

    /// Posted on the main queue after any settings file in the user directory changes.
    public static let settingsDidChange = Notification.Name("m_text.settingsDidChange")

    private init() {
        store.onChange = {
            NotificationCenter.default.post(name: SettingsController.settingsDidChange, object: nil)
        }
        store.startWatching()
    }
}
