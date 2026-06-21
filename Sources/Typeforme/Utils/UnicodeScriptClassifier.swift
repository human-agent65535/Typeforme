import Foundation

enum UnicodeScriptClassifier {
    static func containsHanBMP(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHanBMP)
    }

    static func hanBMPCount(in text: String) -> Int {
        text.unicodeScalars.reduce(0) { count, scalar in
            isHanBMP(scalar) ? count + 1 : count
        }
    }

    static func containsHanBMPOrExtensionA(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHanBMPOrExtensionA)
    }

    static func containsHanCore(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHanCore)
    }

    static func containsEastAsianScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            isHanBMPOrExtensionA(scalar) || isKanaBasic(scalar) || isHangulSyllable(scalar)
        }
    }

    static func isHanBMP(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value))
    }

    static func isHanBMPOrExtensionA(_ scalar: Unicode.Scalar) -> Bool {
        let value = Int(scalar.value)
        return (0x4E00...0x9FFF).contains(value) ||
            (0x3400...0x4DBF).contains(value)
    }

    static func isHanCore(_ scalar: Unicode.Scalar) -> Bool {
        let value = Int(scalar.value)
        return (0x4E00...0x9FFF).contains(value) ||
            (0x3400...0x4DBF).contains(value) ||
            (0x20000...0x2A6DF).contains(value)
    }

    static func isHanBroad(_ scalar: Unicode.Scalar) -> Bool {
        let value = Int(scalar.value)
        return (0x3400...0x4DBF).contains(value) ||
            (0x4E00...0x9FFF).contains(value) ||
            (0xF900...0xFAFF).contains(value) ||
            (0x20000...0x2A6DF).contains(value) ||
            (0x2A700...0x2B73F).contains(value) ||
            (0x2B740...0x2B81F).contains(value) ||
            (0x2B820...0x2CEAF).contains(value)
    }

    static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        let value = Int(scalar.value)
        return (0x3040...0x309F).contains(value) ||
            (0x30A0...0x30FF).contains(value) ||
            (0x31F0...0x31FF).contains(value)
    }

    static func containsASCIILatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isASCIILatinLetter)
    }

    static func containsLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isLatinLetter)
    }

    static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        let value = Int(scalar.value)
        return (0x41...0x5A).contains(value) ||
            (0x61...0x7A).contains(value) ||
            (0x00C0...0x024F).contains(value)
    }

    static func containsLatinDiacritic(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x00C0...0x024F).contains(Int(scalar.value))
        }
    }

    private static func isASCIILatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        let value = Int(scalar.value)
        return (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }

    private static func isKanaBasic(_ scalar: Unicode.Scalar) -> Bool {
        let value = Int(scalar.value)
        return (0x3040...0x30FF).contains(value)
    }

    private static func isHangulSyllable(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7AF).contains(Int(scalar.value))
    }
}
