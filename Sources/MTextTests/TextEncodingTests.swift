import Foundation
import MTextCore
import MTextTestKit

enum TextEncodingTests {

    static let suite = TestSuite("TextEncoding", [
        ("detect plain UTF-8", testDetectPlainUTF8),
        ("detect BOMs", testDetectBOMs),
        ("Latin-1 fallback", testDetectLatin1Fallback),
        ("UTF-8 validation", testUTF8Validation),
        ("UTF-8 validation rejects subtle cases", testUTF8ValidationRejectsSubtleCases),
        ("invalid UTF-8 falls back to Latin-1 losslessly", testInvalidUTF8FallsBackToLatin1WithoutDataLoss),
        ("UTF-32 BOM is not mistaken for UTF-16", testUTF32BOMIsNotMistakenForUTF16),
        ("line ending detection", testLineEndingDetection),
        ("decode normalises to LF", testDecodeNormalisesToLF),
        ("decode strips the BOM", testDecodeStripsBOM),
        ("encode restores line ending and BOM", testEncodeRestoresLineEndingAndBOM),
        ("UTF-16 round trip", testRoundTripUTF16),
        ("atomic save and load round trip", testAtomicSaveAndLoadRoundTrip),
        ("save preserves permissions", testSavePreservesPermissions),
        ("document load sets metadata", testDocumentLoadSetsMetadata),
    ])

    static func testDetectPlainUTF8() {
        expectEqual(TextEncodingDetector.detect(Array("hello".utf8)), .utf8)
        expectEqual(TextEncodingDetector.detect(Array("Tiếng Việt 🇻🇳".utf8)), .utf8)
    }

    static func testDetectBOMs() {
        expectEqual(TextEncodingDetector.detect([0xEF, 0xBB, 0xBF, 0x61]), .utf8BOM)
        expectEqual(TextEncodingDetector.detect([0xFF, 0xFE, 0x61, 0x00]), .utf16LE)
        expectEqual(TextEncodingDetector.detect([0xFE, 0xFF, 0x00, 0x61]), .utf16BE)
    }

    static func testDetectLatin1Fallback() {
        // 0xE9 alone is invalid UTF-8 but valid Latin-1 ("é").
        expectEqual(TextEncodingDetector.detect([0x61, 0xE9, 0x62]), .isoLatin1)
    }

    static func testUTF8Validation() {
        expectTrue(TextEncodingDetector.isValidUTF8([]))
        expectTrue(TextEncodingDetector.isValidUTF8(Array("aé漢🇻🇳".utf8)))
        expectFalse(TextEncodingDetector.isValidUTF8([0xC0, 0x80]), "overlong")
        expectFalse(TextEncodingDetector.isValidUTF8([0xE2, 0x82]), "truncated")
        expectFalse(TextEncodingDetector.isValidUTF8([0xF5, 0x80, 0x80, 0x80]), "> U+10FFFF")
        expectFalse(TextEncodingDetector.isValidUTF8([0x80]), "stray continuation")
    }

    /// Regression: these all pass a naive lead-byte-only check but are invalid,
    /// and letting them through corrupts the file with U+FFFD on the next save.
    static func testUTF8ValidationRejectsSubtleCases() {
        expectFalse(TextEncodingDetector.isValidUTF8([0xE0, 0x80, 0x80]), "3-byte overlong")
        expectFalse(TextEncodingDetector.isValidUTF8([0xED, 0xA0, 0x80]), "surrogate U+D800")
        expectFalse(TextEncodingDetector.isValidUTF8([0xF0, 0x80, 0x80, 0x80]), "4-byte overlong")
        expectFalse(TextEncodingDetector.isValidUTF8([0xF4, 0x90, 0x80, 0x80]), "> U+10FFFF")
        // …while genuinely valid edge cases still pass.
        expectTrue(TextEncodingDetector.isValidUTF8([0xE0, 0xA0, 0x80]), "U+0800")
        expectTrue(TextEncodingDetector.isValidUTF8([0xED, 0x9F, 0xBF]), "U+D7FF")
        expectTrue(TextEncodingDetector.isValidUTF8([0xF4, 0x8F, 0xBF, 0xBF]), "U+10FFFF")
    }

