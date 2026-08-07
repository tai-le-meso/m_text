import AppKit

/// The window's content view, with folder/file drop handling attached.
///
/// A subclass of the split view that is *already* the content view, rather than a new
/// wrapper around it. Inserting a container would change the view hierarchy the window's
/// whole layout hangs off, and this project has lost two days to exactly that class of
/// change (`KNOWLEDGE.md` S1, S6). A subclass adds behaviour and moves nothing.
///
/// Accepts drops anywhere on the window, which is what Sublime does — folders join the
/// project, files open as tabs. The two are separated here rather than by the caller because
/// the distinction is a file-system question, not a policy one.
final class FileDropSplitView: NSSplitView {

    /// Called with the dropped folders and files, already separated. Either may be empty.
    var onDrop: ((_ folders: [URL], _ files: [URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    /// `.copy` only when there is something to take. Returning `.copy` for, say, a dragged
    /// colour swatch shows a drop cursor the drop then ignores.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = urls(from: sender)
        guard !dropped.isEmpty else { return false }

        var folders: [URL] = [], files: [URL] = []
        for url in dropped {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            else { continue }
            if isDirectory.boolValue { folders.append(url) } else { files.append(url) }
        }
        guard !folders.isEmpty || !files.isEmpty else { return false }
        onDrop?(folders, files)
        return true
    }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        // `urlReadingFileURLsOnly` keeps out promised/remote drags this cannot open anyway;
        // without it a dragged web image arrives as a URL with no file behind it.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}
