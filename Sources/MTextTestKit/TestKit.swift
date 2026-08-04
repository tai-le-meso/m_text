import Foundation

/// A dependency-free test harness.
///
/// XCTest ships inside Xcode.app, which this project deliberately does not require,
/// so the suite runs on a plain Command Line Tools install instead.

// MARK: - Failure recording

public struct TestFailure {
    public let suite: String
    public let test: String
    public let message: String
    public let file: String
    public let line: Int
}

/// Single-threaded by design: the runner executes tests sequentially, so plain
/// static state is safe here (and `nonisolated(unsafe)` would need Swift 5.10+).
public enum TestReporter {
    static var currentSuite = ""
    static var currentTest = ""
    static var failures: [TestFailure] = []
    static var assertions = 0

    static func record(_ message: String, file: StaticString, line: UInt) {
        failures.append(TestFailure(suite: currentSuite,
                                    test: currentTest,
                                    message: message,
                                    file: URL(fileURLWithPath: "\(file)").lastPathComponent,
                                    line: Int(line)))
    }
}

// MARK: - Assertions

public func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ note: String = "",
                                      file: StaticString = #file, line: UInt = #line) {
    TestReporter.assertions += 1
    guard actual != expected else { return }
    let suffix = note.isEmpty ? "" : " — \(note)"
    TestReporter.record("expected \(describe(expected)), got \(describe(actual))\(suffix)",
                        file: file, line: line)
}

public func expectTrue(_ value: Bool, _ note: String = "",
                       file: StaticString = #file, line: UInt = #line) {
    TestReporter.assertions += 1
    guard !value else { return }
    TestReporter.record(note.isEmpty ? "expected true" : "expected true — \(note)", file: file, line: line)
}

public func expectFalse(_ value: Bool, _ note: String = "",
                        file: StaticString = #file, line: UInt = #line) {
    TestReporter.assertions += 1
    guard value else { return }
    TestReporter.record(note.isEmpty ? "expected false" : "expected false — \(note)", file: file, line: line)
}

public func expectNil<T>(_ value: T?, _ note: String = "",
                         file: StaticString = #file, line: UInt = #line) {
    TestReporter.assertions += 1
    guard let value else { return }
    let suffix = note.isEmpty ? "" : " — \(note)"
    TestReporter.record("expected nil, got \(describe(value))\(suffix)", file: file, line: line)
}

public func expectLessThan<T: Comparable>(_ actual: T, _ limit: T, _ note: String = "",
                                          file: StaticString = #file, line: UInt = #line) {
    TestReporter.assertions += 1
    guard !(actual < limit) else { return }
    let suffix = note.isEmpty ? "" : " — \(note)"
    TestReporter.record("expected \(describe(actual)) < \(describe(limit))\(suffix)", file: file, line: line)
}

/// Fails if `body` does not throw. `verify` inspects the thrown error.
public func expectThrows(_ body: () throws -> Void,
                         _ note: String = "",
                         file: StaticString = #file, line: UInt = #line,
                         verify: (Error) -> Void = { _ in }) {
    TestReporter.assertions += 1
    do {
        try body()
        let suffix = note.isEmpty ? "" : " — \(note)"
        TestReporter.record("expected an error to be thrown\(suffix)", file: file, line: line)
    } catch {
        verify(error)
    }
}

/// Fails if `body` throws. Use to guard setup that should always succeed.
public func expectNoThrow(_ body: () throws -> Void, _ note: String = "",
                          file: StaticString = #file, line: UInt = #line) {
    TestReporter.assertions += 1
    do {
        try body()
    } catch {
        let suffix = note.isEmpty ? "" : " — \(note)"
        TestReporter.record("unexpected error \(error)\(suffix)", file: file, line: line)
    }
}

public func fail(_ message: String, file: StaticString = #file, line: UInt = #line) {
    TestReporter.assertions += 1
    TestReporter.record(message, file: file, line: line)
}

private func describe<T>(_ value: T) -> String {
    if let string = value as? String {
        return "\"\(string.count > 120 ? String(string.prefix(120)) + "…" : string)\""
    }
    return String(describing: value)
}

// MARK: - Suites

public struct TestSuite {
    public let name: String
    public let tests: [(String, () throws -> Void)]

    public init(_ name: String, _ tests: [(String, () throws -> Void)]) {
        self.name = name
        self.tests = tests
    }
}

// MARK: - Runner

public enum TestRunner {

    /// Runs every suite and returns a process exit code (0 = all passed).
    /// Pass a substring as `filter` to run a subset: `swift run MTextTests PieceTree`.
    public static func run(_ suites: [TestSuite], filter: String? = nil) -> Int32 {
        let start = Date()
        var passed = 0
        var failed = 0
        var skipped = 0

        for suite in suites {
            TestReporter.currentSuite = suite.name
            var printedHeader = false

            for (name, body) in suite.tests {
                if let filter, !filter.isEmpty,
                   !suite.name.localizedCaseInsensitiveContains(filter),
                   !name.localizedCaseInsensitiveContains(filter) {
                    skipped += 1
                    continue
                }
                if !printedHeader {
                    print("\n\(suite.name)")
                    printedHeader = true
                }

                TestReporter.currentTest = name
                let before = TestReporter.failures.count
                let testStart = Date()
                do {
                    try body()
                } catch {
                    TestReporter.record("threw \(error)", file: #file, line: #line)
                }
                let elapsed = Date().timeIntervalSince(testStart)
                let new = TestReporter.failures.count - before

                if new == 0 {
                    passed += 1
                    print("  \(green("✓")) \(name)\(timing(elapsed))")
                } else {
                    failed += 1
                    print("  \(red("✗")) \(name)\(timing(elapsed))")
                    for failure in TestReporter.failures[before...] {
                        print("      \(failure.file):\(failure.line)  \(failure.message)")
                    }
                }
            }
        }

        let total = Date().timeIntervalSince(start)
        print("")
        if failed == 0 {
            print(green("\(passed) passed") + ", \(TestReporter.assertions) assertions"
                  + (skipped > 0 ? ", \(skipped) filtered out" : "")
                  + String(format: " in %.2fs", total))
        } else {
            print(red("\(failed) failed") + ", \(passed) passed"
                  + (skipped > 0 ? ", \(skipped) filtered out" : "")
                  + String(format: " in %.2fs", total))
        }
        return failed == 0 ? 0 : 1
    }

    private static func timing(_ seconds: TimeInterval) -> String {
        seconds < 0.05 ? "" : String(format: "  (%.2fs)", seconds)
    }

    private static var useColor: Bool { isatty(STDOUT_FILENO) == 1 }
    private static func green(_ s: String) -> String { useColor ? "\u{1B}[32m\(s)\u{1B}[0m" : s }
    private static func red(_ s: String) -> String { useColor ? "\u{1B}[31m\(s)\u{1B}[0m" : s }
}

// MARK: - Shared helpers

/// Deterministic PRNG so fuzz failures reproduce exactly.
public struct SplitMix64 {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A temporary directory that deletes itself.
///
/// Always obtain one via `withTemporaryDirectory` — ARC may release a local binding
/// after its last *use*, not at end of scope, which would run `deinit` and delete the
/// directory out from under the rest of the test.
public final class TemporaryDirectory {
    public let url: URL

    public init(_ label: String) throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m_text-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Runs `body` with a temporary directory that is guaranteed to outlive it.
public func withTemporaryDirectory<R>(_ label: String,
                                      _ body: (TemporaryDirectory) throws -> R) throws -> R {
    let dir = try TemporaryDirectory(label)
    defer { withExtendedLifetime(dir) {} }
    return try body(dir)
}
