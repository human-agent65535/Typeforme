import AppKit
import Combine

private struct BridgeListenerSettings: Equatable {
    let enabled: Bool
    let lanEnabled: Bool
    let port: Int

    static var current: BridgeListenerSettings {
        BridgeListenerSettings(
            enabled: AppSettings.bridgeEnabled,
            lanEnabled: AppSettings.bridgeLANEnabled,
            port: AppSettings.bridgePort
        )
    }
}

enum AsyncDeadline {
    /// Races an unstructured operation against a deadline. The losing task is
    /// cancelled but deliberately not awaited, so a non-cooperative shutdown
    /// cannot turn a UI deadline into an unbounded structured-concurrency wait.
    static func run(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let operationTask = Task {
            await operation()
        }
        do {
            try await AsyncTaskBarrier.wait(
                for: operationTask,
                timeoutNanoseconds: timeoutNanoseconds
            )
            return true
        } catch {
            operationTask.cancel()
            return false
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: DictationCoordinator
    let dictionary: UserDictionaryStore
    let settingsWindow: SettingsWindowController
    let setupGuideWindow: SetupGuideWindowController
    private let bridgeServer: BridgeHTTPServer
    private let clientSettingsSync = ClientBridgeSettingsSync()
    private var hud: HUDWindowController!
    private let comboHotkey = HotkeyManager()
    private let commandTextEditHotkey = HotkeyManager(name: .commandTextEdit)
    private let holdMonitor = DoubleTapModifierMonitor()
    private var cancellables: Set<AnyCancellable> = []
    private var escMonitor: Any?
    private var localEscMonitor: Any?
    private var comboHotkeyIsDown = false
    private var commandTextEditHotkeyIsDown = false
    private var comboHotkeyReleaseWatchdog: Task<Void, Never>?
    private var commandTextEditHotkeyReleaseWatchdog: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?
    private var runtimeTransitionTask: Task<Void, Never>?
    private var requestedProcessingMode: ProcessingMode?
    private var appliedProcessingMode: ProcessingMode?
    private var applicationIsTerminating = false
    private static let comboHotkeyReleaseWatchdogDelay: UInt64 = 1_500_000_000
    private static let commandTextEditHotkeyReleaseWatchdogDelay: UInt64 = 1_500_000_000
    private static let terminationShutdownDeadline: UInt64 = 6_000_000_000
    private var lastComboHotkeyPressAt: Date?
    private var lastCommandTextEditHotkeyPressAt: Date?
    private static let hotkeyBounceWindow: TimeInterval = 0.35
    private nonisolated static let escapeKeyCode: UInt16 = 53
    private nonisolated static let returnKeyCodes: Set<UInt16> = [36, 76]

    override init() {
        AppSettings.registerDefaults()
        try? AppPaths.ensureDirectories()
        let store = UserDictionaryStore()
        self.dictionary     = store
        self.coordinator    = DictationCoordinator(dictionary: store)
        self.settingsWindow = SettingsWindowController(dictionary: store)
        self.setupGuideWindow = SetupGuideWindowController()
        self.bridgeServer   = BridgeHTTPServer(dictionary: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppActivationPolicy.applyPreferredPolicy()

        hud = HUDWindowController(coordinator: coordinator, onOpenSettings: { [weak self] in
            self?.openSettings()
        })
        // The HUD is always on screen: collapsed to the idle pip when nothing
        // is happening, expanded while dictating.
        hud.show()

        // Combo shortcut → toggle (industry standard for combos). Key-down can
        // repeat while held, so we ignore repeats until key-up. A watchdog
        // clears the latch if macOS drops the key-up during a focus change.
        comboHotkey.onPressed = { [weak self] in self?.handleTogglePress() }
        comboHotkey.onReleased = { [weak self] in self?.handleToggleRelease() }
        comboHotkey.install()

        commandTextEditHotkey.onPressed = { [weak self] in self?.handleCommandTextEditPress() }
        commandTextEditHotkey.onReleased = { [weak self] in self?.handleCommandTextEditRelease() }
        commandTextEditHotkey.install()

        // Double-tap modifier → hold-to-talk
        holdMonitor.onHoldCandidate = { [weak self] in
            self?.coordinator.prepareHoldDictationStart()
        }
        holdMonitor.onHoldStart = { [weak self] in self?.handleHoldStart() }
        holdMonitor.onHoldEnd   = { [weak self] in self?.handleHoldEnd() }
        holdMonitor.onModifierTap = { [weak self] in self?.handleHoldModifierTap() }
        holdMonitor.install(modifier: AppSettings.holdModifier)

        coordinator.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard state == .idle else { return }
                self?.holdMonitor.resetGestureStateIfModifierReleased()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in AppSettings.holdModifier }
            .removeDuplicates()
            .sink { [weak self] modifier in
                self?.holdMonitor.install(modifier: modifier)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in BridgeListenerSettings.current }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.applyBridgeListenerSettings()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in AppSettings.processingMode }
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.applyProcessingMode(mode)
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.clientSettingsSync.syncIfNeeded()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .clientBridgeConfigurationDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.clientSettingsSync.configurationDidChange()
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .setupGuideRequested)
            .sink { [weak self] _ in
                self?.openSetupGuide()
            }
            .store(in: &cancellables)

        installEscMonitor()

        if !AppPermissions.accessibilityTrusted {
            Log.app.notice("AX trust not granted; automatic text insertion will fail until granted")
        }
        applyProcessingMode(AppSettings.processingMode)
        syncLaunchAtLogin()
        clientSettingsSync.syncIfNeeded(force: true)
        showSetupGuideIfNeeded()
        Log.app.info("Typeforme launched (accessory mode)")
    }

