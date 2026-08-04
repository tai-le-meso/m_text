import Foundation

public enum TextEncodingKind: String, CaseIterable {
    case utf8
    case utf8BOM
    case utf16LE
    case utf16BE
    case isoLatin1

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 with BOM"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .isoLatin1: return "Western (ISO Latin 1)"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .isoLatin1: return .isoLatin1
        }
    }
}

public enum LineEnding: String, CaseIterable {
    case lf   // \n   — Unix
    case crlf // \r\n — Windows
    case cr   // \r   — classic Mac

    public var displayName: String {
        switch self {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }

    var string: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

public enum TextEncodingDetector {

    /// Detects encoding from BOM, then UTF-8 validity, falling back to Latin-1
    /// (which can decode any byte sequence, so decoding never fails).
    public static func detect(_ bytes: [UInt8]) -> TextEncodingKind {
        // 4-byte BOMs must be tested before the 2-byte ones they start with:
        // UTF-32LE (FF FE 00 00) otherwise looks like UTF-16LE.
        if bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xFE, bytes[2] == 0x00, bytes[3] == 0x00 {
            return .isoLatin1 // UTF-32 unsupported; read losslessly rather than mangle it
        }
        if bytes.count >= 4, bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0xFE, bytes[3] == 0xFF {
            return .isoLatin1
        }
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { return .utf8BOM }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { return .utf16LE }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { return .utf16BE }
        if isValidUTF8(bytes) { return .utf8 }
        return .isoLatin1
    }

    public static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            var following = 0
            if b < 0x80 {
                i += 1
                continue
            } else if b & 0xE0 == 0xC0 {
                if b < 0xC2 { return false } // overlong
                following = 1
            } else if b & 0xF0 == 0xE0 {
                if i + 1 >= n { return false }
                let b1 = bytes[i + 1]
                if b == 0xE0 && b1 < 0xA0 { return false } // overlong
                if b == 0xED && b1 > 0x9F { return false } // UTF-16 surrogate half
                following = 2
            } else if b & 0xF8 == 0xF0 {
                if b > 0xF4 { return false } // beyond U+10FFFF
                if i + 1 >= n { return false }
                let b1 = bytes[i + 1]
                if b == 0xF0 && b1 < 0x90 { return false } // overlong
                if b == 0xF4 && b1 > 0x8F { return false } // beyond U+10FFFF
                following = 3
            } else {
                return false
            }
            if i + following >= n { return false }
            for k in 1 ... following where bytes[i + k] & 0xC0 != 0x80 { return false }
            i += following + 1
        }
        return true
    }

    /// Decodes to a String and normalises all line endings to `\n`, reporting
    /// which convention dominated so saving can restore it.
    public static func decode(_ bytes: [UInt8], encoding: TextEncodingKind) -> (text: String, lineEnding: LineEnding) {
        var payload = bytes
        switch encoding {
        case .utf8BOM: payload.removeFirst(min(3, payload.count))
        case .utf16LE, .utf16BE: payload.removeFirst(min(2, payload.count))
        default: break
        }

        // Latin-1 can decode any byte sequence, so a failed decode degrades to a
        // lossless read rather than sprinkling U+FFFD through the user's file.
        let raw = String(data: Data(payload), encoding: encoding.stringEncoding)
            ?? String(data: Data(payload), encoding: .isoLatin1)
            ?? ""

        let lineEnding = detectLineEnding(raw)
        var normalised = raw
        // Byte-level check: "\r\n" is a single Character, so contains("\r") is false
        // for a CRLF document.
        if lineEnding != .lf || raw.utf8.contains(0x0D) {
            normalised = raw.replacingOccurrences(of: "\r\n", with: "\n")
                            .replacingOccurrences(of: "\r", with: "\n")
        }
        return (normalised, lineEnding)
    }

    public static func detectLineEnding(_ text: String) -> LineEnding {
        var crlf = 0, lf = 0, cr = 0
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\r" {
                if previousWasCR { cr += 1 }
                previousWasCR = true
            } else if scalar == "\n" {
                if previousWasCR { crlf += 1; previousWasCR = false } else { lf += 1 }
            } else {
                if previousWasCR { cr += 1 }
                previousWasCR = false
            }
        }
        if previousWasCR { cr += 1 }
        if crlf >= lf && crlf >= cr && crlf > 0 { return .crlf }
        if cr > lf && cr > 0 { return .cr }
        return .lf
    }

    /// Encodes a `\n`-normalised string back to bytes in the target encoding and
    /// line-ending convention.
    public static func encode(_ text: String, encoding: TextEncodingKind, lineEnding: LineEnding) -> Data {
        let denormalised = lineEnding == .lf
            ? text
            : text.replacingOccurrences(of: "\n", with: lineEnding.string)

        var data = denormalised.data(using: encoding.stringEncoding, allowLossyConversion: true) ?? Data()
        switch encoding {
        case .utf8BOM: data = Data([0xEF, 0xBB, 0xBF]) + data
        case .utf16LE: data = Data([0xFF, 0xFE]) + data
        case .utf16BE: data = Data([0xFE, 0xFF]) + data
        default: break
        }
        return data
    }
}
