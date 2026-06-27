import SwiftUI
import AppKit
import ServiceManagement

// Shared container so AppDelegate can access SwiftUI StateObjects
class AppState {
    static let shared = AppState()
    var recorder: RecorderManager?
    var settings: AppSettings?
    var hotkeyManager: HotkeyManager?
}

@main
struct VoiceToTextApp: App {
    @StateObject private var recorder = RecorderManager()
    @StateObject private var settings = AppSettings()
    @StateObject private var hotkeyManager = HotkeyManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppState.shared.recorder = recorder
        AppState.shared.settings = settings
        AppState.shared.hotkeyManager = hotkeyManager
        recorder.settings = settings
        hotkeyManager.configure(settings: settings)
        SoundManager.shared.setVolume(Float(settings.soundVolume))
    }

    var body: some Scene {
        MenuBarExtra {
            menuContent
        } label: {
            MenuBarIcon(state: recorder.state)
        }
        .menuBarExtraStyle(.menu)
    }

    @ViewBuilder
    private var menuContent: some View {
        Text(recorder.statusDescription)
            .font(.headline)

        Divider()

        Button(recorder.toggleButtonLabel) {
            recorder.toggle()
        }
        .disabled(recorder.state == .transcribing || !settings.isSetupComplete)

        Button("Show Window") {
            StatusWindowController.shared.showWindow()
        }

        Button("Settings\u{2026}") {
            SettingsWindowController.shared.showWindow()
        }

        Menu("Output Style: \(settings.postprocessModeLabel)") {
            ForEach(settings.availablePostprocessModes, id: \.id) { mode in
                Button(mode.label) {
                    settings.postprocessMode = mode.id
                    settings.save()
                }
            }
        }

        if !settings.isSetupComplete {
            Text("Run build.sh --install to set up the Python environment.")
                .font(.caption2)
                .foregroundColor(.orange)
        }

        if !recorder.isWhisperServerReady && settings.isSetupComplete {
            Text("Whisper server: starting…")
                .font(.caption2)
                .foregroundColor(.secondary)
        }

        Divider()

        Text("\(hotkeyManager.primaryHotkeyLabel): \(hotkeyManager.primaryRegistered ? "Registered" : hotkeyManager.primaryError.isEmpty ? "Not registered" : hotkeyManager.primaryError)")
            .font(.caption)
            .foregroundColor(hotkeyManager.primaryRegistered ? .secondary : .red)

        Text("\(hotkeyManager.secondaryHotkeyLabel): \(hotkeyManager.secondaryRegistered ? "Registered" : hotkeyManager.secondaryError.isEmpty ? "Not registered" : hotkeyManager.secondaryError)")
            .font(.caption)
            .foregroundColor(hotkeyManager.secondaryRegistered ? .secondary : .red)

        Text("Accessibility: \(recorder.accessibilityGranted ? "Granted" : "Not granted")")
            .font(.caption)
            .foregroundColor(recorder.accessibilityGranted ? .secondary : .orange)

        if !hotkeyManager.fnKeyStandard {
            Text("Hint: Enable F-keys as standard in System Settings")
                .font(.caption2)
                .foregroundColor(.orange)
        }

        if !recorder.accessibilityGranted {
            Button("Grant Accessibility\u{2026}") {
                PasteManager.shared.requestAccessibility()
            }
        }

        if !recorder.lastTranscription.isEmpty {
            Divider()
            Text("Last: \(recorder.lastTranscription.prefix(60))")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        if !recorder.transcriptionHistory.isEmpty {
            Menu("Recent") {
                ForEach(Array(recorder.transcriptionHistory.enumerated()), id: \.offset) { _, text in
                    Button(String(text.prefix(50))) {
                        PasteManager.shared.setClipboard(text: text)
                    }
                }
            }
        }

        if !recorder.lastError.isEmpty {
            Divider()
            Text("Error: \(recorder.lastError)")
                .font(.caption)
                .foregroundColor(.red)
        }

        Divider()

        Button("Quit") {
            hotkeyManager.unregister()
            recorder.quitCleanup()
            NSApplication.shared.terminate(nil)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if ProcessInfo.processInfo.environment["NIMBUS_VTT_HUD_SMOKE"] == "1" {
            runHUDSmokeAndTerminate()
            return
        }

        AppState.shared.recorder?.startServer()
        AppState.shared.recorder?.refreshActiveMic(force: true)
        AppState.shared.recorder?.refreshAudioDevices()

        // After a rename, re-register the login item so it points at the new bundle path.
        if AppState.shared.settings?.launchAtLogin == true {
            try? SMAppService.mainApp.unregister()
            try? SMAppService.mainApp.register()
        }

        if !AXIsProcessTrusted() || !MicPermission.isGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                StatusWindowController.shared.showWindow()
            }
        }

        // Show status window on launch (if enabled)
        if AppState.shared.settings?.showWindowOnLaunch ?? false {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                StatusWindowController.shared.showWindow()
            }
        }

        if AppState.shared.settings?.notificationsEnabled == true {
            NotificationManager.shared.requestPermission()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        StatusWindowController.shared.showWindow()
        return true
    }

    private func runHUDSmokeAndTerminate() {
        VTTLogger.log("hud smoke started")
        HUDManager.shared.showRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            HUDManager.shared.showTranscribing()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
            HUDManager.shared.showPasted(chars: 24)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            HUDManager.shared.hide()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.80) {
            VTTLogger.log("hud smoke complete")
            NSApplication.shared.terminate(nil)
        }
    }
}

