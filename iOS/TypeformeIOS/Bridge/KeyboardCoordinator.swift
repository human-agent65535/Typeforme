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
        chineseInputEnabled: Bool,
        chinesePunctuationStyle: KeyboardChinesePunctuationStyle,
        rimeDictionaryTier: KeyboardRimeDictionaryTier,
        rimeCorrectionEnabled: Bool,
        rimeUserPhrases: [String],
        defaultTextInputLanguage: KeyboardDefaultTextInputLanguage,
        rimeLearningResetGeneration: Int,
        touchLearningResetGeneration: Int,
        force: Bool = false
    ) {
        var payload = KeyboardDefaultsPayload(
            bridgeToken: bridgeToken,
            correctionMode: correctionMode,
            autoCapitalizationEnabled: autoCapitalizationEnabled,
            characterPreviewEnabled: characterPreviewEnabled,
            chineseInputEnabled: chineseInputEnabled,
            chinesePunctuationStyle: chinesePunctuationStyle,
            rimeDictionaryTier: rimeDictionaryTier,
            rimeCorrectionEnabled: rimeCorrectionEnabled,
            rimeUserPhrases: rimeUserPhrases,
            defaultTextInputLanguage: defaultTextInputLanguage,
            rimeLearningResetGeneration: rimeLearningResetGeneration,
            touchLearningResetGeneration: touchLearningResetGeneration,
            updatedAt: 0
        )
        let signature = payload.stableSignature
        guard force || signature != lastDefaultsSignature else { return }
        lastDefaultsSignature = signature

        payload.updatedAt = Date().timeIntervalSince1970
        guard KeyboardSharedDefaults.savePayload(payload) else { return }
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.keyboardDefaultsChanged)
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