    /// Stops owned ASR and correction helper subprocesses before the system
    /// kills the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        applicationIsTerminating = true
        coordinator.prepareForApplicationShutdown()
        let bridgeShutdown = bridgeServer.stop()
        let pendingRuntimeTransition = runtimeTransitionTask
        pendingRuntimeTransition?.cancel()
        terminationTask?.cancel()
        terminationTask = Task { @MainActor in
            let completed = await AsyncDeadline.run(
                timeoutNanoseconds: Self.terminationShutdownDeadline
            ) { @MainActor in
                // The serial mode worker owns any in-progress preload. Join it
                // before tearing down the sessions that use those runtimes.
                await pendingRuntimeTransition?.value
                async let coordinatorShutdown: Void = self.coordinator.shutdown()
                async let bridgeCleanup: Void = bridgeShutdown.value
                _ = await (coordinatorShutdown, bridgeCleanup)
                await self.shutdownRuntimeModels()
            }
            if !completed {
                Log.app.error("Shutdown timed out; allowing macOS termination")
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        applicationIsTerminating = true
        bridgeServer.stop()
        clientSettingsSync.cancel()
        holdMonitor.uninstall()
        comboHotkeyReleaseWatchdog?.cancel()
        commandTextEditHotkeyReleaseWatchdog?.cancel()
        runtimeTransitionTask?.cancel()
        runtimeTransitionTask = nil
        terminationTask?.cancel()
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        if let m = localEscMonitor { NSEvent.removeMonitor(m); localEscMonitor = nil }
    }

    /// Exposed for the SwiftUI MenuBarMenu's Settings button.
    func openSettings() {
        settingsWindow.show()
    }

    func openSetupGuide() {
        setupGuideWindow.show()
    }

    /// Exposed for the menu bar: rescue path when the HUD has been dragged
    /// somewhere unreachable (e.g. onto a display that was unplugged).
    func resetHUDPosition() {
        hud.resetAnchor()
    }

    private func showSetupGuideIfNeeded() {
        guard AppSettings.shouldAutomaticallyShowSetupGuide else { return }
        AppSettings.setSetupGuideHasShown(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.openSetupGuide()
        }
    }

    private func syncLaunchAtLogin() {
        do {
            let status = try LaunchAtLoginController.syncDesiredState()
            Log.app.info("Launch at login synced status=\(status.logValue, privacy: .public)")
        } catch {
            Log.app.error("Launch at login sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Hotkey dispatch

    private func handleTogglePress() {
        if comboHotkeyIsDown {
            Log.hotkey.debug("toggle repeated key-down ignored")
            return
        }
        let now = Date()
        if let lastComboHotkeyPressAt,
           now.timeIntervalSince(lastComboHotkeyPressAt) < Self.hotkeyBounceWindow {
            Log.hotkey.debug("toggle bounced key-down ignored")
            comboHotkeyIsDown = true
            armComboHotkeyReleaseWatchdog()
            return
        }
        lastComboHotkeyPressAt = now
        comboHotkeyIsDown = true
        armComboHotkeyReleaseWatchdog()
        Task { @MainActor in
            await coordinator.toggleDictation()
        }
    }

    private func handleToggleRelease() {
        comboHotkeyIsDown = false
        comboHotkeyReleaseWatchdog?.cancel()
        comboHotkeyReleaseWatchdog = nil
    }

    private func handleCommandTextEditPress() {
        if commandTextEditHotkeyIsDown { return }
        let now = Date()
        if let lastCommandTextEditHotkeyPressAt,
           now.timeIntervalSince(lastCommandTextEditHotkeyPressAt) < Self.hotkeyBounceWindow {
            Log.hotkey.debug("command edit bounced key-down ignored")
            return
        }
        lastCommandTextEditHotkeyPressAt = now
        commandTextEditHotkeyIsDown = true
        armCommandTextEditHotkeyReleaseWatchdog()
        Task { @MainActor in
            await coordinator.toggleCommandTextEdit()
        }
    }

    private func handleCommandTextEditRelease() {
        commandTextEditHotkeyIsDown = false
        commandTextEditHotkeyReleaseWatchdog?.cancel()
        commandTextEditHotkeyReleaseWatchdog = nil
    }

    private func armComboHotkeyReleaseWatchdog() {
        comboHotkeyReleaseWatchdog?.cancel()
        let delay = Self.comboHotkeyReleaseWatchdogDelay
        comboHotkeyReleaseWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.comboHotkeyIsDown else { return }
                self.comboHotkeyIsDown = false
                self.comboHotkeyReleaseWatchdog = nil
                Log.hotkey.debug("toggle key-up watchdog reset")
            }
        }
    }

    private func armCommandTextEditHotkeyReleaseWatchdog() {
        commandTextEditHotkeyReleaseWatchdog?.cancel()
        let delay = Self.commandTextEditHotkeyReleaseWatchdogDelay
        commandTextEditHotkeyReleaseWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.commandTextEditHotkeyIsDown else { return }
                self.commandTextEditHotkeyIsDown = false
                self.commandTextEditHotkeyReleaseWatchdog = nil
                Log.hotkey.debug("command edit key-up watchdog reset")
            }
        }
    }