    static func testInvalidUTF8FallsBackToLatin1WithoutDataLoss() {
        let bytes: [UInt8] = [0x61, 0xED, 0xA0, 0x80, 0x62] // surrogate in the middle
        let encoding = TextEncodingDetector.detect(bytes)
        expectEqual(encoding, .isoLatin1)
        let decoded = TextEncodingDetector.decode(bytes, encoding: encoding)
        let reencoded = TextEncodingDetector.encode(decoded.text, encoding: encoding, lineEnding: .lf)
        expectEqual([UInt8](reencoded), bytes, "round trip must not lose bytes")
    }

    static func testUTF32BOMIsNotMistakenForUTF16() {
        expectEqual(TextEncodingDetector.detect([0xFF, 0xFE, 0x00, 0x00]), .isoLatin1)
        expectEqual(TextEncodingDetector.detect([0xFF, 0xFE, 0x61, 0x00]), .utf16LE)
    }

    static func testLineEndingDetection() {
        expectEqual(TextEncodingDetector.detectLineEnding("a\nb\nc"), .lf)
        expectEqual(TextEncodingDetector.detectLineEnding("a\r\nb\r\nc"), .crlf)
        expectEqual(TextEncodingDetector.detectLineEnding("a\rb\rc"), .cr)
        expectEqual(TextEncodingDetector.detectLineEnding("no line breaks"), .lf)
    }

    static func testDecodeNormalisesToLF() {
        let decoded = TextEncodingDetector.decode(Array("a\r\nb\r\n".utf8), encoding: .utf8)
        expectEqual(decoded.text, "a\nb\n")
        expectEqual(decoded.lineEnding, .crlf)
    }

    static func testDecodeStripsBOM() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("hi".utf8)
        expectEqual(TextEncodingDetector.decode(bytes, encoding: .utf8BOM).text, "hi")
    }

    static func testEncodeRestoresLineEndingAndBOM() {
        let data = TextEncodingDetector.encode("a\nb", encoding: .utf8BOM, lineEnding: .crlf)
        expectEqual([UInt8](data), [0xEF, 0xBB, 0xBF] + Array("a\r\nb".utf8))
    }

    static func testRoundTripUTF16() {
        let original = "héllo 漢字\nsecond"
        let encoded = TextEncodingDetector.encode(original, encoding: .utf16LE, lineEnding: .lf)
        let detected = TextEncodingDetector.detect([UInt8](encoded))
        expectEqual(detected, .utf16LE)
        expectEqual(TextEncodingDetector.decode([UInt8](encoded), encoding: detected).text, original)
    }

    // MARK: - Atomic save

    static func testAtomicSaveAndLoadRoundTrip() throws {
        try withTemporaryDirectory("save") { dir in
            let url = dir.file("sample.txt")
            try FileIO.save(text: "línea uno\nlínea dos", to: url, encoding: .utf8, lineEnding: .crlf)

            let raw = try Data(contentsOf: url)
            expectTrue(String(decoding: raw, as: UTF8.self).contains("\r\n"),
                       "CRLF convention must be restored on save")

            let loaded = try FileIO.load(url)
            expectEqual(loaded.text, "línea uno\nlínea dos", "loading normalises back to LF")
            expectEqual(loaded.lineEnding, .crlf)
            expectEqual(loaded.encoding, .utf8)

            // Overwriting must not leave temp files behind.
            try FileIO.save(text: "second write", to: url, encoding: .utf8, lineEnding: .lf)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
                .filter { $0.hasPrefix(".m_text-") }
            expectTrue(leftovers.isEmpty, "temp files leaked: \(leftovers)")
        }
    }

    static func testSavePreservesPermissions() throws {
        try withTemporaryDirectory("perms") { dir in
            let url = dir.file("script.sh")
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

            try FileIO.save(text: "#!/bin/sh\necho hi\n", to: url, encoding: .utf8, lineEnding: .lf)

            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            expectEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        }
    }

    static func testDocumentLoadSetsMetadata() throws {
        try withTemporaryDirectory("doc") { dir in
            let url = dir.file("crlf.txt")
            try Data("one\r\ntwo\r\n".utf8).write(to: url)

            let doc = TextDocument()
            try doc.load(from: url)
            expectEqual(doc.lineCount, 3)
            expectEqual(doc.line(0), "one")
            expectEqual(doc.lineEnding, .crlf)
            expectEqual(doc.fileURL, url)
            expectFalse(doc.isDirty)

            _ = doc.insert("x", at: .zero)
            expectTrue(doc.isDirty)
            try doc.save()
            expectFalse(doc.isDirty)
            expectEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), "xone\r\ntwo\r\n")
        }
    }
}
