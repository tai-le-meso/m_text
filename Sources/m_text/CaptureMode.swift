import AppKit
import MTextUI

/// Screenshot mode for the landing page — `MTEXT_CAPTURE=<directory> make debug`.
///
/// Drives the real app: loads a sample buffer, switches appearance, and writes a PNG per
/// shot. Deliberately the *real* window rather than a mock, so the page shows what the editor
/// actually renders.
///
/// ⚠️ Reads back through `cacheDisplay`, which `KNOWLEDGE.md` playbook §7 records as
/// unreliable on this layer-backed tree — successive runs have produced blank, partial and
/// fully transparent bitmaps. **Every shot is therefore checked before it is used**: the
/// capture reports ink coverage and distinct colour count per file, and a shot that comes
/// back empty or near-uniform must not be shipped. If captures cannot be trusted on a given
/// machine, the landing page falls back to its CSS mockups, which are marked as such.
enum CaptureMode {

    /// Files opened for the shots. Real sources, not a synthetic string: an untitled buffer
    /// gets no grammar, so the first attempt at this captured perfectly rendered *unhighlighted*
    /// text — the one thing a screenshot of a syntax editor must not show.
    private static let sampleFiles = [
        "Sources/MTextCore/BrandTheme.swift",
        "Sources/MTextCore/PieceTree.swift",
        "Sources/MTextUI/AppearanceController.swift",
    ]

    static func runIfRequested(controller existing: MainWindowController?) {
        guard let directory = ProcessInfo.processInfo.environment["MTEXT_CAPTURE"] else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        try? FileManager.default.createDirectory(atPath: directory,
                                                 withIntermediateDirectories: true)

        // A window of its own rather than the restored session's: the session carries a dozen
        // "untitled" tabs from testing, which is not what the product looks like.
        let controller = MainWindowController()
        controller.showWindow(nil)
        guard let window = controller.window else { return }
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        window.makeKeyAndOrderFront(nil)

        let root = FileManager.default.currentDirectoryPath
        for relative in sampleFiles {
            let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) {
                controller.smokeTestOpen(url)
            } else {
                print("[capture] missing sample file \(relative) — run from the repo root")
            }
        }

        let steps: [(String, () -> Void)] = [
            ("editor-dark", {
                AppearanceController.shared.setPreference(.dark)
                controller.smokeTestSetMinimapEnabled(true)
            }),
            ("editor-light", {
                AppearanceController.shared.setPreference(.light)
            }),
            ("split-dark", {
                AppearanceController.shared.setPreference(.dark)
                controller.splitViewRight(nil)
                // Splitting opens the new pane on a blank tab; give it a real file, or the
                // shot shows half a product.
                let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Sources/MTextCore/RowMap.swift")
                if FileManager.default.fileExists(atPath: url.path) { controller.smokeTestOpen(url) }
            }),
            ("palette-dark", {
                controller.showCommandPalette(nil)
                controller.smokeTestPalette.smokeTestSetQuery("appear")
            }),
            ("clean-up", {
                controller.smokeTestPalette.dismiss()
                window.makeKeyAndOrderFront(nil)
            }),
        ]

        func run(_ index: Int) {
            guard index < steps.count else {
                print("[capture] done")
                exit(0)
            }
            let (name, action) = steps[index]
            action()
            guard name != "clean-up" else { run(index + 1); return }
            // A run-loop turn so constraints settle and the window redraws before reading.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let view = name.hasPrefix("palette")
                    ? controller.smokeTestPalette.smokeTestPanelContentView
                    : window.contentView
                write(view: view, to: "\(directory)/\(name).png", label: name)
                run(index + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { run(0) }
    }

    private static func write(view: NSView?, to path: String, label: String) {
        guard let content = view else { print("[capture] \(label): no view"); return }
        content.layoutSubtreeIfNeeded()
        content.display()
        let rect = content.bounds
        guard rect.width > 1, rect.height > 1,
              let rep = content.bitmapImageRepForCachingDisplay(in: rect)
        else { print("[capture] \(label): no bitmap"); return }
        content.cacheDisplay(in: rect, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("[capture] \(label): could not encode"); return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("[capture] \(label): \(rep.pixelsWide)x\(rep.pixelsHigh), \(quality(rep))")
        } catch {
            print("[capture] \(label): \(error)")
        }
    }

    /// Enough of a description to tell a real screenshot from an empty or uniform one, which
    /// is the failure this capture path is known for.
    private static func quality(_ rep: NSBitmapImageRep) -> String {
        guard let data = rep.bitmapData else { return "unreadable" }
        let bpr = rep.bytesPerRow, bpp = rep.bitsPerPixel / 8
        var colors = Set<UInt32>()
        var transparent = 0, sampled = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                let p = data + y * bpr + x * bpp
                sampled += 1
                if rep.hasAlpha, bpp >= 4, p[3] == 0 { transparent += 1; continue }
                colors.insert(UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2]))
            }
        }
        let transparentPercent = sampled == 0 ? 100 : transparent * 100 / sampled
        let verdict = (colors.count < 5 || transparentPercent > 50) ? "  ** UNUSABLE **" : "ok"
        return "\(colors.count) colours, \(transparentPercent)% transparent — \(verdict)"
    }
}
