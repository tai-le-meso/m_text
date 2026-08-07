import AppKit
import MTextCore

/// Checks GitHub for a newer release — the **only** network code in this app.
///
/// The project's rule was "100% offline, no network code anywhere". That is now "offline by
/// default": nothing here runs unless the user either turns on automatic checks in Settings
/// or picks *Check for Updates…* by hand. A manual check is an explicit request, so it works
/// even with automatic checking off; nothing else in the app ever opens a socket.
///
/// This phase only ever *tells* you about an update and opens the download in your browser.
/// It does not download, verify or install anything — that needs a trust anchor these builds
/// do not have yet (ad-hoc signed, no Developer ID), and is deliberately a separate step.
public final class UpdateChecker {

    public static let shared = UpdateChecker()

    /// Where releases are published. Not user-configurable on purpose: a settable update
    /// endpoint is a way to point the app at someone else's build.
    static let endpoint = URL(string:
        "https://api.github.com/repos/tai-le-meso/m_text/releases/latest")!

    private static let lastCheckKey = "MTextLastUpdateCheck"
    private static let skippedVersionKey = "MTextSkippedUpdateVersion"

    /// How often an automatic check may run. A daily check is plenty for an editor and stays
    /// far inside GitHub's unauthenticated rate limit.
    static let automaticInterval: TimeInterval = 60 * 60 * 24

    public enum CheckError: LocalizedError {
        case network(String)
        case badStatus(Int)

        public var errorDescription: String? {
            switch self {
            case .network(let why): return "Could not reach the update server. \(why)"
            case .badStatus(let code): return "The update server replied with HTTP \(code)."
            }
        }
    }

    /// The running app's version, from its own bundle.
    public var currentVersion: AppVersion {
        let string = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.0.0"
        return AppVersion(string) ?? AppVersion(major: 0, minor: 0, patch: 0)
    }

    // MARK: - Checking

    /// Fetches and parses, calling back on the main queue. Does no UI.
    public func check(completion: @escaping (Result<AvailableUpdate?, Error>) -> Void) {
        var request = URLRequest(url: UpdateChecker.endpoint)
        request.timeoutInterval = 15
        // GitHub asks for an explicit Accept and a User-Agent; without the latter it replies
        // 403 rather than JSON.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("m_text/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let current = currentVersion
        URLSession.shared.dataTask(with: request) { data, response, error in
            let finish: (Result<AvailableUpdate?, Error>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let error {
                finish(.failure(CheckError.network(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                finish(.failure(CheckError.badStatus(http.statusCode)))
                return
            }
            guard let data else {
                finish(.failure(CheckError.network("The server sent no data.")))
                return
            }
            do {
                finish(.success(try UpdateManifest.update(from: data, current: current)))
            } catch {
                finish(.failure(error))
            }
        }.resume()
    }

    // MARK: - Automatic checks

    /// Runs a check only if the user asked for one and one is not due yet.
    ///
    /// Silent about everything except an actual update: a background check that cannot reach
    /// the network is not something to interrupt anyone about.
    public func checkAutomaticallyIfDue(settingEnabled: Bool,
                                        present: @escaping (AvailableUpdate) -> Void) {
        guard settingEnabled, isAutomaticCheckDue else { return }
        recordCheck()
        check { [weak self] result in
            guard case .success(let update) = result, let update else { return }
            guard self?.isSkipped(update.version) == false else { return }
            present(update)
        }
    }

    var isAutomaticCheckDue: Bool {
        let last = UserDefaults.standard.double(forKey: UpdateChecker.lastCheckKey)
        guard last > 0 else { return true }
        return Date().timeIntervalSince1970 - last >= UpdateChecker.automaticInterval
    }

    func recordCheck() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: UpdateChecker.lastCheckKey)
    }

    // MARK: - Skipping

    public func skip(_ version: AppVersion) {
        UserDefaults.standard.set(version.description, forKey: UpdateChecker.skippedVersionKey)
    }

    /// Only the exact skipped version is suppressed — a later release still gets offered, so
    /// "skip" cannot silently turn into "never tell me again".
    public func isSkipped(_ version: AppVersion) -> Bool {
        guard let raw = UserDefaults.standard.string(forKey: UpdateChecker.skippedVersionKey),
              let skipped = AppVersion(raw) else { return false }
        return skipped == version
    }

    public func clearSkipped() {
        UserDefaults.standard.removeObject(forKey: UpdateChecker.skippedVersionKey)
    }
}
