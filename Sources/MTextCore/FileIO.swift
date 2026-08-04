import Foundation

public struct LoadedFile {
    public let text: String
    public let encoding: TextEncodingKind
    public let lineEnding: LineEnding
    public let modificationDate: Date?
}

public enum FileIO {

    public static func load(_ url: URL) throws -> LoadedFile {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let bytes = [UInt8](data)
        let encoding = TextEncodingDetector.detect(bytes)
        let decoded = TextEncodingDetector.decode(bytes, encoding: encoding)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return LoadedFile(text: decoded.text,
                          encoding: encoding,
                          lineEnding: decoded.lineEnding,
                          modificationDate: attrs?[.modificationDate] as? Date)
    }

    /// Atomic save: writes a sibling temp file, flushes it to disk, then swaps it in,
    /// preserving the original's POSIX permissions. (Extended attributes and resource
    /// forks are not yet carried over — see TASKS.md T15.)
    @discardableResult
    public static func save(text: String,
                            to url: URL,
                            encoding: TextEncodingKind,
                            lineEnding: LineEnding) throws -> Date? {
        let data = TextEncodingDetector.encode(text, encoding: encoding, lineEnding: lineEnding)
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        let existingAttributes = try? fm.attributesOfItem(atPath: url.path)

        let temp = directory.appendingPathComponent(".m_text-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .atomic)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        // Force the bytes out before the swap, so a crash can't leave a truncated file.
        // A failure here (e.g. disk full) must fail the save, not silently produce
        // a short file, so it is not swallowed.
        let handle = try FileHandle(forWritingTo: temp)
        try handle.synchronize()
        try handle.close()

        if let permissions = existingAttributes?[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        }

        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: temp, to: url)
        }

        // replaceItemAt removes the temp file on success; clean up defensively.
        if fm.fileExists(atPath: temp.path) { try? fm.removeItem(at: temp) }

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }
}
