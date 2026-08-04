import Foundation
import MTextTestKit

// Test entry point. No XCTest — see Package.swift.
// Usage: swift run MTextTests [name filter]

let filter = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

var suites: [TestSuite] = [
    PieceTreeTests.suite,
    TextDocumentTests.suite,
    TextEncodingTests.suite,
    SelectionTests.suite,
    MultiCursorTests.suite,
    TextTransformTests.suite,
    SyntaxTests.suite,
    SearchTests.suite,
    PackageTests.suite,
    FuzzyMatcherTests.suite,
    FileIndexTests.suite,
    SymbolExtractorTests.suite,
    SymbolIndexTests.suite,
    KeymapTests.suite,
    ProjectTests.suite,
    SessionTests.suite,
    SettingsTests.suite,
    CompletionTests.suite,
    SnippetTests.suite,
    FoldingTests.suite,
    WordWrapTests.suite,
    RowMapTests.suite,
    MacroTests.suite,
    BuildSystemTests.suite,
    FindInFilesTests.suite,
    FindResultsTests.suite,
]

// The performance budgets are written for an optimised build; a debug build is
// several times slower and would fail them meaninglessly. `make test-release`
// runs them, as does naming them explicitly: `make test FILTER=Performance`.
#if DEBUG
if let filter, "Performance".localizedCaseInsensitiveContains(filter) {
    suites.append(PerformanceTests.suite)
} else {
    print("note: performance budgets skipped in a debug build — run `make test-release`")
}
#else
suites.append(PerformanceTests.suite)
#endif

exit(TestRunner.run(suites, filter: filter))