    private func handleHoldStart() {
        Task { @MainActor in
            guard coordinator.acceptsNewUserOperations else { return }
            await coordinator.startPreparedHoldDictation()
        }
    }

    private func handleHoldEnd() {
        Task { @MainActor in
            // stopDictation records stopAfterStart while recorder startup is
            // still awaiting permissions / device warmup. Filtering on the
            // published state here would lose a quick hold release because the
            // state remains idle until startup completes.
            await coordinator.stopDictation()
        }
    }

    private func handleHoldModifierTap() {
        coordinator.cancelPreparedHoldDictationStart()
        Task { @MainActor in
            guard coordinator.isRecordingCommandTextEdit else { return }
            await coordinator.stopDictation()
        }
    }

    // MARK: - Key command monitor

    private func installEscMonitor() {
        guard escMonitor == nil, localEscMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            guard Self.isMonitoredKeyCode(keyCode) else { return }
            guard let self else { return }
            Task { @MainActor in
                await self.handleMonitoredKeyDown(keyCode)
            }
        }
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            guard Self.isMonitoredKeyCode(keyCode) else { return event }
            guard let self else { return event }
            Task { @MainActor in
                await self.handleMonitoredKeyDown(keyCode)
            }
            return event
        }
    }

    private nonisolated static func isMonitoredKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == escapeKeyCode || returnKeyCodes.contains(keyCode)
    }

    private func handleMonitoredKeyDown(_ keyCode: UInt16) async {
        if keyCode == Self.escapeKeyCode {
            if coordinator.state != .idle {
                Log.app.debug("Esc — cancelling dictation")
                await coordinator.cancelDictation()
            } else if coordinator.canCollapseVoicePreviewHUD {
                Log.app.debug("Esc — collapsing voice preview HUD")
                coordinator.collapseVoicePreviewHUD()
            }
        } else if Self.returnKeyCodes.contains(keyCode) {
            Log.app.debug("Return — dismissing voice preview HUD if expanded")
            coordinator.dismissVoicePreviewHUDFromKeyboard()
        }
    }

    private func preloadRuntimeModels() async {
        await ASRFactory.shared.preloadCachedActiveModel()
        guard !Task.isCancelled else { return }
        _ = await CorrectorFactory.shared.preloadActiveModels()
    }

    private func shutdownRuntimeModels() async {
        async let qwenShutdown: Void = ASRFactory.shared.stopQwenLlama()
        async let nvidiaShutdown: Void = ASRFactory.shared.stopNvidiaNemotron()
        async let correctorShutdown: Void = CorrectorFactory.shared.shutdownAll()
        async let aiWritingShutdown: Void = AIWritingDecoderService.shared.shutdown()
        _ = await (qwenShutdown, nvidiaShutdown, correctorShutdown, aiWritingShutdown)
    }

    private func applyProcessingMode(_ mode: ProcessingMode) {
        guard !applicationIsTerminating,
              requestedProcessingMode != mode || appliedProcessingMode != mode
        else { return }

        let isInitialMode = requestedProcessingMode == nil && appliedProcessingMode == nil
        requestedProcessingMode = mode
        if !isInitialMode {
            // Closing admission is synchronous. The single worker below then
            // cancels the current operation and moves runtimes in one order.
            coordinator.beginRuntimeTransition()
        }
        guard runtimeTransitionTask == nil else { return }

        runtimeTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runProcessingModeTransitions()
        }
    }

    private func runProcessingModeTransitions() async {
        while !Task.isCancelled,
              let mode = requestedProcessingMode,
              mode != appliedProcessingMode {
            if coordinator.requiresRuntimeDiscard {
                await coordinator.cancelDictation()
            }
            guard !Task.isCancelled else { break }
            guard await transitionProcessingMode(to: mode) else { break }
            appliedProcessingMode = mode
        }

        runtimeTransitionTask = nil
        if !applicationIsTerminating,
           requestedProcessingMode == appliedProcessingMode {
            coordinator.endRuntimeTransition()
        }
    }

    private func transitionProcessingMode(to mode: ProcessingMode) async -> Bool {
        switch mode {
        case .server:
            clientSettingsSync.cancel()
            // Health, pairing, and settings stay available while local models
            // warm. Real mode changes have already quiesced dictation above.
            bridgeServer.applySettings()
            await preloadRuntimeModels()
            guard !Task.isCancelled else { return false }

        case .client:
            let bridgeShutdown = bridgeServer.stop()
            clientSettingsSync.syncIfNeeded(force: true)
            // Bridge previews own ASR leases, so listener cleanup precedes the
            // shared runtime shutdown.
            await bridgeShutdown.value
            guard !Task.isCancelled else { return false }
            await shutdownRuntimeModels()
        }
        return !Task.isCancelled
    }

    private func applyBridgeListenerSettings() {
        if AppSettings.processingMode == .server,
           requestedProcessingMode == .server {
            bridgeServer.applySettings()
        } else {
            bridgeServer.stop()
        }
    }
}
