import Foundation

final class KeyboardCoordinator {
    let bridgeToken: String

    private var lastDefaultsSignature = ""
    private(set) var commandLifecycle: KeyboardCommandLifecycleSnapshot?

    var latestCommandToken: KeyboardCommandToken? {
        commandLifecycle?.command
    }

    var activeCommandID: String? {
        guard let commandLifecycle, !commandLifecycle.stage.isTerminal else { return nil }
        return commandLifecycle.command.id
    }

    init() {
        self.bridgeToken = Self.loadKeyboardBridgeToken()
        self.commandLifecycle = Self.restorePersistedCommandLifecycle()
    }

    init(bridgeToken: String) {
        self.bridgeToken = bridgeToken
        self.commandLifecycle = Self.restorePersistedCommandLifecycle()
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

    @discardableResult
    func acceptCommand(commandID: String, issuedAt: TimeInterval) -> KeyboardCommandAdmission {
        let incoming = KeyboardCommandToken(id: commandID, issuedAt: issuedAt)
        let admission = KeyboardCommandLifecyclePolicy.admission(
            current: latestCommandToken,
            incoming: incoming
        )
        guard case .accepted = admission else { return admission }
        publishLifecycle(
            KeyboardCommandLifecycleSnapshot(command: incoming, stage: .accepted)
        )
        return admission
    }

    func owns(_ commandID: String) -> Bool {
        activeCommandID == commandID
    }

    @discardableResult
    func transition(
        commandID: String,
        to stage: KeyboardCommandLifecycleStage,
        failureCode: KeyboardCommandFailureCode? = nil,
        recovery: KeyboardCommandRecovery = .none,
        message: String? = nil
    ) -> Bool {
        guard let current = commandLifecycle,
              current.command.id == commandID,
              KeyboardCommandLifecyclePolicy.canTransition(from: current.stage, to: stage)
        else { return false }
        publishLifecycle(
            KeyboardCommandLifecycleSnapshot(
                command: current.command,
                stage: stage,
                failureCode: failureCode,
                recovery: recovery,
                message: message
            )
        )
        return true
    }

    private func publishLifecycle(_ snapshot: KeyboardCommandLifecycleSnapshot) {
        commandLifecycle = snapshot
        let saved = KeyboardSharedDefaults.saveCommandLifecycle(snapshot)
        KeyboardDiagnosticEventLog.record(
            source: "host-app",
            event: "command_lifecycle_published",
            fields: [
                "command_id": snapshot.command.id,
                "stage": snapshot.stage.rawValue,
                "failure_code": snapshot.failureCode?.rawValue ?? "none",
                "recovery": snapshot.recovery.rawValue,
                "saved": "\(saved)",
            ]
        )
        guard saved else { return }
        KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.commandLifecycleChanged)
    }

    private static func loadKeyboardBridgeToken() -> String {
        if let token = KeyboardSharedKeychain.keyboardBridgeToken() {
            return token
        }
        let token = KeyboardSharedDefaults.makeBridgeToken()
        KeyboardSharedKeychain.saveKeyboardBridgeToken(token)
        return token
    }

    private static func restorePersistedCommandLifecycle() -> KeyboardCommandLifecycleSnapshot? {
        guard let persisted = KeyboardSharedDefaults.loadCommandLifecycle() else { return nil }
        guard !persisted.stage.isTerminal else { return persisted }
        let failed = KeyboardCommandLifecycleSnapshot(
            command: persisted.command,
            stage: .failed,
            failureCode: .hostRestarted,
            recovery: .retry,
            message: "Typeforme restarted before the command finished."
        )
        if KeyboardSharedDefaults.saveCommandLifecycle(failed) {
            KeyboardDarwinBridge.post(KeyboardDarwinNotificationName.commandLifecycleChanged)
        }
        return failed
    }
}
