import Foundation

/// Guesses a language from the *content* of a document, not its name.
///
/// `GrammarRegistry.grammar(for:firstLine:)` covers the common case — a real file with
/// an extension, or a shebang. This covers the other one: an untitled buffer that the
/// user pasted or typed real code into, which has no extension to go on at all.
///
/// Deliberately a heuristic, not a real classifier: each candidate language has a small
/// set of hand-picked signature patterns (keywords, punctuation shapes) with a weight,
/// and whichever language's patterns add up to the highest score — clearly ahead of the
/// runner-up, past a minimum bar — wins. Short or ambiguous text returns nil rather than
/// guessing, which is the safe failure mode: the buffer just stays on Plain Text, same
/// as today.
public enum ContentSniffer {

    /// Below this, "clearly ahead" isn't a large enough sample to trust — a two-line
    /// paste that happens to contain one common keyword shouldn't flip the syntax.
    private static let minimumScore = 4
    /// The winner must beat the runner-up by at least this much, or the guess is
    /// discarded rather than picked arbitrarily between two plausible languages.
    private static let minimumMargin = 3
    /// Content is scanned from the start only, and capped — this can run on every
    /// several keystrokes of an untitled buffer, so it must stay cheap regardless of
    /// how long the document eventually gets.
    private static let sampleLimit = 4_000

    /// Returns the winning grammar's `scope`, for `GrammarRegistry.grammar(forScope:)`,
    /// or nil when nothing scores confidently enough.
    public static func detect(_ text: String) -> String? {
        let sample = String(text.prefix(sampleLimit))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let full = NSRange(sample.startIndex ..< sample.endIndex, in: sample)

        var scores: [String: Int] = [:]
        for signature in signatures {
            var total = 0
            for pattern in signature.patterns where pattern.regex.firstMatch(in: sample, range: full) != nil {
                total += pattern.weight
            }
            if total > 0 { scores[signature.scope] = total }
        }

        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= minimumScore else { return nil }
        if let runnerUp = ranked.dropFirst().first, best.value - runnerUp.value < minimumMargin {
            return nil
        }
        return best.key
    }

    // MARK: - Signatures

    private struct WeightedPattern {
        let regex: NSRegularExpression
        let weight: Int
    }

    private struct Signature {
        let scope: String
        let patterns: [WeightedPattern]
    }

    /// `try?` rather than `try!`: a typo in one hand-written pattern below should quietly
    /// drop that one pattern, not crash every document view at launch.
    private static func pattern(_ source: String, weight: Int, lines: Bool = false) -> WeightedPattern? {
        var options: NSRegularExpression.Options = [.caseInsensitive]
        if lines { options.insert(.anchorsMatchLines) }
        guard let regex = try? NSRegularExpression(pattern: source, options: options) else { return nil }
        return WeightedPattern(regex: regex, weight: weight)
    }

