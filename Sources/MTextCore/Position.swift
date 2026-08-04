import Foundation

/// A caret position. `column` is measured in Characters (grapheme clusters), so it
/// matches what the user sees; the document converts it to a UTF-8 byte offset.
public struct Position: Equatable, Comparable, Hashable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static let zero = Position(line: 0, column: 0)

    public static func < (a: Position, b: Position) -> Bool {
        a.line != b.line ? a.line < b.line : a.column < b.column
    }
}
