import Foundation

/// A `major.minor.patch` version, for deciding whether a release is newer than what is
/// running.
///
/// Comparison is numeric per component, never string comparison: `"1.0.10" < "1.0.9"`
/// lexicographically, which would silently stop offering updates after the ninth patch.
public struct AppVersion: Comparable, Equatable, CustomStringConvertible {

    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `1.2.3`, `v1.2.3`, and the short forms `1` and `1.2`. Anything else is nil —
    /// a version that cannot be understood must not be treated as "newer" and offered as an
    /// update, so refusing it is the safe direction to fail.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        // Ignore any pre-release or build suffix (`1.2.3-beta.1`, `1.2.3+7`) for the numeric
        // comparison. Taking the prefix *before* the first separator, not `split().first`:
        // splitting drops leading separators, so "-1.0.0" came back as "1.0.0" and a
        // negative version parsed happily.
        let core: String
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            core = String(text[text.startIndex ..< cut])
        } else {
            core = text
        }
        guard !core.isEmpty else { return nil }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        self.init(major: numbers[0],
                  minor: numbers.count > 1 ? numbers[1] : 0,
                  patch: numbers.count > 2 ? numbers[2] : 0)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}
