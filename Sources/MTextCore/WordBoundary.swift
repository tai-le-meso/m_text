import Foundation

public enum CharacterClass {
    case word
    case whitespace
    case punctuation
}

public enum WordBoundary {

    /// Sublime's default `word_separators`, minus the characters we treat as word
    /// constituents. Anything not a separator and not whitespace counts as a word
    /// character, so accented letters and CJK behave correctly.
    public static let separators: Set<Character> = Set("./\\()\"'-:,.;<>~!@#$%^&*|+=[]{}`~?")

    public static func classify(_ character: Character) -> CharacterClass {
        if character == "_" { return .word }
        if character.isWhitespace { return .whitespace }
        if separators.contains(character) { return .punctuation }
        return .word
    }

    /// A "subword" boundary also breaks at camelCase humps and digit runs,
    /// used by ⌃← / ⌃→ style movement.
    public static func isSubwordBoundary(previous: Character, next: Character) -> Bool {
        if classify(previous) != classify(next) { return true }
        if previous.isLowercase && next.isUppercase { return true }
        if previous.isNumber != next.isNumber { return true }
        return false
    }
}

public extension TextDocument {

    /// The word-ish range containing `position`. Double-click selects this.
    ///
    /// Clicking inside a run of letters selects the word; clicking in whitespace
    /// selects the whitespace run; clicking on punctuation selects that run.
    func wordRange(at position: Position) -> Region {
        let p = clamp(position)
        let text = line(p.line)
        let characters = Array(text)
        guard !characters.isEmpty else { return Region(caret: p) }

        // A caret sitting just past a word belongs to that word.
        let index = min(p.column, characters.count - 1)
        let probe = p.column > 0 && p.column >= characters.count ? characters.count - 1 : index
        let target = WordBoundary.classify(characters[probe])

        var start = probe
        while start > 0 && WordBoundary.classify(characters[start - 1]) == target { start -= 1 }
        var end = probe
        while end < characters.count && WordBoundary.classify(characters[end]) == target { end += 1 }

        return Region(anchor: Position(line: p.line, column: start),
                      head: Position(line: p.line, column: end))
    }

    /// The whole line including its trailing newline (⌘L, triple-click).
    func lineRegion(at position: Position) -> Region {
        let p = clamp(position)
        let start = Position(line: p.line, column: 0)
        if p.line + 1 < lineCount {
            return Region(anchor: start, head: Position(line: p.line + 1, column: 0))
        }
        return Region(anchor: start, head: Position(line: p.line, column: lineLength(p.line)))
    }

    /// Next word boundary in the given direction, crossing lines when needed.
    func wordBoundary(from position: Position, forward: Bool, subword: Bool = false) -> Position {
        var p = clamp(position)
        let characters = Array(line(p.line))

        if forward {
            if p.column >= characters.count {
                return p.line + 1 < lineCount ? Position(line: p.line + 1, column: 0) : p
            }
            var i = p.column
            // Skip leading whitespace, then consume one run.
            while i < characters.count && WordBoundary.classify(characters[i]) == .whitespace { i += 1 }
            if i < characters.count {
                let runClass = WordBoundary.classify(characters[i])
                var previous = characters[i]
                i += 1
                while i < characters.count {
                    let c = characters[i]
                    if WordBoundary.classify(c) != runClass { break }
                    if subword && WordBoundary.isSubwordBoundary(previous: previous, next: c) { break }
                    previous = c
                    i += 1
                }
            }
            p.column = i
            return p
        }

        if p.column == 0 {
            return p.line > 0
                ? Position(line: p.line - 1, column: lineLength(p.line - 1))
                : p
        }
        var i = p.column
        while i > 0 && WordBoundary.classify(characters[i - 1]) == .whitespace { i -= 1 }
        if i > 0 {
            let runClass = WordBoundary.classify(characters[i - 1])
            var next = characters[i - 1]
            i -= 1
            while i > 0 {
                let c = characters[i - 1]
                if WordBoundary.classify(c) != runClass { break }
                if subword && WordBoundary.isSubwordBoundary(previous: c, next: next) { break }
                next = c
                i -= 1
            }
        }
        p.column = i
        return p
    }

    /// First non-whitespace column, for smart Home (⌘← toggles between the two).
    func firstNonBlankColumn(of lineIndex: Int) -> Int {
        let characters = Array(line(lineIndex))
        var i = 0
        while i < characters.count && characters[i].isWhitespace { i += 1 }
        return i == characters.count ? 0 : i
    }

    /// The leading whitespace of a line, copied when opening a new line.
    func indentation(of lineIndex: Int) -> String {
        let text = line(lineIndex)
        return String(text.prefix { $0 == " " || $0 == "\t" })
    }
}
