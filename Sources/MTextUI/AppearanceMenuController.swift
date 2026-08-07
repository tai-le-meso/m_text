import AppKit
import MTextCore

/// Drives View ▸ Appearance: dispatches the three commands and ticks the current one.
///
/// A menu *delegate* rather than `validateMenuItem`, for the same reason `SyntaxMenuController`
/// is: the check mark has to reflect state the editor doesn't own, and recomputing it as the
/// menu opens is simpler than keeping every item in step from the other end.
public final class AppearanceMenuController: NSObject, NSMenuDelegate {

    public static let shared = AppearanceMenuController()

    public func menuNeedsUpdate(_ menu: NSMenu) {
        let current = AppearanceController.shared.preference
        for item in menu.items {
            guard let raw = item.representedObject as? String else { continue }
            item.state = (raw == current.rawValue) ? .on : .off
        }
    }

    @objc public func selectAppearance(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String
        else { return }
        AppearanceController.shared.setPreference(AppearancePreference(settingValue: raw))
    }
}
