import AppKit
import SwiftUI

@MainActor
final class SetupGuideWindowController: NSObject, NSWindowDelegate {
    private let modelDownloads = ModelDownloadRegistry()
    private var window: NSWindow!

    override init() {
        super.init()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Typeforme Setup Guide"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 500)
        window.maxSize = NSSize(width: 880, height: 640)
        window.center()
        window.setFrameAutosaveName("TypeformeSetupGuideWizardWindow.v2")

        let root = SetupGuideWizardView(onClose: { [weak self] in
            self?.close()
        })
        .environmentObject(modelDownloads)

        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        window.delegate = self
    }

    func show() {
        AppActivationPolicy.showDocumentWindow()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            AppActivationPolicy.restoreAccessoryIfNoDocumentWindows(excluding: window)
        }
    }
}
