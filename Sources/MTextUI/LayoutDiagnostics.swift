import AppKit

/// Opt-in view/layer tree dumps for rendering bugs — built to chase "the pane renders
/// blank when an overlay opens" (KNOWLEDGE.md), kept as a standing tool because that class
/// of bug is miserable to diagnose without it. Off unless `MTEXT_LAYOUT_DEBUG` is set, so
/// it costs nothing in a normal build:
///
///     MTEXT_LAYOUT_DEBUG=1 make debug
///
/// **There are deliberately no call sites.** Add a `LayoutDiagnostics.dump(...)` /
/// `.dumpLayerTree(...)` / `.trace(...)` where you need one, and take it out again — the
/// alternative is dump calls scattered through render paths, which is what this file
/// exists to avoid.
///
/// Deliberately free functions over `NSView` rather than methods on
/// `MainWindowController`: everything interesting is reachable from `window.contentView`
/// downwards, and keeping it out of that file avoids needing access to its (file-scoped)
/// `private` members.
enum LayoutDiagnostics {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MTEXT_LAYOUT_DEBUG"] != nil
    }

    /// One-line trace, same env gate as everything else here. `@autoclosure` so the
    /// (usually string-interpolating) argument costs nothing when diagnostics are off,
    /// which matters when tracing from `draw(_:)` or another per-frame path.
    static func trace(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        print("[layout] \(message())")
    }

    /// Walks `root`'s **view** subtree, logging the three things that can each
    /// independently explain "draw() ran and produced pixels, but the screen stayed
    /// blank":
    ///
    /// 1. **Auto Layout ambiguity** (`hasAmbiguousLayout`) — the frame you logged is
    ///    one of several the engine considered legal, so it can change under you.
    /// 2. **View geometry** — frame/bounds/hidden/alpha.
    /// 3. **Layer geometry and contents** — a layer-backed view whose `draw(_:)` ran but
    ///    whose `layer.contents` is nil never handed its bitmap to the compositor; a
    ///    layer whose frame is zero (or whose `superlayer` is nil) is drawing into
    ///    something that will never be shown, no matter how correct the *view* frame is.
    ///
    /// Note from the blank-pane hunt: a clean report from this proves less than it looks
    /// like it does. Every one of these read correct in *both* the working and broken
    /// states, which is what eventually made `dumpLayerTree` necessary.
    static func dump(_ root: NSView, label: String) {
        guard isEnabled else { return }
        print("=== LayoutDiagnostics: \(label) ===")
        print("root.hasAmbiguousLayout: \(root.hasAmbiguousLayout)")
        walk(root, depth: 0)
        print("=== end \(label) ===")
    }

    /// Walks the **CALayer** tree directly, rather than each view's own layer in view-tree
    /// order. A view-driven dump structurally cannot show layers AppKit inserts that
    /// belong to no view, nor a layer hierarchy whose parent/child links have drifted
    /// from the view hierarchy. A `masksToBounds` layer with the wrong bounds, a stray
    /// `mask`, a zeroed `contentsRect`, or a non-identity transform anywhere between the
    /// window's root layer and a leaf would clip correct content to nothing while every
    /// view-level property still read perfectly correct.
    ///
    /// One caution learned the hard way: `ContentLayer` sublayers with no delegate are
    /// **normal** — that is simply where AppKit stores a view's drawn contents, and they
    /// appear under ordinary labels and text fields too. They are not evidence of
    /// responsive-scrolling tiling or of anything being wrong.
    static func dumpLayerTree(_ root: NSView, label: String) {
        guard isEnabled, let layer = root.layer else { return }
        print("=== LayerTree: \(label) ===")
        walkLayer(layer, depth: 0)
        print("=== end LayerTree \(label) ===")
    }

    private static func walkLayer(_ layer: CALayer, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        var parts: [String] = []
        parts.append("frame=\(short(layer.frame))")
        parts.append("bounds=\(short(layer.bounds))")
        if layer.isHidden { parts.append("HIDDEN") }
        if layer.opacity != 1.0 { parts.append("opacity=\(layer.opacity)") }
        if layer.masksToBounds { parts.append("masksToBounds") }
        if layer.mask != nil { parts.append("HAS-MASK\(short(layer.mask!.frame))") }
        if !CATransform3DIsIdentity(layer.transform) { parts.append("TRANSFORM") }
        if !CATransform3DIsIdentity(layer.sublayerTransform) { parts.append("SUBLAYER-TRANSFORM") }
        let cr = layer.contentsRect
        if cr != CGRect(x: 0, y: 0, width: 1, height: 1) {
            parts.append("contentsRect=(\(cr.origin.x),\(cr.origin.y),\(cr.width),\(cr.height))")
        }
        parts.append("scale=\(layer.contentsScale)")
        if let contents = layer.contents {
            parts.append("contents=\(String(describing: type(of: contents)))")
        } else {
            parts.append("NO-CONTENTS")
        }
        // A layer with no owning view is one AppKit inserted itself — invisible to every
        // view-tree dump taken so far, and the main reason this walk exists.
        parts.append(layer.delegate == nil ? "NO-DELEGATE(appkit-inserted?)"
                                           : "owner=\(String(describing: type(of: layer.delegate!)))")

        print("\(indent)\(String(describing: type(of: layer))) \(parts.joined(separator: " "))")
        for sublayer in layer.sublayers ?? [] {
            walkLayer(sublayer, depth: depth + 1)
        }
    }

    private static func walk(_ view: NSView, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        let name = String(describing: type(of: view))

        var parts: [String] = []
        parts.append("frame=\(short(view.frame))")
        parts.append("bounds=\(short(view.bounds))")
        if view.isHidden { parts.append("HIDDEN") }
        if view.isHiddenOrHasHiddenAncestor { parts.append("HIDDEN-ANCESTOR") }
        if view.alphaValue != 1.0 { parts.append("alpha=\(view.alphaValue)") }
        if view.hasAmbiguousLayout { parts.append("AMBIGUOUS") }
        if view.window == nil { parts.append("NO-WINDOW") }

        // The layer half — the whole point of this dump. `wantsLayer` says the view
        // asked for a layer; `layer` being non-nil says it got one; `layer.contents`
        // being non-nil says drawing actually landed somewhere the compositor reads.
        if let layer = view.layer {
            parts.append("layer=\(short(layer.frame))")
            if layer.bounds.size != view.bounds.size {
                parts.append("LAYER-SIZE-MISMATCH(\(short(layer.bounds)))")
            }
            if layer.superlayer == nil { parts.append("NO-SUPERLAYER") }
            if layer.isHidden { parts.append("LAYER-HIDDEN") }
            if layer.opacity != 1.0 { parts.append("layerOpacity=\(layer.opacity)") }
            parts.append(layer.contents == nil ? "NO-CONTENTS" : "has-contents")
            if layer.masksToBounds { parts.append("masksToBounds") }
        } else {
            parts.append(view.wantsLayer ? "WANTS-LAYER-BUT-NIL" : "no-layer")
        }

        print("\(indent)\(name) \(parts.joined(separator: " "))")

        for subview in view.subviews {
            walk(subview, depth: depth + 1)
        }
    }

    private static func short(_ rect: NSRect) -> String {
        func f(_ value: CGFloat) -> String { String(format: "%.0f", value) }
        return "(\(f(rect.origin.x)),\(f(rect.origin.y)),\(f(rect.width)),\(f(rect.height)))"
    }
}
