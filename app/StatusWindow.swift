import SwiftUI
import AppKit

struct StatusWindowView: View {
    @ObservedObject var recorder: RecorderManager
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var hud = HUDManager.shared
    @State private var micGranted = MicPermission.isGranted
    @State private var permissionTimer: Timer?

    private let cardRadius: CGFloat = 8

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [NimbusTheme.cream, NimbusTheme.cloudNavy, NimbusTheme.parchment],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 16) {
                statusHeader
                if permissionsReady {
                    recordButton
                    workflowStrip
                    statsRow
                } else {
                    permissionsCard
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                statusCards

                if !recorder.lastTranscription.isEmpty {
                    transcriptionCard
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                if !recorder.lastError.isEmpty {
                    errorBanner
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 20)
        }
        .frame(width: 420, height: 620)
        .animation(.easeInOut(duration: 0.2), value: recorder.state)
        .animation(.easeInOut(duration: 0.2), value: recorder.lastTranscription)
        .animation(.easeInOut(duration: 0.2), value: recorder.lastError)
        .animation(.easeInOut(duration: 0.2), value: permissionsReady)
        .onAppear {
            refreshPermissions()
            recorder.refreshActiveMic()
            recorder.refreshAudioDevices()
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                refreshPermissions()
            }
        }
        .onDisappear {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    // MARK: - Header

    private var statusHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(NimbusTheme.elevatedFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(statusColor.opacity(0.28), lineWidth: 1)
                    )

                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Image(systemName: headerSymbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Nimbus VTT")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(NimbusTheme.cocoa.opacity(0.68))
                    .textCase(.uppercase)

                Text(recorder.statusDescription)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(NimbusTheme.frost)
                    .lineLimit(1)

                Text(statusDetailText)
                    .font(.system(size: 12, weight: .medium, design: recorder.state == .idle ? .rounded : .monospaced))
                    .foregroundStyle(NimbusTheme.cocoa.opacity(0.70))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            statusChip
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 2)
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusChipText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(NimbusTheme.frost)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(NimbusTheme.elevatedFill)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(statusColor.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Record button

    private var recordButton: some View {
        Button(action: { recorder.toggle() }) {
            ZStack {
                Circle()
                    .fill(buttonColor.opacity(recorder.state == .transcribing ? 0.26 : 1.0))
                    .frame(width: 72, height: 72)
                    .shadow(color: buttonColor.opacity(0.28), radius: 18, y: 9)

                Circle()
                    .strokeBorder(Color.white.opacity(0.58), lineWidth: 1)
                    .frame(width: 72, height: 72)

                if recorder.state == .transcribing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(1.12)
                        .tint(NimbusTheme.frost)
                } else {
                    Image(systemName: buttonSymbol)
                        .font(.system(size: recorder.state == .recording ? 23 : 25, weight: .semibold))
                        .foregroundStyle(recorder.state == .idle ? Color.white : Color.white)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: 92, height: 86)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.state == .transcribing || !settings.isSetupComplete)
        .scaleEffect(recorder.state == .recording ? 1.0 : 0.96)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: recorder.state)
    }

    private var buttonColor: Color {
        switch recorder.state {
        case .idle:
            return NimbusTheme.sky
        case .recording:
            return NimbusTheme.record
        case .transcribing:
            return NimbusTheme.sky.opacity(0.46)
        }
    }

    private var buttonSymbol: String {
        recorder.state == .recording ? "stop.fill" : "mic.fill"
    }

    // MARK: - Permissions

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NimbusTheme.sky)
                Text("Finish Setup")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(NimbusTheme.frost)
                Spacer()
            }

            permissionRow(
                title: "Microphone",
                detail: micGranted ? "Ready for dictation" : "Required to record audio",
                granted: micGranted,
                actionTitle: "Request",
                action: {
                    MicPermission.requestAccess { granted in
                        DispatchQueue.main.async {
                            micGranted = granted
                        }
                    }
                }
            )

            permissionRow(
                title: "Accessibility",
                detail: recorder.accessibilityGranted ? "Paste into focused apps is enabled" : "Required to paste transcriptions",
                granted: recorder.accessibilityGranted,
                actionTitle: "Open",
                action: {
                    PasteManager.shared.requestAccessibility()
                    openSystemSettings("Privacy_Accessibility")
                }
            )
        }
        .padding(14)
        .background(cardBackground)
        .overlay(cardStroke)
        .padding(.horizontal, 20)
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(granted ? NimbusTheme.success : NimbusTheme.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(NimbusTheme.frost)
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(NimbusTheme.frost.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !granted {
                Button(actionTitle, action: action)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Stats

    private var workflowStrip: some View {
        HStack(spacing: 8) {
            workflowItem(
                icon: "mic",
                title: "Input",
                value: recorder.activeMicName
            )
            workflowItem(
                icon: settings.outputMode == "paste" ? "arrow.down.doc" : "doc.on.clipboard",
                title: "Output",
                value: settings.outputMode == "paste" ? "Focused app" : "Clipboard"
            )
            workflowItem(
                icon: "wand.and.stars",
                title: "Style",
                value: settings.postprocessModeLabel
            )
        }
        .padding(.horizontal, 20)
    }

    private func workflowItem(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NimbusTheme.sky)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .textCase(.uppercase)
                    .foregroundStyle(NimbusTheme.frost.opacity(0.45))
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(NimbusTheme.frost.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
        .background(cardBackground)
        .overlay(cardStroke)
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard(
                icon: "mic.fill",
                value: "\(recorder.sessionCount)",
                label: "Sessions"
            )
            statCard(
                icon: "text.alignleft",
                value: "\(recorder.totalCharsTranscribed)",
                label: "Characters"
            )
            statCard(
                icon: "keyboard",
                value: hotkeyManager.primaryHotkeyLabel,
                label: "Hotkey"
            )
        }
        .padding(.horizontal, 20)
    }

    private func statCard(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NimbusTheme.sky)

            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(NimbusTheme.frost)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NimbusTheme.frost.opacity(0.55))
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(cardBackground)
        .overlay(cardStroke)
        .shadow(color: NimbusTheme.cocoa.opacity(0.04), radius: 12, y: 6)
    }

    // MARK: - Status cards

    private var statusCards: some View {
        VStack(spacing: 9) {
            statusRow(
                label: "Whisper",
                value: recorder.isWhisperServerReady ? "Ready" : "Starting...",
                color: recorder.isWhisperServerReady ? NimbusTheme.success : NimbusTheme.warning
            )
            statusRow(
                label: "Microphone",
                value: micGranted ? "Granted" : "Not granted",
                color: micGranted ? NimbusTheme.success : NimbusTheme.warning
            )
            statusRow(
                label: hotkeyManager.primaryHotkeyLabel,
                value: hotkeyManager.primaryRegistered ? "Registered" : (hotkeyManager.primaryError.isEmpty ? "Not registered" : hotkeyManager.primaryError),
                color: hotkeyManager.primaryRegistered ? NimbusTheme.success : NimbusTheme.record
            )
            statusRow(
                label: hotkeyManager.secondaryHotkeyLabel,
                value: hotkeyManager.secondaryRegistered ? "Registered" : (hotkeyManager.secondaryError.isEmpty ? "Not registered" : hotkeyManager.secondaryError),
                color: hotkeyManager.secondaryRegistered ? NimbusTheme.success : NimbusTheme.record
            )
            statusRow(
                label: "Accessibility",
                value: recorder.accessibilityGranted ? "Granted" : "Not granted",
                color: recorder.accessibilityGranted ? NimbusTheme.success : NimbusTheme.warning
            )
        }
        .padding(14)
        .background(cardBackground)
        .overlay(cardStroke)
        .padding(.horizontal, 20)
    }

    private func statusRow(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(NimbusTheme.cocoa.opacity(0.66))
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Transcription card

    private var transcriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last transcription")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .textCase(.uppercase)
                    .foregroundStyle(NimbusTheme.frost.opacity(0.62))

                Spacer()

                Button {
                    PasteManager.shared.setClipboard(text: recorder.lastTranscription)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .foregroundStyle(NimbusTheme.frost)
                        .background(Circle().fill(NimbusTheme.elevatedFill))
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }

            Text(String(recorder.lastTranscription.prefix(200)))
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(NimbusTheme.cocoa.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .lineLimit(4)
        }
        .padding(14)
        .background(cardBackground)
        .overlay(cardStroke)
        .padding(.horizontal, 20)
    }

    private var errorBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(NimbusTheme.warning)
            Text(recorder.lastError)
                .font(.caption)
                .foregroundStyle(NimbusTheme.frost)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .fill(NimbusTheme.warning.opacity(0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(NimbusTheme.warning.opacity(0.24), lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }

    // MARK: - Helpers

    private var permissionsReady: Bool {
        micGranted && recorder.accessibilityGranted
    }

    private func refreshPermissions() {
        micGranted = MicPermission.isGranted
        recorder.accessibilityGranted = PasteManager.shared.isAccessibilityTrusted()
    }

    private func openSystemSettings(_ item: String) {
        let url = "x-apple.systempreferences:com.apple.preference.security?\(item)"
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
            .fill(NimbusTheme.cardFill)
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
            .strokeBorder(NimbusTheme.cardBorder, lineWidth: 1)
    }

    private var statusColor: Color {
        switch recorder.state {
        case .idle:
            return NimbusTheme.sky
        case .recording:
            return NimbusTheme.record
        case .transcribing:
            return NimbusTheme.frost
        }
    }

    private var headerSymbol: String {
        switch recorder.state {
        case .idle:
            return "cloud.fill"
        case .recording:
            return "waveform.circle.fill"
        case .transcribing:
            return "cloud.fill"
        }
    }

    private var statusDetailText: String {
        switch recorder.state {
        case .idle:
            return "Mic: \(recorder.activeMicName)"
        case .recording:
            return timeString(hud.elapsed)
        case .transcribing:
            return "Processing audio"
        }
    }

    private var statusChipText: String {
        switch recorder.state {
        case .idle:
            return "Ready"
        case .recording:
            return timeString(hud.elapsed)
        case .transcribing:
            return "Working"
        }
    }

    private func timeString(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
