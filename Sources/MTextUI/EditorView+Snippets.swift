import AppKit
import MTextCore

// T91 — inserting snippets and driving the tab-stop session.
//
// The session model itself (`SnippetSession`) lives in MTextCore and is pure offset
// arithmetic; this file is only the AppKit half: turning byte ranges into selections,
// applying the mirror edits the session asks for, and deciding which key does what while a
// snippet is active.
extension EditorView {

    var isSnippetActive: Bool { snippetSession?.isFinished == false }

    // MARK: - Inserting

    /// Expands `snippet` at the caret, replacing `replacingPrefix` characters before it
    /// (the tab trigger, when there was one).
    public func insertSnippet(_ snippet: Snippet, replacingPrefix prefixLength: Int = 0) {
        guard !selection.isMultiple else {
            // No single caret to build a session around, and a snippet with mirrors has no
            // sensible meaning applied at several places at once.
            NSSound.beep()
            return
        }

        let expansion = SnippetRenderer.expand(snippet.content, context: snippetContext())

        // Replace the trigger word (if any) along with the selection, so `for<Tab>` leaves
        // no "for" behind.
        let head = selection.primary.head
        let start = Position(line: head.line, column: max(0, head.column - prefixLength))
        let target = prefixLength > 0 && !selection.hasSelectedText
            ? Selection(regions: [Region(anchor: start, head: head)])
            : selection

        let originByteOffset = document.byteOffset(of: target.primary.start)
        didEdit(newSelection: document.replace(target, withEach: expansion.text))

        // No placeholders means there is nothing to Tab through; the caret is already in
        // the right place after the insert.
        guard let session = SnippetSession(expansion: expansion,
                                           originByteOffset: originByteOffset) else {
            snippetSession = nil
            return
        }
        snippetSession = session
        selectCurrentSnippetStop()
    }

    /// Values for `$SELECTION`, `$TM_FILENAME` and friends, read at expansion time.
    private func snippetContext() -> SnippetContext {
        let head = selection.primary.head
        let url = document.fileURL
        return SnippetContext(
            selection: document.text(in: selection.primary),
            fileName: url?.lastPathComponent ?? "",
            filePath: url?.path ?? "",
            directory: url?.deletingLastPathComponent().path ?? "",
            currentLine: document.line(head.line),
            lineNumber: head.line + 1,
            currentWord: CompletionEngine.prefix(in: document, before: head),
            tabSize: indentUnit == "\t" ? 4 : indentUnit.count
        )
    }

    // MARK: - Navigation

    /// Selects the stop the session is currently on. A placeholder is *selected* so typing
    /// replaces it; an empty stop collapses to a caret.
    private func selectCurrentSnippetStop() {
        guard let stop = snippetSession?.currentStop else { return }
        let range = stop.primary
        let anchor = document.position(ofByteOffset: range.lowerBound)
        let head = document.position(ofByteOffset: range.upperBound)
        didMoveSelection(Selection(regions: [Region(anchor: anchor, head: head)]), scroll: true)
    }

    /// Tab while a snippet is active. Returns true when it was consumed.
    func advanceSnippet() -> Bool {
        guard let session = snippetSession, !session.isFinished else { return false }
        // Committing whatever is in the current stop before moving on, so mirrors are up to
        // date even if the user typed and Tabbed without pausing.
        synchronizeSnippetMirrors()
        guard session.advance() != nil else {
            snippetSession = nil
            return true   // still consumed: Tab ended the snippet rather than indenting
        }
        selectCurrentSnippetStop()
        return true
    }

    func retreatSnippet() -> Bool {
        guard let session = snippetSession, !session.isFinished else { return false }
        synchronizeSnippetMirrors()
        _ = session.retreat()
        selectCurrentSnippetStop()
        return true
    }

    func endSnippetSession() {
        snippetSession?.finish()
        snippetSession = nil
    }

    // MARK: - Keeping the document and session in step

    /// Called after every edit while a session is active, from `didEdit`.
    func snippetDidEdit(replaced: Range<Int>, newByteLength: Int) {
        guard let session = snippetSession, !session.isFinished else { return }
        guard session.rebase(replaced: replaced, newByteLength: newByteLength) else {
            // The edit straddled a stop boundary — the session can no longer say where its
            // stops are, so it ends rather than silently corrupting the document.
            snippetSession = nil
            return
        }
        synchronizeSnippetMirrors()
    }

    /// Rewrites every mirror of the current stop to match what is in the primary range.
    ///
    /// The session hands back edits **back to front** precisely so applying them in order
    /// can't invalidate the ones still queued, and it has already rebased its own ranges as
    /// if these edits happened — so this must apply all of them, and must not route them
    /// back through `snippetDidEdit`.
    private func synchronizeSnippetMirrors() {
        guard let session = snippetSession, let stop = session.currentStop,
              stop.ranges.count > 1 else { return }

        let primary = stop.primary
        let activeText = document.text(in: Region(anchor: document.position(ofByteOffset: primary.lowerBound),
                                                  head: document.position(ofByteOffset: primary.upperBound)))
        let edits = session.mirrorEdits(activeText: activeText)
        guard !edits.isEmpty else { return }

        // The caret is tracked in byte offsets across the rewrites, not as a `Position`:
        // line/column would silently mean something different once a mirror on an earlier
        // line changed length. A mirror is usually *after* the caret (and so harmless), but
        // a snippet can legitimately place one before it.
        var anchorOffset = document.byteOffset(of: selection.primary.anchor)
        var headOffset = document.byteOffset(of: selection.primary.head)

        isApplyingSnippetMirrors = true
        for edit in edits {
            let region = Region(anchor: document.position(ofByteOffset: edit.range.lowerBound),
                                head: document.position(ofByteOffset: edit.range.upperBound))
            _ = document.replace(Selection(regions: [region]), withEach: edit.replacement)

            let delta = edit.replacement.utf8.count - edit.range.count
            if edit.range.upperBound <= anchorOffset { anchorOffset += delta }
            if edit.range.upperBound <= headOffset { headOffset += delta }
        }
        isApplyingSnippetMirrors = false

        didMoveSelection(Selection(regions: [
            Region(anchor: document.position(ofByteOffset: anchorOffset),
                   head: document.position(ofByteOffset: headOffset)),
        ]), scroll: false)
    }

    // MARK: - Tab trigger

    /// Tab pressed with no snippet active: expand a trigger word if there is one.
    /// Returns true when a snippet was inserted, so Tab doesn't also indent.
    func expandSnippetTrigger() -> Bool {
        guard !selection.isMultiple, selection.primary.isEmpty else { return false }
        let word = CompletionEngine.prefix(in: document, before: selection.primary.head)
        guard !word.isEmpty else { return false }
        guard let snippet = EditorView.snippetStore.snippet(forTrigger: word, scope: syntaxScope)
        else { return false }
        insertSnippet(snippet, replacingPrefix: word.count)
        return true
    }
}
