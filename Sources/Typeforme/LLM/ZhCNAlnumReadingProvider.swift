import Foundation

enum ZhCNAlnumReadingProvider {
    static func pinyinSyllableOptions(for character: Character) -> [[String]] {
        guard let key = String(character).lowercased().first else {
            return [[String(character)]]
        }
        return pinyinOptions[key] ?? [[String(character)]]
    }

    private static let pinyinOptions: [Character: [[String]]] = [
        "a": [["ei"]],
        "b": [["bi"]],
        "c": [["xi"], ["si"]],
        "d": [["di"]],
        "e": [["yi"]],
        "f": [["ai", "fu"], ["fu"]],
        "g": [["ji"]],
        "h": [["ai", "chi"], ["chi"]],
        "i": [["ai"]],
        "j": [["jie"]],
        "k": [["kei"]],
        "l": [["ai", "er"], ["er"]],
        "m": [["ai", "mu"], ["mu"]],
        "n": [["en"]],
        "o": [["ou"]],
        "p": [["pi"]],
        "q": [["qiu"]],
        "r": [["a", "er"], ["er"]],
        "s": [["ai", "si"], ["si"]],
        "t": [["ti"]],
        "u": [["you"]],
        "v": [["wei"]],
        "w": [["da", "bu", "liu"]],
        "x": [["ai", "ke", "si"], ["ke", "si"]],
        "y": [["wai"]],
        "z": [["zi"]],
        "0": [["ling"]],
        "1": [["wan"]],
        "2": [["tu"]],
        "3": [["si", "rui"]],
        "4": [["fo"]],
        "5": [["fai", "fu"], ["fu"]],
        "6": [["si", "ke", "si"]],
        "7": [["sai", "wen"]],
        "8": [["ei", "te"]],
        "9": [["nai"]],
    ]
}
