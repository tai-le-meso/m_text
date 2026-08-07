import Foundation

/// A release newer than what is running.
public struct AvailableUpdate: Equatable {
    public let version: AppVersion
    /// The release page — what "Release Notes" opens.
    public let releaseURL: URL
    /// The universal DMG, when the release published one. Optional because a release without
    /// a usable asset should still be *reported*; it just cannot be downloaded directly.
    public let downloadURL: URL?
    public let notes: String

    public init(version: AppVersion, releaseURL: URL, downloadURL: URL?, notes: String) {
        self.version = version
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
        self.notes = notes
    }
}

/// Reads GitHub's "latest release" JSON.
///
/// Parsing lives here, apart from the networking, so the interesting decisions — is this
/// newer, is it a draft, which asset is the DMG — are unit tested against real payload
/// shapes instead of needing a server.
public enum UpdateManifest {

    public enum ParseError: Error, Equatable {
        case notAnObject
        case noTag
        case unreadableVersion(String)
    }

    /// The asset the updater wants: the version-less universal DMG the release workflow
    /// publishes alongside the versioned one.
    public static let preferredAssetName = "m_text-macos-universal.dmg"

    /// `nil` when the release is not newer than `current` — including when it is *older*,
    /// which happens if someone runs a build newer than the published release.
    ///
    /// Drafts and pre-releases are ignored: a draft is not published for anyone, and a
    /// pre-release is opt-in by nature and should not be pushed at people who did not ask.
    public static func update(from data: Data, current: AppVersion) throws -> AvailableUpdate? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notAnObject
        }
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true {
            return nil
        }
        guard let tag = object["tag_name"] as? String else { throw ParseError.noTag }
        guard let version = AppVersion(tag) else { throw ParseError.unreadableVersion(tag) }
        guard version > current else { return nil }

        let assets = object["assets"] as? [[String: Any]] ?? []
        let download = assets
            .first { ($0["name"] as? String) == preferredAssetName }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))

        let releaseURL = (object["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/tai-le-meso/m_text/releases/latest")!

        return AvailableUpdate(version: version,
                               releaseURL: releaseURL,
                               downloadURL: download,
                               notes: (object["body"] as? String) ?? "")
    }
}
