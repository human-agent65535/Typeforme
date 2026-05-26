import CryptoKit
import Foundation

final class KeyboardCoordinator {
    let bridgeToken: String

    private var lastDefaultsSignature = ""

    init() {
        self.bridgeToken = Self.loadKeyboardBridgeToken()
    }

    init(bridgeToken: String) {
        self.bridgeToken = bridgeToken
    }

    func publishDefaults(
        correctionMode: CorrectionModeID,
        autoCapitalizationEnabled: Bool,
        characterPreviewEnabled: Bool,
        chinesePunctuationStyle: KeyboardChinesePunctuationStyle,
        rimeDictionaryTier: KeyboardRimeDictionaryTier,
        rimeUserPhrases: [String],
        defaultTextInputLanguage: KeyboardDefaultTextInputLanguage,
        rimeLearningResetGeneration: Int,
        touchLearningResetGeneration: Int,
        force: Bool = false
    ) {
        let normalizedRimeUserPhrases = Self.normalizedRimeUserPhrases(rimeUserPhrases)
        let stablePayload: [String: Any] = [
            "version": 1,
            "bridge_token": bridgeToken,
            "correction_mode": correctionMode.rawValue,
            "auto_capitalization_enabled": autoCapitalizationEnabled,
            "character_preview_enabled": characterPreviewEnabled,
            "chinese_punctuation_style": chinesePunctuationStyle.rawValue,
            "rime_dictionary_tier": rimeDictionaryTier.rawValue,
            "rime_user_phrases": normalizedRimeUserPhrases,
            "rime_user_phrases_revision": rimeUserPhrasesRevision(normalizedRimeUserPhrases),
            "default_text_input_language": defaultTextInputLanguage.rawValue,
            "rime_learning_reset_generation": rimeLearningResetGeneration,
            "touch_learning_reset_generation": touchLearningResetGeneration,
        ]
        let signature = stableKeyboardDefaultsSignature(stablePayload)
        guard force || signature != lastDefaultsSignature else { return }
        lastDefaultsSignature = signature

        var payload = stablePayload
        payload["updated_at"] = Date().timeIntervalSince1970
        guard KeyboardSharedDefaults.savePayload(payload) else { return }
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.keyboardDefaultsChanged)
    }

    private func stableKeyboardDefaultsSignature(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return UUID().uuidString
        }
        return text
    }

    private func rimeUserPhrasesRevision(_ phrases: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: phrases, options: [.sortedKeys]) else {
            return ""
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedRimeUserPhrases(_ phrases: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for phrase in phrases {
            let cleaned = phrase
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            guard seen.insert(key).inserted else { continue }
            output.append(cleaned)
        }
        return output.sorted()
    }

    private static func loadKeyboardBridgeToken() -> String {
        let store = PairingTokenStore.keyboardBridge
        if let sharedToken = KeyboardSharedDefaults.bridgeToken(from: KeyboardSharedDefaults.loadPayload()) {
            store.save(sharedToken)
            return sharedToken
        }
        if let token = store.load(),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return token
        }
        let token = KeyboardSharedDefaults.makeBridgeToken()
        store.save(token)
        return token
    }
}
