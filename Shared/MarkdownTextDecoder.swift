import Foundation

enum MarkdownTextDecoder {
    static let maximumBytes = MarkdownRenderer.maximumSourceBytes

    static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumBytes else {
            throw CocoaError(.fileReadTooLarge)
        }

        if let value = String(data: data, encoding: .utf8),
           let safeValue = validatedText(value) {
            return safeValue
        }

        let encoding: String.Encoding?
        if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
        } else {
            encoding = nil
        }
        if let encoding,
           let value = String(data: data, encoding: encoding) {
            let withoutBOM = value.first == "\u{FEFF}" ? String(value.dropFirst()) : value
            if let safeValue = validatedText(withoutBOM) {
                return safeValue
            }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    /// Accept isolated controls from pasted terminal output while continuing to
    /// reject NULs and control-heavy byte streams that only happen to decode.
    private static func validatedText(_ value: String) -> String? {
        var ordinaryScalarCount = 0
        var unsafeControlCount = 0

        for scalar in value.unicodeScalars {
            if scalar.value == 0 { return nil }
            if MarkdownTextSafety.isUnsafeControl(scalar) {
                unsafeControlCount += 1
            } else {
                ordinaryScalarCount += 1
            }
        }

        guard unsafeControlCount == 0
                || (ordinaryScalarCount > 0
                    && unsafeControlCount <= max(1, ordinaryScalarCount / 4)) else {
            return nil
        }
        return MarkdownTextSafety.sanitizedForDisplay(value)
    }
}

/// Converts controls that have meaning to terminals or parsers into inert,
/// visible Unicode. Tabs and line endings remain intact for Markdown layout.
enum MarkdownTextSafety {
    static func isUnsafeControl(_ scalar: UnicodeScalar) -> Bool {
        let codePoint = scalar.value
        return (codePoint < 0x20 && codePoint != 0x09 && codePoint != 0x0A && codePoint != 0x0D)
            || (0x7F...0x9F).contains(codePoint)
    }

    static func sanitizedForDisplay(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: isUnsafeControl) else { return value }

        var result = ""
        result.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            guard isUnsafeControl(scalar) else {
                result.unicodeScalars.append(scalar)
                continue
            }

            switch scalar.value {
            case 0x00...0x1F:
                result.unicodeScalars.append(UnicodeScalar(0x2400 + scalar.value)!)
            case 0x7F:
                result.unicodeScalars.append("\u{2421}")
            default:
                result.unicodeScalars.append("\u{FFFD}")
            }
        }
        return result
    }
}
