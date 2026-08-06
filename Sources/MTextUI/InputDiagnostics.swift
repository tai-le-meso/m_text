import AppKit
import MTextCore

/// Env-gated trace of the keyboard path — `MTEXT_INPUT_DEBUG=1 make debug`.
///
/// Exists because the `MTEXT_SMOKE_TEST` harness **cannot reproduce a key window**: a
/// process launched from a terminal is not frontmost, so macOS refuses it key status and
/// never routes real key events to it. The harness therefore injects `NSEvent`s directly,
/// which proves the editor *handles* keys but says nothing about whether the OS ever
/// *delivers* them. "Typing does nothing" lives precisely in that gap.
///
/// The trace answers, in order, the only questions that matter when keys go missing:
///
/// 1. Does the key event reach the application at all? (the local monitor)
/// 2. Is the app active, the window key, and who holds first responder?
/// 3. Does it reach `EditorView.keyDown`, or is something upstream eating it?
/// 4. Does the keymap swallow it (`.command` with no handler, or `.pendingChord`)?
/// 5. Does `insertText` run, and does the document's generation actually move?
///
/// Whichever line stops appearing is the layer that broke. Unlike `LayoutDiagnostics`,
/// this one *does* have call sites — they are all `guard isEnabled` one-liners, so the
/// feature costs a boolean check when it is off.
public enum InputDiagnostics {

    public static let isEnabled = ProcessInfo.processInfo.environment["MTEXT_INPUT_DEBUG"] != nil

    public static func log(_ message: String) {
        guard isEnabled else { return }
        print("[input] \(message)")
    }

