import Foundation

/// Where a single document line breaks into several screen rows (T28).
///
/// Measured in **character columns**, not points. The editor already assumes a monospaced
/// font everywhere it estimates width (`updateFrameSize` sizes the canvas as
/// `charWidth × longestLineLength`), so a column model is consistent with the rest of the
/// layout and — unlike a CoreText-measured one — is pure, fast, and unit-testable without a
/// view. The cost is that a proportional `font_face` wraps approximately; that is a
/// documented consequence of the same assumption the canvas already makes, not a new one.
public enum WordWrapper {

    /// Columns at which `line` breaks, ascending, excluding 0 and the line's end.
    ///
    /// Greedy and word-aware: it breaks at the last break opportunity that fits, and only
    /// splits mid-word when a single word is itself wider than the available width — which
    /// is the behaviour that keeps a long URL or a minified line from vanishing off the
    /// right edge entirely.
    ///
    /// `width` is the usable column count. Anything under 1 disables wrapping, so a
    /// pathologically narrow window degrades to a horizontal scroll rather than to one
    /// character per row.
    public static func breaks(for line: String, width: Int, tabSize: Int = 4) -> [Int] {
        guard width >= 1 else { return [] }
        let characters = Array(line)
        guard !characters.isEmpty else { return [] }

        var breaks: [Int] = []
        var rowStart = 0                 // character index the current row begins at
        var lastOpportunity: Int?        // index just after the most recent space on this row
        var rowColumn = 0                // visual column *within the current row*
        var index = 0

        while index < characters.count {
            let character = characters[index]
            let advance = character == "\t" ? tabSize - (rowColumn % tabSize) : 1

            // A space that overflows is allowed to **hang** past the edge instead of forcing
            // a break. Without this, "aaa bbb ccc" at width 7 breaks after "aaa " — the
            // separating space trips the overflow test before "bbb" is ever considered, so
            // the row ends four columns short of a fit. Trailing whitespace is invisible
            // anyway, so hanging it costs nothing and makes the wrap properly greedy.
            // Tabs are excluded: a tab is real indentation, and letting it hang would run
            // rows arbitrarily far past the width.
            let hangs = character == " "

            if !hangs, rowColumn + advance > width {
                let breakAt: Int
                if let opportunity = lastOpportunity, opportunity > rowStart, opportunity <= index {
                    breakAt = opportunity
                } else {
                    // One word wider than the row: hard-break rather than let it run off
                    // screen. `rowStart + 1` guarantees forward progress even when a single
                    // character (a wide tab) exceeds the whole width, which would otherwise
                    // loop forever.
                    breakAt = max(index, rowStart + 1)
                }
                // A break at the line's end would add an empty trailing row.
                guard breakAt < characters.count else { break }
                breaks.append(breakAt)
                rowStart = breakAt
                lastOpportunity = nil
                index = breakAt
                rowColumn = 0
                continue
            }

            if character == " " || character == "\t" { lastOpportunity = index + 1 }
            rowColumn += advance
            index += 1
        }
        return breaks
    }

    /// Rows a line occupies — always at least 1, so an empty line still takes a row.
    public static func rowCount(for line: String, width: Int, tabSize: Int = 4) -> Int {
        breaks(for: line, width: width, tabSize: tabSize).count + 1
    }

    /// Which wrapped row within its line `column` falls on.
    public static func row(forColumn column: Int, breaks: [Int]) -> Int {
        var row = 0
        for breakColumn in breaks where column >= breakColumn { row += 1 }
        return row
    }

    /// Column range covered by wrapped row `row`, given the line's break points.
    public static func columnRange(ofRow row: Int, breaks: [Int], lineLength: Int) -> Range<Int> {
        let start = row == 0 ? 0 : breaks[min(row - 1, breaks.count - 1)]
        let end = row < breaks.count ? breaks[row] : lineLength
        return start ..< max(start, end)
    }
}
