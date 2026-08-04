import Foundation
import MTextCore
import MTextTestKit

/// Exercises `SymbolIndex.performIndex(...)`, the pure synchronous half — the
/// background-queue/generation-stamping half isn't separately unit-tested, same tier as
/// `FileIndex`'s queue/watcher machinery.
enum SymbolIndexTests {

    static let suite = TestSuite("SymbolIndex", [
        ("indexes symbols across multiple files", testIndexesAcrossFiles),
        ("skips a file with an unrecognised grammar", testSkipsPlainTextFiles),
        ("skips a file over the size cap", testSkipsOversizedFiles),
    ])

    private static func makeTempDirectory() -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m_text_SymbolIndexTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func write(_ text: String, to url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func testIndexesAcrossFiles() {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = root.appendingPathComponent("A.java")
        let fileB = root.appendingPathComponent("B.java")
        write("public class Foo {\n}\n", to: fileA)
        write("public class Bar {\n}\n", to: fileB)

        let files = [
            FileIndex.Entry(url: fileA, displayPath: "A.java"),
            FileIndex.Entry(url: fileB, displayPath: "B.java"),
        ]
        let entries = SymbolIndex.performIndex(files: files, registry: BuiltInGrammars.registry())

        expectTrue(entries.contains { $0.symbol.name == "Foo" && $0.displayPath == "A.java" })
        expectTrue(entries.contains { $0.symbol.name == "Bar" && $0.displayPath == "B.java" })
    }

    static func testSkipsPlainTextFiles() {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("notes.unknownext")
        write("class Foo not really code, just prose\n", to: file)

        let files = [FileIndex.Entry(url: file, displayPath: "notes.unknownext")]
        let entries = SymbolIndex.performIndex(files: files, registry: BuiltInGrammars.registry())
        expectEqual(entries.count, 0)
    }

    static func testSkipsOversizedFiles() {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("Big.java")
        write("public class Foo {\n}\n", to: file)
        let files = [FileIndex.Entry(url: file, displayPath: "Big.java")]

        // Under the real (2 MB) cap: indexed normally.
        let normal = SymbolIndex.performIndex(files: files, registry: BuiltInGrammars.registry())
        expectTrue(normal.contains { $0.symbol.name == "Foo" })

        // A cap of 1 byte forces every real file to be skipped.
        let capped = SymbolIndex.performIndex(files: files, registry: BuiltInGrammars.registry(),
                                              maximumFileSizeBytes: 1)
        expectEqual(capped.count, 0)
    }
}
