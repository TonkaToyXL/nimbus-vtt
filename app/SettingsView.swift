import SwiftUI
import AppKit
import AVFoundation

// MARK: - Shared styling

private enum NimbusStyle {
    static let cardRadius: CGFloat = 8
    static let controlRadius: CGFloat = 7
    static let cardBackground = NimbusTheme.cardFill
    static let cardBorder = NimbusTheme.cardBorder
    static let primaryText = NimbusTheme.frost
    static let secondaryText = NimbusTheme.cocoa.opacity(0.68)
    static let mutedText = NimbusTheme.cocoa.opacity(0.46)
    static let accent = NimbusTheme.sky
}

struct CardSection<Content: View>: View {
    let title: String
    let systemImage: String?
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NimbusStyle.accent)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .textCase(.uppercase)
                    .foregroundStyle(NimbusStyle.secondaryText)
            }
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: NimbusStyle.cardRadius, style: .continuous)
                .fill(NimbusStyle.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NimbusStyle.cardRadius, style: .continuous)
                .strokeBorder(NimbusStyle.cardBorder, lineWidth: 1)
        )
    }
}

// MARK: - Branded header

struct SettingsHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(NimbusStyle.accent)
                    .frame(width: 42, height: 42)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Nimbus VTT")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(NimbusStyle.primaryText)
                Text("Voice-to-text \u{2014} 100% local")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(NimbusStyle.secondaryText)
            }

            Spacer()

            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text("v\(version)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NimbusStyle.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous).fill(NimbusTheme.elevatedFill)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(NimbusTheme.cardBorder, lineWidth: 1)
                    )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: NimbusStyle.cardRadius, style: .continuous)
                .fill(NimbusTheme.elevatedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NimbusStyle.cardRadius, style: .continuous)
                .strokeBorder(NimbusTheme.cardBorder, lineWidth: 1)
        )
    }
}

// MARK: - Hotkey recorder

struct HotkeyRecorder: View {
    let label: String
    @Binding var spec: String
    let onCommit: (String) -> Void

    @State private var isRecording = false
    @State private var capturedLabel: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))

            Spacer()

            HotkeyCaptureField(
                isRecording: $isRecording,
                capturedLabel: $capturedLabel,
                currentSpec: spec,
                onCapture: { newSpec in
                    spec = newSpec
                    onCommit(newSpec)
                }
            )
            .frame(width: 150)
        }
    }
}

struct HotkeyCaptureField: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var capturedLabel: String
    let currentSpec: String
    let onCapture: (String) -> Void

    func makeNSView(context: Context) -> HotkeyCaptureButton {
        let button = HotkeyCaptureButton()
        button.spec = currentSpec
        button.onCapture = { newSpec in
            DispatchQueue.main.async {
                onCapture(newSpec)
            }
        }
        button.onRecordingChange = { recording in
            DispatchQueue.main.async {
                isRecording = recording
            }
        }
        button.updateLabel()
        return button
    }

    func updateNSView(_ nsView: HotkeyCaptureButton, context: Context) {
        if !nsView.isRecording {
            nsView.spec = currentSpec
            nsView.updateLabel()
        }
    }
}