    /// Installs an application-level key-down monitor. Logs every key the app receives
    /// *before* the responder chain gets it, so a keystroke that never reaches the editor
    /// is still visible here — that difference is the whole point.
    public static func installMonitor() {
        guard isEnabled else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        print("[input] tracing enabled — type in the window, then quit and send this log")
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
            let responder = window?.firstResponder
            log("""
                key \(String(reflecting: event.charactersIgnoringModifiers ?? "")) \
                code=\(event.keyCode) mods=\(describe(event.modifierFlags)) | \
                appActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow != nil) \
                windowIsKey=\(window?.isKeyWindow ?? false) \
                firstResponder=\(responder.map { String(describing: type(of: $0)) } ?? "nil")
                """)
            return event
        }
    }

    /// Writes a PNG of the whole window a few seconds after launch — `MTEXT_RENDER_DUMP=1`.
    ///
    /// The trace can say "draw ran, one row, caret advancing" while the pane is visibly
    /// empty; only an image settles what is actually on screen. Renders through
    /// `cacheDisplay`, so it needs no screen-recording permission and captures nothing but
    /// this app's own window.
    public static func dumpWindowRender() {
        guard ProcessInfo.processInfo.environment["MTEXT_RENDER_DUMP"] != nil else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            print("[render] NSApp.windows = \(NSApp.windows.count), "
                  + "key=\(NSApp.keyWindow != nil) main=\(NSApp.mainWindow != nil)")
            for (index, w) in NSApp.windows.enumerated() {
                print("[render]   window \(index): \(type(of: w)) \(w.frame.integral) "
                      + "visible=\(w.isVisible) key=\(w.isKeyWindow)")
            }
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first,
                  let content = window.contentView
            else { print("[render] no window to capture"); return }
            content.layoutSubtreeIfNeeded()
            // Force the drawing to happen before it is read back. Without this the capture
            // is genuinely unreliable on this layer-backed tree — successive runs produced
            // an all-white bitmap, a partial one, and a fully transparent one.
            content.display()
            let rect = content.bounds
            guard rect.width > 1, rect.height > 1,
                  let rep = content.bitmapImageRepForCachingDisplay(in: rect)
            else { print("[render] could not make a bitmap"); return }
            content.cacheDisplay(in: rect, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("[render] could not encode PNG"); return
            }
            let path = ProcessInfo.processInfo.environment["MTEXT_RENDER_DUMP"].flatMap {
                $0.hasSuffix(".png") ? $0 : nil
            } ?? "/tmp/mtext-render.png"
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("[render] wrote \(path) — \(rep.pixelsWide)x\(rep.pixelsHigh)")
                reportInk(rep)
                print("[render] view tree (frame / hidden / alpha):")
                dumpTree(content, depth: 0)
                reportEditorInk(content)
            } catch {
                print("[render] could not write \(path): \(error)")
            }
        }
    }

    /// How much ink the snapshot actually contains, and where. Eyeballing a 3024-wide PNG
    /// for one 16pt line of text is not a measurement — a single line is a few thousand
    /// dark pixels in six million, and easy to call "blank" when it is there.
    static func reportInk(_ rep: NSBitmapImageRep) {
        guard let data = rep.bitmapData else { return }
        let bpr = rep.bytesPerRow, bpp = rep.bitsPerPixel / 8
        var count = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide {
                let p = data + y * bpr + x * bpp
                // Anything meaningfully darker than white counts as ink.
                guard Int(p[0]) + Int(p[1]) + Int(p[2]) < 720 else { continue }
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        if count == 0 {
            print("[render] ink: NONE — the snapshot is entirely white")
            return
        }
        print("[render] ink: \(count) px, bounding box x \(minX)...\(maxX), y \(minY)...\(maxY)")

        // A bounding box spanning the whole window says nothing — a 1px border alone does
        // that. This grid shows *where* the ink is, which is what distinguishes "the editor
        // is empty but the chrome drew" from "everything drew".
        let cols = 64, rows = 24
        print("[render] ink density (top-left = window top-left, '.' = empty):")
        for gy in 0 ..< rows {
            var line = ""
            for gx in 0 ..< cols {
                var cell = 0
                let x0 = gx * rep.pixelsWide / cols, x1 = (gx + 1) * rep.pixelsWide / cols
                let y0 = gy * rep.pixelsHigh / rows, y1 = (gy + 1) * rep.pixelsHigh / rows
                for y in stride(from: y0, to: y1, by: 2) {
                    for x in stride(from: x0, to: x1, by: 2) {
                        let p = data + y * bpr + x * bpp
                        if Int(p[0]) + Int(p[1]) + Int(p[2]) < 720 { cell += 1 }
                    }
                }
                line += cell == 0 ? "." : (cell < 10 ? "-" : (cell < 60 ? "+" : "#"))
            }
            print("[render] |\(line)|")
        }
    }

    /// Ink for each on-screen `EditorView`, captured per view.
    ///
    /// Window-level capture proved untrustworthy on this layer-backed tree — successive runs
    /// gave an all-white bitmap, a partial one, and a fully transparent one — so nothing may
    /// be concluded from it. Capturing a single view has been stable, so that is what this
    /// asks: does the editor, in the real launch path, actually paint any text?
    static func reportEditorInk(_ root: NSView) {
        func walk(_ view: NSView) {
            if String(describing: type(of: view)) == "EditorView", !view.isHiddenOrHasHiddenAncestor {
                let rect = view.visibleRect
                guard rect.width > 1, rect.height > 1,
                      let rep = view.bitmapImageRepForCachingDisplay(in: rect)
                else { print("[render] editor: could not capture"); return }
                view.display()
                view.cacheDisplay(in: rect, to: rep)
                guard let data = rep.bitmapData else { return }
                let bpr = rep.bytesPerRow, bpp = rep.bitsPerPixel / 8
                let hasAlpha = rep.hasAlpha
                var ink = 0, transparent = 0
                for y in 0 ..< rep.pixelsHigh {
                    for x in 0 ..< rep.pixelsWide {
                        let p = data + y * bpr + x * bpp
                        // Composite over white: a transparent pixel shows the window's
                        // backing, which is not ink. Counting it as ink is what made the
                        // window-level numbers meaningless.
                        if hasAlpha, bpp >= 4, p[3] == 0 { transparent += 1; continue }
                        if Int(p[0]) + Int(p[1]) + Int(p[2]) < 720 { ink += 1 }
                    }
                }
                print("[render] editor \(rect.integral): \(ink) ink px, "
                      + "\(transparent) transparent of \(rep.pixelsWide * rep.pixelsHigh)"
                      + (ink == 0 ? "   ** EDITOR PAINTS NOTHING **" : ""))
            }
            view.subviews.forEach(walk)
        }
        walk(root)
    }

    /// A blank pane is almost always geometry: a view collapsed to zero, hidden, or covered.
    /// The image says *that* nothing appeared; this says *which view* is responsible.
    static func dumpTree(_ view: NSView, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        let f = view.frame.integral
        let flags = [view.isHidden ? "HIDDEN" : nil,
                     view.alphaValue < 0.99 ? "alpha=\(view.alphaValue)" : nil,
                     f.width < 1 || f.height < 1 ? "ZERO-SIZE" : nil]
            .compactMap { $0 }.joined(separator: " ")
        print("[render] \(pad)\(type(of: view)) \(f) \(flags)")
        // Deep trees are mostly AppKit internals; the interesting part is the top.
        guard depth < 10 else { return }
        for subview in view.subviews { dumpTree(subview, depth: depth + 1) }
    }

    static func describe(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.shift) { parts.append("shift") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }
}
