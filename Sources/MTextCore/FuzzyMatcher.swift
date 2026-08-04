import Foundation

/// Fuzzy subsequence matching shared by Goto Anything and the Command Palette (T70).
///
/// Scores how well a short `query` matches as an ordered, not-necessarily-contiguous
/// subsequence of a longer `candidate` (a file path, symbol name, or command title),
/// favouring matches that land on word boundaries (right after `/ \ _ - . space`, or a
/// lower→upper "camelCase" transition) and runs of consecutive characters, and
/// penalising gaps between matched characters and a late start. Case-insensitive.
///
/// This is a single left-to-right greedy pass — for each query character it takes the
/// *first* occurrence at or after where the previous character matched, rather than
/// solving for the globally best-scoring alignment with a full dynamic-programming
/// table. That is a deliberate approximation shared by most editors' "fuzzy open file"
/// pickers (Sublime's own scorer included): it is O(pattern × candidate) instead of
/// something worse, occasionally not-quite-optimal on pathological inputs, and in
/// practice indistinguishable from an optimal scorer for the short queries and short
/// candidates (file names, symbol names) this is actually used on.
public enum FuzzyMatcher {

    /// A successful match: an unbounded score (higher is better; only meaningful
    /// relative to other scores for the *same* query) and the position of every matched
    /// character in `candidate`, in order — callers use these to bold the matched
    /// letters in a result list.
    public struct Match {
        public let score: Int
        public let indices: [Int]

        public init(score: Int, indices: [Int]) {
            self.score = score
            self.indices = indices
        }
    }

    /// Characters after which the next character counts as "starting a word", for the
    /// boundary bonus — typical path/identifier separators.
    private static let boundarySeparators: Set<Character> = ["/", "\\", "_", "-", ".", " ", "\t"]

    // Bonuses/penalties are tuned by feel, not a formal model — same spirit as the
    // heuristic weights in ContentSniffer. Revisit if real usage ever "feels" wrong.
    private static let firstCharacterBonus = 8
    private static let boundaryBonus = 6
    private static let camelCaseBonus = 6
    private static let consecutiveRunBonus = 4
    private static let gapPenaltyPerSkippedCharacter = 2
    private static let leadingCharacterPenalty = 1
    private static let maxLeadingPenalty = 12

    /// `nil` if `query` isn't found as an in-order (not necessarily contiguous)
    /// subsequence of `candidate` at all. An empty query matches everything with a
    /// score of 0 and no highlighted indices, so an empty palette search box shows every
    /// candidate in its natural order.
    public static func match(query: String, in candidate: String) -> Match? {
        guard !query.isEmpty else { return Match(score: 0, indices: []) }
        guard !candidate.isEmpty else { return nil }

        let queryCharacters = Array(query.lowercased())
        let candidateCharacters = Array(candidate)
        let candidateLowercased = candidateCharacters.map { Character(String($0).lowercased()) }

        var indices: [Int] = []
        indices.reserveCapacity(queryCharacters.count)
        var score = 0
        var searchFrom = 0
        var previousMatchIndex = -1
        var consecutiveRun = 0

        for queryCharacter in queryCharacters {
            guard let foundIndex = firstIndex(of: queryCharacter, in: candidateLowercased, from: searchFrom)
            else { return nil }

            var characterScore = 0
            if foundIndex == 0 {
                characterScore += firstCharacterBonus
            } else {
                let previousCharacter = candidateCharacters[foundIndex - 1]
                let currentCharacter = candidateCharacters[foundIndex]
                if boundarySeparators.contains(previousCharacter) {
                    characterScore += boundaryBonus
                } else if previousCharacter.isLowercase, currentCharacter.isUppercase {
                    characterScore += camelCaseBonus
                }
            }

            if foundIndex == previousMatchIndex + 1 {
                consecutiveRun += 1
                characterScore += consecutiveRunBonus * consecutiveRun
            } else {
                consecutiveRun = 0
                if previousMatchIndex >= 0 {
                    let gap = foundIndex - previousMatchIndex - 1
                    characterScore -= gap * gapPenaltyPerSkippedCharacter
                }
            }

            score += characterScore
            indices.append(foundIndex)
            previousMatchIndex = foundIndex
            searchFrom = foundIndex + 1
        }

        // A mild preference for matches that start earlier in the candidate overall,
        // capped so it can never dominate the per-character bonuses above.
        if let first = indices.first {
            score -= min(first * leadingCharacterPenalty, maxLeadingPenalty)
        }

        return Match(score: score, indices: indices)
    }

    /// Scores every candidate against `query` and returns only the ones that matched,
    /// best score first (ties keep the original relative order, via a stable sort on
    /// the original index as a tiebreaker).
    public static func rank(query: String, candidates: [String]) -> [(index: Int, match: Match)] {
        var results: [(index: Int, match: Match)] = []
        results.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            if let match = match(query: query, in: candidate) {
                results.append((index, match))
            }
        }
        results.sort { lhs, rhs in
            if lhs.match.score != rhs.match.score { return lhs.match.score > rhs.match.score }
            return lhs.index < rhs.index
        }
        return results
    }

    private static func firstIndex(of character: Character, in haystack: [Character], from start: Int) -> Int? {
        var i = start
        while i < haystack.count {
            if haystack[i] == character { return i }
            i += 1
        }
        return nil
    }
}