private final class WindowFrameObserver: NSObject, NSWindowDelegate {
    private let frameKey: String
    private var observerTokens: [NSObjectProtocol] = []
    private let onClose: () -> Void

    init(window: NSWindow, frameKey: String, onClose: @escaping () -> Void) {
        self.frameKey = frameKey
        self.onClose = onClose
        super.init()
        window.delegate = self
        observerTokens = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak window, frameKey] _ in
                guard let window else { return }
                UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameKey)
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak window, frameKey] _ in
                guard let window else { return }
                UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: frameKey)
            }
        ]
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
        onClose()
    }

    deinit {
        cleanup()
    }

    private func cleanup() {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        observerTokens.removeAll()
    }
}

private func makeHostedWindow<Content: View>(
    title: String,
    contentSize: NSSize,
    frameKey: String,
    rootView: Content,
    onClose: @escaping () -> Void
) -> (window: NSWindow, observer: WindowFrameObserver) {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: contentSize),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.title = title
    window.contentViewController = NSHostingController(rootView: rootView)
    window.minSize = contentSize
    window.setContentSize(contentSize)
    window.isReleasedWhenClosed = false

    if !restoreFrame(for: window, key: frameKey, minimumSize: contentSize) {
        window.center()
    }

    let observer = WindowFrameObserver(window: window, frameKey: frameKey, onClose: onClose)
    return (window, observer)
}

private func restoreFrame(for window: NSWindow, key: String, minimumSize: NSSize) -> Bool {
    guard let frameString = UserDefaults.standard.string(forKey: key) else {
        return false
    }

    let frame = NSRectFromString(frameString)
    guard frame.origin.x.isFinite,
          frame.origin.y.isFinite,
          frame.width.isFinite,
          frame.height.isFinite,
          frame.width >= minimumSize.width,
          frame.height >= minimumSize.height,
          NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else {
        return false
    }

    window.setFrame(frame, display: false)
    return true
}

class StatusWindowController {
    static let shared = StatusWindowController()
    private var window: NSWindow?
    private var frameObserver: WindowFrameObserver?

    func showWindow() {
        guard let recorder = AppState.shared.recorder,
              let hotkeyManager = AppState.shared.hotkeyManager,
              let settings = AppState.shared.settings else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = StatusWindowView(
            recorder: recorder,
            hotkeyManager: hotkeyManager,
            settings: settings
        )
        let hosted = makeHostedWindow(
            title: "Nimbus VTT",
            contentSize: NSSize(width: 420, height: 620),
            frameKey: "statusWindowFrame",
            rootView: contentView
        ) { [weak self] in
            self?.window = nil
            self?.frameObserver = nil
        }

        window = hosted.window
        frameObserver = hosted.observer
        hosted.window.makeKeyAndOrderFront(nil)
    }
}

class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var frameObserver: WindowFrameObserver?

    func showWindow() {
        guard let recorder = AppState.shared.recorder,
              let hotkeyManager = AppState.shared.hotkeyManager,
              let settings = AppState.shared.settings else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Recreate the view each time to pick up latest state.
        let contentView = SettingsView(
            settings: settings,
            recorder: recorder,
            hotkeyManager: hotkeyManager
        )
        let hosted = makeHostedWindow(
            title: "Nimbus VTT Settings",
            contentSize: NSSize(width: 580, height: 600),
            frameKey: "settingsWindowFrame",
            rootView: contentView
        ) { [weak self] in
            self?.window = nil
            self?.frameObserver = nil
        }

        window = hosted.window
        frameObserver = hosted.observer
        hosted.window.makeKeyAndOrderFront(nil)
    }
}
