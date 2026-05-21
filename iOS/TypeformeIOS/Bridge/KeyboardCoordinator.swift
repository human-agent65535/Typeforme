import Foundation

final class KeyboardCoordinator {
    let bridgeToken: String

    private static let legacyKeyboardBridgeTokenKey = "keyboard.bridgeToken"
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
        force: Bool = false
    ) {
        let stablePayload: [String: Any] = [
            "version": 1,
            "bridge_token": bridgeToken,
            "correction_mode": correctionMode.rawValue,
            "auto_capitalization_enabled": autoCapitalizationEnabled,
            "character_preview_enabled": characterPreviewEnabled,
            "chinese_punctuation_style": chinesePunctuationStyle.rawValue,
        ]
        let signature = stableKeyboardDefaultsSignature(stablePayload)
        guard force || signature != lastDefaultsSignature else { return }
        lastDefaultsSignature = signature

        var payload = stablePayload
        payload["updated_at"] = Date().timeIntervalSince1970
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let text = String(data: data, encoding: .utf8),
              let defaults = KeyboardSharedDefaults.suite()
        else { return }
        defaults.set(text, forKey: KeyboardSharedDefaults.keyboardDefaultsKey)
        defaults.synchronize()
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

    private static func loadKeyboardBridgeToken() -> String {
        let store = PairingTokenStore.keyboardBridge
        if let token = store.load(),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: legacyKeyboardBridgeTokenKey)
            return token
        }
        let token = "\(UUID().uuidString).\(UUID().uuidString)"
        store.save(token)
        UserDefaults.standard.removeObject(forKey: legacyKeyboardBridgeTokenKey)
        return token
    }
}
