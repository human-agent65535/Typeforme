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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: DictationCoordinator
    let dictionary: UserDictionaryStore
    let settingsWindow: SettingsWindowController
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
    private static let comboHotkeyReleaseWatchdogDelay: UInt64 = 1_500_000_000
    private static let commandTextEditHotkeyReleaseWatchdogDelay: UInt64 = 1_500_000_000
    private static let terminationShutdownDeadline: UInt64 = 4_000_000_000
    private var lastComboHotkeyPressAt: Date?
    private var lastCommandTextEditHotkeyPressAt: Date?
    private static let hotkeyBounceWindow: TimeInterval = 0.35

    override init() {
        AppSettings.registerDefaults()
        try? AppPaths.ensureDirectories()
        let store = UserDictionaryStore()
        self.dictionary     = store
        self.coordinator    = DictationCoordinator(dictionary: store)
        self.settingsWindow = SettingsWindowController(dictionary: store)
        self.bridgeServer   = BridgeHTTPServer(dictionary: store)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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
        holdMonitor.onHoldStart = { [weak self] in self?.handleHoldStart() }
        holdMonitor.onHoldEnd   = { [weak self] in self?.handleHoldEnd() }
        holdMonitor.install(modifier: AppSettings.holdModifier)

        coordinator.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard state == .idle else { return }
                self?.holdMonitor.resetGestureState()
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
            .sink { [weak self] settings in
                if AppSettings.processingMode == .server, settings.enabled {
                    self?.bridgeServer.applySettings()
                } else {
                    self?.bridgeServer.stop()
                }
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

        installEscMonitor()

        if !AppPermissions.accessibilityTrusted {
            Log.app.notice("AX trust not granted; automatic text insertion will fail until granted")
        }
        applyProcessingMode(AppSettings.processingMode)
        syncLaunchAtLogin()
        clientSettingsSync.syncIfNeeded(force: true)
        Log.app.info("Typeforme launched (accessory mode)")
    }

    /// Stops owned ASR and correction helper subprocesses before the system
    /// kills the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        coordinator.shutdown()
        bridgeServer.stop()
        terminationTask?.cancel()
        terminationTask = Task { @MainActor in
            let deadline = Self.terminationShutdownDeadline
            let shutdownTask = Task {
                await ASRFactory.shared.stopQwenLlama()
                await MainActor.run {
                    ASRFactory.shared.stopNvidiaNemotron()
                }
                await CorrectorFactory.shared.shutdownAll()
            }
            let completed = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                group.addTask {
                    await shutdownTask.value
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: deadline)
                    return false
                }
                let result = await group.next() ?? false
                group.cancelAll()
                if !result {
                    shutdownTask.cancel()
                }
                return result
            }
            if !completed {
                Log.app.error("Shutdown timed out; allowing macOS termination")
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridgeServer.stop()
        clientSettingsSync.cancel()
        holdMonitor.uninstall()
        comboHotkeyReleaseWatchdog?.cancel()
        commandTextEditHotkeyReleaseWatchdog?.cancel()
        terminationTask?.cancel()
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        if let m = localEscMonitor { NSEvent.removeMonitor(m); localEscMonitor = nil }
    }

    /// Exposed for the SwiftUI MenuBarMenu's Settings button.
    func openSettings() {
        settingsWindow.show()
    }

    /// Exposed for the menu bar: rescue path when the HUD has been dragged
    /// somewhere unreachable (e.g. onto a display that was unplugged).
    func resetHUDPosition() {
        hud.resetAnchor()
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
            // Mirror toggleDictation's terminal-state handling: a fresh
            // double-tap-hold while the preview / wand toolbar is still on
            // screen must reset and start a new dictation, otherwise the
            // hotkey appears dead and the user has to press Esc first.
            switch coordinator.state {
            case .idle:
                await coordinator.startDictation()
            case .success, .error:
                coordinator.reset()
                await coordinator.startDictation()
            default:
                break
            }
        }
    }

    private func handleHoldEnd() {
        Task { @MainActor in
            if coordinator.state == .recording {
                await coordinator.stopDictation()
            }
        }
    }

    // MARK: - Esc cancel

    private func installEscMonitor() {
        guard escMonitor == nil, localEscMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }  // kVK_Escape
            guard let self else { return }
            Task { @MainActor in
                if self.coordinator.state != .idle {
                    Log.app.debug("Esc — cancelling dictation")
                    await self.coordinator.cancelDictation()
                } else if self.coordinator.canCollapseVoicePreviewHUD {
                    Log.app.debug("Esc — collapsing voice preview HUD")
                    self.coordinator.collapseVoicePreviewHUD()
                }
            }
        }
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // kVK_Escape
            guard let self else { return event }
            Task { @MainActor in
                if self.coordinator.state != .idle {
                    Log.app.debug("Esc — cancelling dictation")
                    await self.coordinator.cancelDictation()
                } else if self.coordinator.canCollapseVoicePreviewHUD {
                    Log.app.debug("Esc — collapsing voice preview HUD")
                    self.coordinator.collapseVoicePreviewHUD()
                }
            }
            return event
        }
    }

    private func preloadRuntimeModels() {
        guard AppSettings.processingMode == .server else {
            Log.app.info("Skipping local model preload in client mode")
            return
        }
        Task { @MainActor in
            async let asrPreload: Void = ASRFactory.shared.preloadCachedActiveModel()
            async let correctionPreload: CorrectorPreloadResult = CorrectorFactory.shared.preloadActiveModels()
            _ = await (asrPreload, correctionPreload)
        }
    }

    private func applyProcessingMode(_ mode: ProcessingMode) {
        switch mode {
        case .server:
            bridgeServer.applySettings()
            preloadRuntimeModels()
        case .client:
            bridgeServer.stop()
            clientSettingsSync.syncIfNeeded(force: true)
            Task { @MainActor in
                await ASRFactory.shared.stopQwenLlama()
                ASRFactory.shared.stopNvidiaNemotron()
                await CorrectorFactory.shared.shutdownAll()
            }
        }
    }
}