final class HotkeyCaptureButton: NSButton {
    var spec: String = ""
    var onCapture: ((String) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    var isRecording = false {
        didSet {
            onRecordingChange?(isRecording)
            updateLabel()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        target = self
        action = #selector(toggleRecording)
    }

    @objc private func toggleRecording() {
        isRecording.toggle()
        if isRecording {
            window?.makeFirstResponder(self)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Escape cancels recording
        if event.keyCode == 53 {
            isRecording = false
            return
        }

        let mods = event.modifierFlags
        var parts: [String] = []

        if mods.contains(.command) { parts.append("command") }
        if mods.contains(.option) { parts.append("option") }
        if mods.contains(.control) { parts.append("control") }
        if mods.contains(.shift) { parts.append("shift") }

        let keyMap: [UInt16: String] = [
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5",
            97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10",
            103: "f11", 111: "f12",
            49: "space",
        ]

        guard let keyToken = keyMap[event.keyCode] else {
            NSSound.beep()
            return
        }

        parts.append(keyToken)
        let newSpec = parts.joined(separator: "+")

        // Validate via the parser
        guard HotkeyManager.parse(newSpec) != nil else {
            NSSound.beep()
            return
        }

        spec = newSpec
        isRecording = false
        onCapture?(newSpec)
    }

    func updateLabel() {
        if isRecording {
            title = "Press keys\u{2026}"
            font = .systemFont(ofSize: 11, weight: .medium)
        } else {
            let binding = HotkeyManager.parse(spec)
            title = binding?.label ?? spec
            font = .systemFont(ofSize: 12, weight: .medium)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: RecorderManager
    @ObservedObject var hotkeyManager: HotkeyManager
    @State private var micGranted = MicPermission.isGranted

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [NimbusTheme.cream, NimbusTheme.cloudNavy, NimbusTheme.parchment],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                SettingsHeader()
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                TabView {
                    generalTab
                        .tabItem { Label("General", systemImage: "gear") }
                    transcriptionTab
                        .tabItem { Label("Transcription", systemImage: "waveform") }
                    hotkeysTab
                        .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                    permissionsTab
                        .tabItem { Label("Permissions", systemImage: "lock.shield") }
                    aboutTab
                        .tabItem { Label("About", systemImage: "info.circle") }
                }
                .tint(NimbusTheme.sky)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 580, height: 600)
    }

    // MARK: - General

    @ViewBuilder
    private var generalTab: some View {
        ScrollView {
            VStack(spacing: 14) {
                CardSection("Output", systemImage: "arrow.right.doc.on.clipboard") {
                    VStack(alignment: .leading, spacing: 6) {
                        RadioButtonRow(title: "Paste into focused app", isSelected: settings.outputMode == "paste") {
                            settings.outputMode = "paste"; settings.save()
                        }
                        RadioButtonRow(title: "Clipboard only", isSelected: settings.outputMode == "clipboard") {
                            settings.outputMode = "clipboard"; settings.save()
                        }
                    }
                }

                CardSection("Feedback", systemImage: "bell") {
                    Toggle("Notifications", isOn: $settings.notificationsEnabled)
                    Toggle("Sounds", isOn: $settings.soundEnabled)
                    if settings.soundEnabled {
                        HStack {
                            Text("Volume")
                            Slider(value: $settings.soundVolume, in: 0...1, step: 0.1)
                            Text("\(Int(settings.soundVolume * 100))%")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        Button("Test Sounds") {
                            SoundManager.shared.playStart()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                SoundManager.shared.playStop()
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                SoundManager.shared.playDone()
                            }
                        }
                        .font(.caption)
                    }
                }

                CardSection("Startup", systemImage: "power") {
                    Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    Toggle("Show window on launch", isOn: $settings.showWindowOnLaunch)
                }

                CardSection("HUD", systemImage: "rectangle.dashed") {
                    Button("Reset HUD Position") {
                        UserDefaults.standard.removeObject(forKey: "hudPosX")
                        UserDefaults.standard.removeObject(forKey: "hudPosY")
                    }
                    .font(.caption)
                }

                CardSection("Diagnostics", systemImage: "folder") {
                    HStack {
                        Button("Open Config Folder") {
                            openInFinder("~/Library/Application Support/VoiceToText")
                        }
                        Button("Open Log File") {
                            openInFinder("~/Library/Logs/VoiceToText.log")
                        }
                    }
                    .font(.caption)
                    if !settings.configError.isEmpty {
                        Text(settings.configError)
                            .font(.caption)
                            .foregroundColor(NimbusTheme.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .onChangeCompat(of: settings.outputMode) { _ in settings.save() }
        .onChangeCompat(of: settings.notificationsEnabled) { enabled in
            if enabled { NotificationManager.shared.requestPermission() }
            settings.save()
        }
        .onChangeCompat(of: settings.soundEnabled) { _ in settings.save() }
        .onChangeCompat(of: settings.soundVolume) { vol in
            SoundManager.shared.setVolume(Float(vol))
            settings.save()
        }
        .onChangeCompat(of: settings.launchAtLogin) { _ in settings.save() }
        .onChangeCompat(of: settings.showWindowOnLaunch) { _ in settings.save() }
    }

    // MARK: - Transcription

    @ViewBuilder
    private var transcriptionTab: some View {
        ScrollView {
            VStack(spacing: 14) {
                CardSection("Whisper Server", systemImage: "server.rack") {
                    HStack {
                        Circle()
                            .fill(recorder.isWhisperServerReady ? NimbusTheme.success : NimbusTheme.warning)
                            .frame(width: 8, height: 8)
                        Text("Status")
                        Spacer()
                        Text(recorder.isWhisperServerReady ? "Ready" : "Starting\u{2026}")
                            .foregroundColor(recorder.isWhisperServerReady ? NimbusStyle.secondaryText : NimbusTheme.warning)
                            .font(.system(.body, design: .monospaced))
                    }
                    Text("Model loads once at launch and stays warm for fast repeat dictation (~1s after warm-up).")
                        .font(.caption)
                        .foregroundColor(NimbusStyle.secondaryText)
                    Button("Restart Whisper Server") {
                        recorder.restartServer()
                    }
                    .disabled(recorder.state != .idle)
                }

                CardSection("Model", systemImage: "brain") {
                    Picker("Model", selection: $settings.model) {
                        ForEach(settings.availableModels, id: \.id) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                    Text("Large v3 Turbo is accurate. Small English is ~4\u{00D7} faster for English dictation.")
                        .font(.caption)
                        .foregroundColor(NimbusStyle.secondaryText)
                }

                CardSection("Language", systemImage: "globe") {
                    Picker("Language", selection: $settings.language) {
                        ForEach(settings.availableLanguages, id: \.1) { lang in
                            Text(lang.0).tag(lang.1)
                        }
                    }
                    Text("English is fastest (~1s). Auto-detect adds ~1s per dictation.")
                        .font(.caption)
                        .foregroundColor(NimbusStyle.secondaryText)
                }

                CardSection("Silence Filtering", systemImage: "waveform.path.ecg") {
                    HStack {
                        Text("VAD Sensitivity")
                        Slider(value: $settings.vadThreshold, in: 0.001...0.05, step: 0.001)
                        Text("\(String(format: "%.3f", settings.vadThreshold))")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                    Text("Lower = more sensitive. Higher = stricter.")
                        .font(.caption)
                        .foregroundColor(NimbusStyle.secondaryText)
                        .padding(.bottom, 4)

                    VADVisualizer(recorder: recorder, threshold: settings.vadThreshold)
                }

                CardSection("Initial Prompt", systemImage: "text.alignleft") {
                    TextField("e.g. Names, jargon, punctuation style", text: $settings.initialPrompt, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                    Text("Biases Whisper toward proper punctuation and capitalization.")
                        .font(.caption)
                        .foregroundColor(NimbusStyle.secondaryText)
                }

                CardSection("Output Style", systemImage: "wand.and.stars") {
                    Picker("Output style", selection: $settings.postprocessMode) {
                        ForEach(settings.availablePostprocessModes, id: \.id) { mode in
                            Text(mode.label).tag(mode.id)
                        }
                    }
                    Text(postprocessDescription(settings.postprocessMode))
                        .font(.caption)
                        .foregroundColor(NimbusStyle.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                CardSection("Test", systemImage: "mic.fill") {
                    Button("Test Transcription") {
                        recorder.toggle()
                    }
                    .disabled(recorder.state != .idle)
                }
            }
            .padding(.vertical, 8)
        }
        .onChangeCompat(of: settings.model) { _ in
            settings.save()
            recorder.restartServer()
        }
        .onChangeCompat(of: settings.language) { _ in settings.save() }
        .onChangeCompat(of: settings.vadThreshold) { _ in settings.save() }
        .onChangeCompat(of: settings.initialPrompt) { _ in settings.save() }
        .onChangeCompat(of: settings.postprocessMode) { _ in settings.save() }
    }

    // MARK: - Hotkeys

    @ViewBuilder
    private var hotkeysTab: some View {
        ScrollView {
            VStack(spacing: 14) {
                CardSection("Primary Hotkey", systemImage: "keyboard") {
                    HotkeyRecorder(
                        label: "Primary",
                        spec: $settings.primaryHotkey,
                        onCommit: { _ in
                            settings.save()
                            hotkeyManager.register()
                        }
                    )
                    HStack {
                        Text("Status")
                            .font(.caption)
                            .foregroundStyle(NimbusStyle.secondaryText)
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(hotkeyManager.primaryRegistered ? NimbusTheme.success : NimbusTheme.record)
                                .frame(width: 6, height: 6)
                            Text(hotkeyManager.primaryRegistered ? "Registered" : (hotkeyManager.primaryError.isEmpty ? "Not registered" : hotkeyManager.primaryError))
                                .font(.caption)
                                .foregroundStyle(hotkeyManager.primaryRegistered ? NimbusStyle.secondaryText : NimbusTheme.record)
                        }
                    }
                }

                CardSection("Secondary Hotkey", systemImage: "keyboard") {
                    HotkeyRecorder(
                        label: "Secondary",
                        spec: $settings.secondaryHotkey,
                        onCommit: { _ in
                            settings.save()
                            hotkeyManager.register()
                        }
                    )
                    HStack {
                        Text("Status")
                            .font(.caption)
                            .foregroundStyle(NimbusStyle.secondaryText)
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(hotkeyManager.secondaryRegistered ? NimbusTheme.success : NimbusTheme.record)
                                .frame(width: 6, height: 6)
                            Text(hotkeyManager.secondaryRegistered ? "Registered" : (hotkeyManager.secondaryError.isEmpty ? "Not registered" : hotkeyManager.secondaryError))
                                .font(.caption)
                                .foregroundStyle(hotkeyManager.secondaryRegistered ? NimbusStyle.secondaryText : NimbusTheme.record)
                        }
                    }
                }

                CardSection("Actions", systemImage: "arrow.clockwise") {
                    HStack {
                        Button("Reload from Config") {
                            settings.reloadFromDisk()
                            hotkeyManager.register()
                        }
                        Button("Reset to Defaults") {
                            hotkeyManager.resetToDefaults()
                        }
                    }
                    .font(.caption)
                }

                CardSection("Supported Keys", systemImage: "questionmark.circle") {
                    Text("Supported: F1\u{2013}F12, Space, and modifier combos (Option+Space, Cmd+Shift+Space, etc.). Press Escape to cancel recording.")
                        .font(.caption)
                        .foregroundColor(NimbusStyle.secondaryText)
                }

                if !hotkeyManager.fnKeyStandard {
                    CardSection("Function Key Setup", systemImage: "exclamationmark.triangle") {
                        Text("\u{26A0} F-keys are media keys. Enable: System Settings \u{2192} Keyboard \u{2192} Keyboard Shortcuts \u{2192} Function Keys")
                            .font(.caption)
                            .foregroundColor(NimbusTheme.warning)
                        Button("Open Keyboard Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")!)
                        }
                        .font(.caption)
                        Text("Note: External keyboards (Razer Cynosa V2) typically send F1 directly.")
                            .font(.caption2)
                            .foregroundColor(NimbusStyle.secondaryText)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionsTab: some View {
        ScrollView {
            VStack(spacing: 14) {
                CardSection("Microphone", systemImage: "mic.fill") {
                    HStack {
                        Image(systemName: micGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundColor(micGranted ? NimbusTheme.success : NimbusTheme.warning)
                        Text("Microphone Access")
                        Spacer()
                        Text(MicPermission.statusLabel)
                            .foregroundColor(micGranted ? NimbusStyle.secondaryText : NimbusTheme.warning)
                            .font(.caption)
                    }
                    if !micGranted {
                        Button("Request Microphone Access") {
                            MicPermission.requestAccess { granted in
                                DispatchQueue.main.async { micGranted = granted }
                            }
                        }
                        .font(.caption)
                    }
                    Picker("Input Device", selection: Binding(
                        get: { settings.inputDeviceIndex ?? -1 },
                        set: { newValue in
                            settings.inputDeviceIndex = newValue < 0 ? nil : newValue
                            settings.save()
                            recorder.refreshActiveMic()
                        }
                    )) {
                        Text("Automatic (system default)").tag(-1)
                        ForEach(recorder.audioDevices.filter { !$0.blocked }) { device in
                            Text(device.label).tag(device.index)
                        }
                    }
                    HStack {
                        Text("Active Input")
                            .font(.caption)
                            .foregroundStyle(NimbusStyle.secondaryText)
                        Spacer()
                        Text(recorder.activeMicName)
                            .font(.caption)
                            .foregroundColor(NimbusStyle.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    HStack {
                        Button("Refresh Devices") {
                            recorder.refreshAudioDevices()
                            recorder.refreshActiveMic()
                            refreshMicPermission()
                        }
                        Button("Open Mic Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    }
                    .font(.caption)
                }

                CardSection("Accessibility", systemImage: "accessibility") {
                    HStack {
                        Image(systemName: recorder.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundColor(recorder.accessibilityGranted ? NimbusTheme.success : NimbusTheme.warning)
                        Text("Accessibility Access")
                        Spacer()
                        Text(recorder.accessibilityGranted ? "Granted" : "Not granted")
                            .foregroundColor(recorder.accessibilityGranted ? NimbusStyle.secondaryText : NimbusTheme.warning)
                            .font(.caption)
                    }
                    Text("Required to paste transcribed text into the focused app.")
                        .font(.caption)
                        .foregroundColor(NimbusStyle.secondaryText)
                    if !recorder.accessibilityGranted {
                        Button("Grant Accessibility\u{2026}") {
                            PasteManager.shared.requestAccessibility()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }

                CardSection("Notifications", systemImage: "bell") {
                    Button("Open Notification Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                    }
                    .font(.caption)
                }

                CardSection("Reset", systemImage: "arrow.counterclockwise") {
                    Button("Reset All Permissions") {
                        let task = Process()
                        task.launchPath = "/usr/bin/tccutil"
                        task.arguments = ["reset", "ALL", Bundle.main.bundleIdentifier ?? "app.nimbusvtt.NimbusVTT"]
                        try? task.run()
                    }
                    .foregroundColor(.red)
                    .font(.caption)
                }
            }
            .padding(.vertical, 8)
        }
        .onAppear {
            recorder.accessibilityGranted = PasteManager.shared.isAccessibilityTrusted()
            recorder.refreshAudioDevices()
            refreshMicPermission()
        }
    }

    private func refreshMicPermission() {
        micGranted = MicPermission.isGranted
    }

    // MARK: - About

    @ViewBuilder
    private var aboutTab: some View {
        VStack(spacing: 20) {
            Group {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 80, height: 80)
                } else {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(NimbusStyle.accent)
                }
            }

            Text("Nimbus VTT")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(NimbusStyle.primaryText)

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.0")")
                .font(.caption)
                .foregroundColor(NimbusStyle.secondaryText)

            Text("Voice-to-text with auto-enhance \u{2014} 100% local")
                .font(.body)
                .foregroundColor(NimbusStyle.secondaryText)

            VStack(alignment: .leading, spacing: 8) {
                Label("mlx-whisper for local transcription", systemImage: "checkmark")
                    .foregroundColor(NimbusStyle.secondaryText)
                Label("Agent-handoff cleanup before paste", systemImage: "checkmark")
                    .foregroundColor(NimbusStyle.secondaryText)
                Label("No cloud \u{2014} data never leaves your Mac", systemImage: "checkmark")
                    .foregroundColor(NimbusStyle.secondaryText)
                Label("\(hotkeyManager.primaryHotkeyLabel) or \(hotkeyManager.secondaryHotkeyLabel) to dictate", systemImage: "checkmark")
                    .foregroundColor(NimbusStyle.secondaryText)
            }
            .font(.caption)

            Spacer()

            Button("Open Log File") {
                openInFinder("~/Library/Logs/VoiceToText.log")
            }
            .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openInFinder(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
    }

    private func postprocessDescription(_ mode: String) -> String {
        switch mode {
        case "agent_handoff":
            return "Removes filler words (um, ah, etc.), fixes punctuation, and trims rambling \u{2014} optimal for AI chat inputs."
        case "natural_prose":
            return "Cleans up transcription into readable, natural conversational text with standard grammar."
        case "code_aware":
            return "Preserves syntax, technical terms, symbols, and casing (camelCase, snake_case) for code snippets."
        case "minimal":
            return "Trims leading/trailing spaces but keeps all transcribed words exactly as spoken."
        case "off":
            return "Pastes the raw, unprocessed Whisper transcription output."
        default:
            return "Cleans up Whisper output before pasting."
        }
    }
}

// MARK: - Radio button row helper

struct RadioButtonRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? NimbusTheme.sky : NimbusStyle.secondaryText)
                Text(title)
                    .foregroundStyle(NimbusStyle.primaryText)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - VAD Live Visualizer

struct VADVisualizer: View {
    @ObservedObject var hud = HUDManager.shared
    @ObservedObject var recorder: RecorderManager
    let threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(NimbusTheme.elevatedFill)
                        .frame(height: 8)

                    // Audio level indicator
                    if recorder.state == .recording {
                        Capsule()
                            .fill(hud.audioLevel > (threshold * 20.0) ? NimbusTheme.success : NimbusTheme.warning)
                            .frame(width: min(geo.size.width, geo.size.width * CGFloat(hud.audioLevel)), height: 8)
                            .animation(.easeOut(duration: 0.08), value: hud.audioLevel)
                    }

                    // Threshold gate indicator
                    Rectangle()
                        .fill(NimbusTheme.record)
                        .frame(width: 2, height: 16)
                        .offset(x: min(geo.size.width - 2, max(0, geo.size.width * CGFloat(threshold * 20.0) - 1)))
                }
                .frame(height: 16)
            }
            .frame(height: 16)

            HStack {
                Text("Gate: \(String(format: "%.3f", threshold))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NimbusStyle.secondaryText)
                Spacer()
                if recorder.state == .recording {
                    Text(hud.audioLevel > (threshold * 20.0) ? "\u{25CF} SPEECH DETECTED" : "\u{25CB} SILENCE / FILTERED")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(hud.audioLevel > (threshold * 20.0) ? NimbusTheme.success : NimbusTheme.warning)
                } else {
                    Text("Calibrate via test recording")
                        .font(.system(size: 10))
                        .foregroundColor(NimbusStyle.secondaryText)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: NimbusStyle.controlRadius, style: .continuous)
                .fill(NimbusTheme.elevatedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NimbusStyle.controlRadius, style: .continuous)
                .strokeBorder(NimbusTheme.cardBorder, lineWidth: 1)
        )
    }
}
