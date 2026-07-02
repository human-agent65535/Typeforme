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
        correctionMode: CorrectionMode,
        autoCapitalizationEnabled: Bool,
        characterPreviewEnabled: Bool,
        keySoundEnabled: Bool,
        keyHapticsEnabled: Bool,
        chineseInputEnabled: Bool,
        chinesePunctuationStyle: KeyboardChinesePunctuationStyle,
        rimeDictionaryTier: KeyboardRimeDictionaryTier,
        rimeLearningEnabled: Bool,
        rimeCorrectionEnabled: Bool,
        touchLearningEnabled: Bool,
        rimeUserPhrases: [String],
        defaultTextInputLanguage: KeyboardDefaultTextInputLanguage,
        rimeLearningResetGeneration: Int,
        touchLearningResetGeneration: Int,
        force: Bool = false
    ) {
        KeyboardSharedKeychain.saveKeyboardBridgeToken(bridgeToken)
        var payload = KeyboardDefaultsPayload(
            correctionMode: correctionMode,
            autoCapitalizationEnabled: autoCapitalizationEnabled,
            characterPreviewEnabled: characterPreviewEnabled,
            keySoundEnabled: keySoundEnabled,
            keyHapticsEnabled: keyHapticsEnabled,
            chineseInputEnabled: chineseInputEnabled,
            chinesePunctuationStyle: chinesePunctuationStyle,
            rimeDictionaryTier: rimeDictionaryTier,
            rimeLearningEnabled: rimeLearningEnabled,
            rimeCorrectionEnabled: rimeCorrectionEnabled,
            touchLearningEnabled: touchLearningEnabled,
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
        if let token = KeyboardSharedKeychain.keyboardBridgeToken() {
            return token
        }
        let token = KeyboardSharedDefaults.makeBridgeToken()
        KeyboardSharedKeychain.saveKeyboardBridgeToken(token)
        return token
    }
}