    private static let signatures: [Signature] = [
        Signature(scope: "source.sql", patterns: [
            pattern(#"\bselect\b[\s\S]{0,200}\bfrom\b"#, weight: 3),
            pattern(#"\bcreate\s+table\b"#, weight: 4),
            pattern(#"\binsert\s+into\b"#, weight: 4),
            pattern(#"\bwhere\b"#, weight: 1),
        ].compactMap { $0 }),

        Signature(scope: "source.rust", patterns: [
            pattern(#"\bfn\s+\w+\s*\("#, weight: 3, lines: true),
            pattern(#"\blet\s+mut\b"#, weight: 2),
            pattern(#"#!?\[derive\("#, weight: 4),
            pattern(#"\buse\s+std::"#, weight: 3),
            pattern(#"->\s*\w+\s*\{"#, weight: 1),
        ].compactMap { $0 }),

        Signature(scope: "source.go", patterns: [
            pattern(#"^\s*package\s+main\b"#, weight: 4, lines: true),
            pattern(#"\bfunc\s+main\s*\(\s*\)"#, weight: 3),
            pattern(#"\w+\s*:="#, weight: 2),
            pattern(#"^\s*import\s*\("#, weight: 2, lines: true),
        ].compactMap { $0 }),

        Signature(scope: "source.perl", patterns: [
            pattern(#"^use strict\b"#, weight: 3, lines: true),
            pattern(#"\bmy\s+\$\w+"#, weight: 3),
            pattern(#"\bsub\s+\w+\s*\{"#, weight: 2),
            pattern(#"^#!.*\bperl\b"#, weight: 4, lines: true),
        ].compactMap { $0 }),

        Signature(scope: "source.python", patterns: [
            pattern(#"^\s*def\s+\w+\s*\([^)]*\)\s*:\s*$"#, weight: 3, lines: true),
            pattern(#"^\s*(?:import|from)\s+\w+"#, weight: 2, lines: true),
            pattern(#"\bself\b"#, weight: 1),
            pattern(#"\belif\b"#, weight: 3),
            pattern(#"^\s*if __name__\s*==\s*['"]__main__['"]"#, weight: 4, lines: true),
        ].compactMap { $0 }),

        Signature(scope: "source.java", patterns: [
            pattern(#"\bpublic\s+(?:static\s+)?(?:final\s+)?class\s+\w+"#, weight: 4),
            pattern(#"\bSystem\.out\.println\b"#, weight: 4),
            pattern(#"\bpublic\s+static\s+void\s+main\s*\("#, weight: 4),
            pattern(#"\bpackage\s+[\w.]+;"#, weight: 2),
        ].compactMap { $0 }),

        Signature(scope: "source.swift", patterns: [
            pattern(#"\bfunc\s+\w+\s*\("#, weight: 2),
            pattern(#"\bimport\s+(?:Foundation|SwiftUI|UIKit|AppKit)\b"#, weight: 4),
            pattern(#"\bguard\s+let\b"#, weight: 3),
            pattern(#"\bvar\s+\w+\s*:\s*\w+"#, weight: 1),
        ].compactMap { $0 }),

        Signature(scope: "source.c++", patterns: [
            pattern(#"#include\s*<iostream>"#, weight: 4),
            pattern(#"\bstd::\w+"#, weight: 2),
            pattern(#"\b(?:cout|cin)\s*(?:<<|>>)"#, weight: 3),
            pattern(#"\btemplate\s*<"#, weight: 3),
            pattern(#"\bclass\s+\w+\s*\{"#, weight: 1),
        ].compactMap { $0 }),

        Signature(scope: "source.c", patterns: [
            pattern(#"#include\s*<stdio\.h>"#, weight: 4),
            pattern(#"\bprintf\s*\("#, weight: 2),
            pattern(#"\bint\s+main\s*\(\s*(?:void)?\s*\)"#, weight: 2),
        ].compactMap { $0 }),

        Signature(scope: "source.cs", patterns: [
            pattern(#"\busing\s+System;"#, weight: 4),
            pattern(#"\bnamespace\s+[\w.]+"#, weight: 2),
            pattern(#"\bConsole\.WriteLine\b"#, weight: 4),
            pattern(#"\bpublic\s+class\s+\w+"#, weight: 1),
        ].compactMap { $0 }),

        Signature(scope: "source.objc", patterns: [
            pattern(#"#import\s*<Foundation/Foundation\.h>"#, weight: 4),
            pattern(#"@interface\b"#, weight: 4),
            pattern(#"@implementation\b"#, weight: 4),
            pattern(#"\bNSLog\s*\("#, weight: 3),
        ].compactMap { $0 }),

        Signature(scope: "source.php", patterns: [
            pattern(#"<\?php\b"#, weight: 5),
            pattern(#"\$\w+\s*="#, weight: 1),
            pattern(#"\becho\b"#, weight: 1),
        ].compactMap { $0 }),

        Signature(scope: "source.ruby", patterns: [
            pattern(#"\bputs\s"#, weight: 2),
            pattern(#"\brequire(?:_relative)?\s+['"]"#, weight: 3),
            pattern(#"\battr_(?:accessor|reader|writer)\b"#, weight: 4),
            pattern(#"^\s*def\s+\w+"#, weight: 1, lines: true),
            pattern(#"^\s*end\s*$"#, weight: 1, lines: true),
        ].compactMap { $0 }),

        Signature(scope: "source.js", patterns: [
            pattern(#"\bconsole\.log\s*\("#, weight: 3),
            pattern(#"\b(?:const|let)\s+\w+\s*="#, weight: 1),
            pattern(#"=>\s*\{"#, weight: 1),
            pattern(#"\brequire\s*\(\s*['"]"#, weight: 2),
            pattern(#"\bexport\s+(?:default\s+)?(?:function|class|const)\b"#, weight: 2),
        ].compactMap { $0 }),

        Signature(scope: "source.ts", patterns: [
            pattern(#"\binterface\s+\w+\s*\{"#, weight: 3),
            pattern(#":\s*(?:string|number|boolean|void|any)\b"#, weight: 2),
            pattern(#"\bexport\s+(?:type|interface)\b"#, weight: 3),
            pattern(#"\bimport\s+.*\bfrom\s+['"]"#, weight: 1),
        ].compactMap { $0 }),

        Signature(scope: "text.xml", patterns: [
            pattern(#"^\s*<\?xml\b"#, weight: 5, lines: true),
            pattern(#"<!DOCTYPE\s+html"#, weight: 4),
            pattern(#"<html\b"#, weight: 2),
            pattern(#"</\w+>"#, weight: 1),
        ].compactMap { $0 }),

        Signature(scope: "source.json", patterns: [
            pattern(#"^\s*[\{\[]\s*$"#, weight: 1, lines: true),
            pattern(#""[\w-]+"\s*:\s*(?:"|\d|true|false|null|\{|\[)"#, weight: 2),
        ].compactMap { $0 }),

        Signature(scope: "source.yaml", patterns: [
            pattern(#"^---\s*$"#, weight: 3, lines: true),
            pattern(#"^[\w.-]+:\s*$"#, weight: 1, lines: true),
            pattern(#"^\s*-\s+\w"#, weight: 1, lines: true),
        ].compactMap { $0 }),

        Signature(scope: "source.shell", patterns: [
            pattern(#"^#!.*\b(?:ba|z|k)?sh\b"#, weight: 5, lines: true),
            pattern(#"\bfi\b"#, weight: 2),
            pattern(#"\bdone\b"#, weight: 2),
            pattern(#"\becho\b"#, weight: 1),
        ].compactMap { $0 }),

        Signature(scope: "source.css", patterns: [
            pattern(#"\{[^{}]*:[^{}]*;[^{}]*\}"#, weight: 2),
            pattern(#"@media\b"#, weight: 3),
            pattern(#"^\s*[.#][\w-]+\s*\{"#, weight: 2, lines: true),
        ].compactMap { $0 }),

        Signature(scope: "text.html.markdown", patterns: [
            pattern(#"^#{1,6}\s+\S"#, weight: 2, lines: true),
            pattern(#"^\s*[-*+]\s+\S"#, weight: 1, lines: true),
            pattern(#"\[[^\]]+\]\([^)]+\)"#, weight: 2),
            pattern(#"^```"#, weight: 2, lines: true),
        ].compactMap { $0 }),
    ]
}
