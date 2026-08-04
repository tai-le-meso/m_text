import AppKit
import MTextCore

// T86 — applying resolved settings to a view, and recording this view's own overrides.
//
// The editor is deliberately a *sink* here: it takes an already-resolved
// `EditorSettings` and never reads a file or knows what layers exist.
// `MainWindowController` owns the stack (default → user → syntax → project → view) and
// hands down the answer, which keeps every layer-precedence decision in one place.
extension EditorView {

    /// Applies resolved settings. Each property has a `didSet` that invalidates only what
    /// it needs to, and assigning an unchanged value to a `didSet` still fires it, so
    /// every field is guarded by an equality check — a settings reload that changed one
    /// key must not force a full relayout and repaint of everything else.
    public func applySettings(_ settings: EditorSettings) {
        let resolvedFont = EditorView.resolveFont(face: settings.fontFace, size: settings.fontSize)
        if font != resolvedFont { font = resolvedFont }
        if showsGutter != settings.lineNumbers { showsGutter = settings.lineNumbers }
        if showsInvisibles != settings.drawWhiteSpace { showsInvisibles = settings.drawWhiteSpace }
        if highlightsCurrentLine != settings.highlightLine { highlightsCurrentLine = settings.highlightLine }
        if rulerColumns != settings.rulers { rulerColumns = settings.rulers }
        if indentUnit != settings.indentUnit { indentUnit = settings.indentUnit }
        if autoCompleteEnabled != settings.autoComplete { autoCompleteEnabled = settings.autoComplete }
        // `settings.colorScheme` is intentionally not applied: colour schemes are loaded
        // and installed by name (`PackageManager`) but never indexed by name, so there is
        // nothing to look one up in — every editor uses `ColorScheme.builtInDefault()`.
        // The setting parses and round-trips so files stay portable; wiring it up needs a
        // scheme registry, which is a Phase 3 gap rather than part of T86.
    }

    /// Falls back to the system monospaced font when `font_face` is absent *or* names a
    /// font that isn't installed — a typo in a settings file should cost you your chosen
    /// typeface, not leave the editor unable to lay out text.
    static func resolveFont(face: String?, size: Double) -> NSFont {
        let points = CGFloat(max(4, min(size, 288)))
        if let face, let named = NSFont(name: face, size: points) { return named }
        return .monospacedSystemFont(ofSize: points, weight: .regular)
    }

    /// Records a view-level override and asks the controller to re-resolve. Used by the
    /// View menu toggles, which are per-view by definition.
    func setViewOverride(_ key: String, _ value: SettingValue) {
        viewOverrides[key] = value
        onViewOverridesChanged?()
    }

    /// This view's layer for the settings stack.
    var viewLayer: SettingsLayer {
        SettingsLayer(name: "View", values: viewOverrides)
    }
}
