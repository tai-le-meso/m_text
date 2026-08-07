import Foundation
import MTextCore
import MTextTestKit

enum UpdateTests {

    static let suite = TestSuite("Update", [
        ("parses the forms a tag actually takes", testVersionParsing),
        ("rejects anything it cannot understand", testVersionRejects),
        ("compares numerically, not as text", testVersionOrdering),
        ("offers a newer release", testNewerRelease),
        ("says nothing when up to date or ahead", testNotNewer),
        ("ignores drafts and pre-releases", testDraftsAndPrereleases),
        ("picks the universal DMG asset", testAssetSelection),
        ("still reports a release with no usable asset", testMissingAsset),
        ("rejects a malformed payload rather than guessing", testMalformed),
        ("handles the real GitHub payload for this repo", testRealGitHubPayload),
    ])

    // MARK: - Versions

    static func testVersionParsing() {
        expectEqual(AppVersion("1.2.3"), AppVersion(major: 1, minor: 2, patch: 3))
        expectEqual(AppVersion("v1.2.3"), AppVersion(major: 1, minor: 2, patch: 3), "tags carry a v")
        expectEqual(AppVersion("1.2"), AppVersion(major: 1, minor: 2, patch: 0))
        expectEqual(AppVersion("2"), AppVersion(major: 2, minor: 0, patch: 0))
        expectEqual(AppVersion(" 1.0.1 "), AppVersion(major: 1, minor: 0, patch: 1), "trimmed")
        expectEqual(AppVersion("1.2.3-beta.1"), AppVersion(major: 1, minor: 2, patch: 3),
                    "a suffix does not change the numeric version")
    }

    /// Failing to parse must mean "no update", never "unknown, assume newer" — an
    /// unparseable tag that counted as newer would nag forever.
    static func testVersionRejects() {
        expectNil(AppVersion("banana"))
        expectNil(AppVersion(""))
        expectNil(AppVersion("1.2.3.4"), "four components is not a version this app writes")
        expectNil(AppVersion("-1.0.0"))
        expectNil(AppVersion("1.x.0"))
    }

    /// The bug this exists to prevent: string comparison puts 1.0.10 *before* 1.0.9, so
    /// updates would silently stop being offered after the ninth patch release.
    static func testVersionOrdering() {
        expectTrue(AppVersion("1.0.9")! < AppVersion("1.0.10")!, "10 is newer than 9")
        expectTrue(AppVersion("1.9.0")! < AppVersion("1.10.0")!)
        expectTrue(AppVersion("1.0.0")! < AppVersion("2.0.0")!)
        expectTrue(AppVersion("1.0.1")! > AppVersion("1.0.0")!)
        expectEqual(AppVersion("1.0.1"), AppVersion("v1.0.1"))
    }

    // MARK: - Release payloads

    private static func release(tag: String,
                                draft: Bool = false,
                                prerelease: Bool = false,
                                assets: [String] = [UpdateManifest.preferredAssetName]) -> Data {
        let assetJSON = assets.map {
            """
            {"name":"\($0)","browser_download_url":"https://example.test/\($0)"}
            """
        }.joined(separator: ",")
        return Data("""
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),
         "html_url":"https://example.test/releases/\(tag)",
         "body":"what changed","assets":[\(assetJSON)]}
        """.utf8)
    }

    static func testNewerRelease() {
        let update = try! UpdateManifest.update(from: release(tag: "v1.0.2"),
                                                current: AppVersion("1.0.1")!)
        expectFalse(update == nil, "a newer tag is an update")
        expectEqual(update?.version, AppVersion("1.0.2"))
        expectEqual(update?.notes, "what changed")
        expectEqual(update?.releaseURL.absoluteString, "https://example.test/releases/v1.0.2")
    }

    static func testNotNewer() {
        let same = try! UpdateManifest.update(from: release(tag: "v1.0.1"), current: AppVersion("1.0.1")!)
        expectNil(same, "the running version is not an update")
        let older = try! UpdateManifest.update(from: release(tag: "v1.0.0"), current: AppVersion("1.0.1")!)
        expectNil(older, "a local build ahead of the release must not be told to downgrade")
    }

    /// A draft is not published to anyone, and a pre-release is opt-in by nature — neither
    /// should be pushed at someone who just wants the stable app.
    static func testDraftsAndPrereleases() {
        expectNil(try! UpdateManifest.update(from: release(tag: "v2.0.0", draft: true),
                                             current: AppVersion("1.0.1")!))
        expectNil(try! UpdateManifest.update(from: release(tag: "v2.0.0", prerelease: true),
                                             current: AppVersion("1.0.1")!))
    }

    static func testAssetSelection() {
        let data = release(tag: "v1.1.0",
                           assets: ["m_text-1.1.0.dmg", "m_text-1.1.0.dmg.sha256",
                                    UpdateManifest.preferredAssetName])
        let update = try! UpdateManifest.update(from: data, current: AppVersion("1.0.1")!)
        expectEqual(update?.downloadURL?.lastPathComponent, UpdateManifest.preferredAssetName,
                    "the version-less universal DMG, not the checksum or the versioned copy")
    }

    /// Reporting the release without a download is better than staying silent: the user can
    /// still open the page and get it by hand.
    static func testMissingAsset() {
        let update = try! UpdateManifest.update(from: release(tag: "v1.1.0", assets: ["notes.txt"]),
                                                current: AppVersion("1.0.1")!)
        expectFalse(update == nil, "still reported")
        expectNil(update?.downloadURL)
    }

    static func testMalformed() {
        expectThrows { _ = try UpdateManifest.update(from: Data("[]".utf8), current: AppVersion("1.0.0")!) }
        expectThrows { _ = try UpdateManifest.update(from: Data("{}".utf8), current: AppVersion("1.0.0")!) }
        expectThrows {
            _ = try UpdateManifest.update(from: Data(#"{"tag_name":"banana"}"#.utf8),
                                          current: AppVersion("1.0.0")!)
        }
    }

    /// A trimmed copy of what api.github.com actually returned for this repo, field names
    /// and all. The hand-written fixtures above prove the logic; this proves the logic is
    /// pointed at the right *shape* — if GitHub renames a key, this is what fails.
    static func testRealGitHubPayload() {
        let data = Data(#"{"tag_name": "v1.0.1", "draft": false, "prerelease": false, "html_url": "https://github.com/tai-le-meso/m_text/releases/tag/v1.0.1", "assets": [{"name": "m_text-1.0.1.dmg", "browser_download_url": "https://github.com/tai-le-meso/m_text/releases/download/v1.0.1/m_text-1.0.1.dmg"}, {"name": "m_text-1.0.1.dmg.sha256", "browser_download_url": "https://github.com/tai-le-meso/m_text/releases/download/v1.0.1/m_text-1.0.1.dmg.sha256"}, {"name": "m_text-macos-universal.dmg", "browser_download_url": "https://github.com/tai-le-meso/m_text/releases/download/v1.0.1/m_text-macos-universal.dmg"}]}"#.utf8)

        let sameVersion = try! UpdateManifest.update(from: data, current: AppVersion("1.0.1")!)
        expectNil(sameVersion, "running the published version is not an update")

        let older = try! UpdateManifest.update(from: data, current: AppVersion("1.0.0")!)
        expectEqual(older?.version, AppVersion("1.0.1"))
        expectEqual(older?.downloadURL?.lastPathComponent, UpdateManifest.preferredAssetName,
                    "the version-less asset, so the link keeps working next release")
        expectTrue(older?.releaseURL.absoluteString.contains("releases/tag/v1.0.1") == true)
    }
}
