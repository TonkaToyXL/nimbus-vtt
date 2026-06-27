import Foundation
import AppKit

struct AudioDevice: Identifiable, Equatable {
    let index: Int
    let name: String
    let blocked: Bool
    let isDefault: Bool

    var id: Int { index }
    var label: String {
        var parts = [name]
        if isDefault { parts.append("(system default)") }
        if blocked { parts.append("(excluded by default)") }
        return parts.joined(separator: " ")
    }
}

class RecorderManager: ObservableObject {
    enum State: String, CaseIterable {
        case idle = "VTT"
        case recording = "REC"
        case transcribing = "TXT"
    }

    @Published var state: State = .idle
    @Published var lastTranscription: String = ""
    @Published var lastError: String = ""
    @Published var isWhisperServerReady: Bool = false
    @Published var accessibilityGranted: Bool = false
    @Published var activeMicName: String = "—"
    @Published var audioDevices: [AudioDevice] = []
    @Published var transcriptionHistory: [String] = []
    private(set) var sessionCount = 0
    private(set) var totalCharsTranscribed = 0

    private var recordProcess: Process?
    private var rmsBuffer = ""
    private var transcribeProcess: Process?
    private var serverProcess: Process?
    private var serverStdinPipe: Pipe?
    private var serverStdoutPipe: Pipe?
    private var serverReady = false
    private let bufferLock = NSLock()
    private var serverStdoutBuffer = Data()
    private let serverQueue = DispatchQueue(label: "app.nimbusvtt.NimbusVTT.server")
    private var audioPath: String?
    private var stopWatchdogWorkItem: DispatchWorkItem?
    private var transcribeWatchdogWorkItem: DispatchWorkItem?
    private var transcribeInFlight = false
    private var isQuitting = false
    private var serverRestartCount = 0
    private var serverStartedAt: Date?
    private var serverGeneration = 0
    private var hasRefreshedActiveMicThisSession = false

    weak var settings: AppSettings?

    private func configureProcessEnvironment(_ process: Process) {
        var env = ProcessInfo.processInfo.environment
        let brewBin = "/opt/homebrew/bin"
        let usrLocalBin = "/usr/local/bin"
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !path.contains(brewBin) {
            env["PATH"] = "\(brewBin):\(usrLocalBin):\(path)"
        }
        process.environment = env
    }

    var toggleButtonLabel: String {
        switch state {
        case .idle: return "Start Recording"
        case .recording: return "Stop Recording"
        case .transcribing: return "Transcribing\u{2026}"
        }
    }

    var statusDescription: String {
        switch state {
        case .idle: return "Nimbus VTT — Ready"
        case .recording: return "Nimbus VTT — Recording\u{2026}"
        case .transcribing: return "Nimbus VTT — Transcribing\u{2026}"
        }
    }

    init() {
        HotkeyManager.shared.recorder = self
        accessibilityGranted = PasteManager.shared.isAccessibilityTrusted()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("VTTAccessibilityChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let granted = notification.object as? Bool {
                self?.accessibilityGranted = granted
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.accessibilityGranted = PasteManager.shared.isAccessibilityTrusted()
            AppState.shared.settings?.reloadFromDisk()
            AppState.shared.hotkeyManager?.register()
        }

        refreshActiveMic()
    }

    func refreshActiveMic(force: Bool = false) {
        if !force && hasRefreshedActiveMicThisSession { return }
        hasRefreshedActiveMicThisSession = true

        guard let python = venvPythonPath(), let cli = cliScriptPath() else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [cli, "mic"]
            self?.configureProcessEnvironment(process)

            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                guard let line = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !line.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let name = json["name"] as? String, !name.isEmpty else {
                    return
                }
                DispatchQueue.main.async {
                    self?.activeMicName = name
                }
            } catch {
                VTTLogger.log("mic refresh failed", ["error": error.localizedDescription])
            }
        }
    }

    func refreshAudioDevices() {
        guard let python = venvPythonPath(), let cli = cliScriptPath() else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [cli, "devices", "--json"]
            self?.configureProcessEnvironment(process)

            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let devices = json["devices"] as? [[String: Any]] else {
                    return
                }
                let parsed = devices.compactMap { dict -> AudioDevice? in
                    guard let index = dict["index"] as? Int,
                          let name = dict["name"] as? String else { return nil }
                    let blocked = dict["blocked"] as? Bool ?? false
                    let isDefault = dict["default"] as? Bool ?? false
                    return AudioDevice(index: index, name: name, blocked: blocked, isDefault: isDefault)
                }
                DispatchQueue.main.async {
                    self?.audioDevices = parsed
                }
            } catch {
                VTTLogger.log("device list failed", ["error": error.localizedDescription])
            }
        }
    }

    func startServer() {
        guard serverProcess == nil else { return }
        guard checkSetup() else { return }
        guard let python = venvPythonPath(), let cli = cliScriptPath() else { return }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [cli, "serve", "--framed"]
        configureProcessEnvironment(process)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = errPipe

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                VTTLogger.log("server", ["msg": line])
            }
        }

        do {
            serverGeneration += 1
            let startedGen = serverGeneration

            try process.run()
            serverProcess = process
            serverStdinPipe = stdinPipe
            serverStdoutPipe = stdoutPipe

            bufferLock.lock()
            serverStdoutBuffer = Data()
            bufferLock.unlock()

            serverReady = false
            isWhisperServerReady = false
            serverStartedAt = Date()

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                self?.bufferLock.lock()
                self?.serverStdoutBuffer.append(data)
                self?.bufferLock.unlock()
            }

            serverQueue.async { [weak self] in
                self?.waitForServerReady()
            }

            DispatchQueue.global().async { [weak self] in
                process.waitUntilExit()
                DispatchQueue.main.async {
                    guard let self = self, self.serverGeneration == startedGen else { return }
                    self.handleServerExit(status: process.terminationStatus)
                }
            }
        } catch {
            VTTLogger.log("server start failed", ["error": error.localizedDescription])
        }
    }

    private func waitForServerReady() {
        guard let msgData = readServerMessage(timeout: 120.0),
              let msg = String(data: msgData, encoding: .utf8),
              let json = try? JSONSerialization.jsonObject(with: Data(msg.utf8)) as? [String: Any],
              json["ready"] as? Bool == true else {
            DispatchQueue.main.async {
                VTTLogger.log("server ready timeout")
                self.serverReady = false
                self.isWhisperServerReady = false
            }
            self.terminateServerForRecovery(reason: "ready timeout")
            return
        }

        DispatchQueue.main.async {
            self.serverReady = true
            self.isWhisperServerReady = true
            if self.lastError.contains("Whisper server crashed") {
                self.lastError = ""
            }
            VTTLogger.log("server ready")
        }
    }

    private func terminateServerForRecovery(reason: String) {
        VTTLogger.log("server recovery requested", ["reason": reason])
        serverReady = false
        DispatchQueue.main.async {
            self.isWhisperServerReady = false
        }
        if let server = serverProcess, server.isRunning {
            server.terminate()
        }
    }

    private func handleServerExit(status: Int32) {
        VTTLogger.log("server exited", ["status": status])
        // If the server ran for > 30 seconds, treat it as a healthy session and
        // reset the crash counter so a single bad boot doesn't block recovery.
        if let start = serverStartedAt, Date().timeIntervalSince(start) > 30 {
            serverRestartCount = 0
        }
        serverStartedAt = nil
        serverProcess = nil
        serverStdinPipe = nil
        serverStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        serverStdoutPipe = nil

        bufferLock.lock()
        serverStdoutBuffer = Data()
        bufferLock.unlock()

        serverReady = false
        isWhisperServerReady = false

        guard !isQuitting else { return }

        let maxRestarts = 5
        guard serverRestartCount < maxRestarts else {
            VTTLogger.log("server gave up", ["restarts": serverRestartCount])
            DispatchQueue.main.async {
                self.lastError = "Whisper server crashed \(self.serverRestartCount)× — check log. Use Restart Whisper Server in Settings → Transcription."
            }
            return
        }

        // Exponential backoff: 1s, 2s, 4s, 8s, 16s
        let delay = pow(2.0, Double(serverRestartCount))
        serverRestartCount += 1
        VTTLogger.log("server restarting", ["attempt": serverRestartCount, "delay": delay])
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.isQuitting, self.serverProcess == nil else { return }
            self.startServer()
        }
    }

    func restartServer() {
        serverRestartCount = 0
        lastError = ""
        isWhisperServerReady = false
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopServerSync()
            DispatchQueue.main.async {
                self.startServer()
            }
        }
    }

    private func stopServerSync() {
        guard let server = serverProcess else { return }
        if server.isRunning {
            serverStdinPipe?.fileHandleForWriting.closeFile()
            server.terminate()
            let deadline = Date().addingTimeInterval(2.0)
            while server.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if server.isRunning {
                kill(server.processIdentifier, SIGKILL)
            }
        }
        serverProcess = nil
        serverStdinPipe = nil
        serverStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        serverStdoutPipe = nil

        bufferLock.lock()
        serverStdoutBuffer = Data()
        bufferLock.unlock()

        DispatchQueue.main.async {
            self.serverReady = false
            self.isWhisperServerReady = false
        }
    }

    private func readServerMessage(timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)

        // Read 4-byte big-endian length prefix
        while true {
            guard Date() < deadline else { return nil }
            guard serverProcess?.isRunning == true else { return nil }

            bufferLock.lock()
            let count = serverStdoutBuffer.count
            bufferLock.unlock()

            if count >= 4 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        bufferLock.lock()
        let lengthData = serverStdoutBuffer.subdata(in: 0..<4)
        let length = UInt32(bigEndian: lengthData.withUnsafeBytes { $0.load(as: UInt32.self) })

        if length > 5 * 1024 * 1024 {
            serverStdoutBuffer.removeAll()
            bufferLock.unlock()
            VTTLogger.log("server ipc error", ["reason": "payload too large", "size": length])
            return nil
        }
        bufferLock.unlock()

        // Read message body
        while true {
            guard Date() < deadline else { return nil }
            guard serverProcess?.isRunning == true else { return nil }

            bufferLock.lock()
            let count = serverStdoutBuffer.count
            bufferLock.unlock()

            if count >= length + 4 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        bufferLock.lock()
        serverStdoutBuffer.removeFirst(4)
        let message = serverStdoutBuffer.prefix(Int(length))
        serverStdoutBuffer.removeFirst(Int(length))
        bufferLock.unlock()

        return Data(message)
    }

    func toggle() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .transcribing:
            break
        }
    }

    private var outputMode: String {
        settings?.outputMode ?? "paste"
    }

    private var soundEnabled: Bool {
        settings?.soundEnabled ?? true
    }

    private var notificationsEnabled: Bool {
        settings?.notificationsEnabled ?? true
    }

    private func venvPythonPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent("Library/Application Support/VoiceToText/venv/bin/python").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func cliScriptPath() -> String? {
        let path = Bundle.main.path(forResource: "voice_to_text", ofType: "py")
        return (path != nil && !path!.isEmpty) ? path : nil
    }

    private func checkSetup() -> Bool {
        guard venvPythonPath() != nil else {
            lastError = "Python venv not found. Run build.sh --install."
            return false
        }
        guard cliScriptPath() != nil else {
            lastError = "CLI script missing from app bundle."
            return false
        }
        lastError = ""
        return true
    }

    private func startRecording() {
        guard state == .idle else { return }
        guard checkSetup() else { return }
        guard let python = venvPythonPath(), let cli = cliScriptPath() else { return }
        guard recordProcess == nil else { return }

        refreshActiveMic()

        let timestamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nimbusvtt_\(timestamp).wav")
        audioPath = url.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [cli, "record", "--output", url.path]
        configureProcessEnvironment(process)

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        PasteManager.shared.captureFrontmostApp()

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self.rmsBuffer += chunk
                while let nl = self.rmsBuffer.range(of: "\n") {
                    let line = String(self.rmsBuffer[self.rmsBuffer.startIndex..<nl.lowerBound])
                    self.rmsBuffer = String(self.rmsBuffer[nl.upperBound...])
                    self.handleRMSLine(line)
                }
            }
        }

        do {
            try process.run()
            recordProcess = process
            state = .recording
            lastError = ""

            if soundEnabled { SoundManager.shared.playStart() }
            HUDManager.shared.showRecording()
            if notificationsEnabled { NotificationManager.shared.send(title: "Nimbus VTT", body: "Listening\u{2026}") }

            DispatchQueue.global().async { [weak self] in
                process.waitUntilExit()
                let status = process.terminationStatus
                DispatchQueue.main.async {
                    self?.handleRecordExit(status)
                }
            }
        } catch {
            lastError = "Failed to start recording: \(error.localizedDescription)"
            audioPath = nil
        }
    }

    private func stopRecording() {
        guard let process = recordProcess, process.isRunning else {
            state = .idle
            HUDManager.shared.hide()
            recordProcess = nil
            return
        }
        if soundEnabled { SoundManager.shared.playStop() }

        let pid = process.processIdentifier

        // Step 1: SIGINT (graceful)
        VTTLogger.log("stop escalation", ["step": "SIGINT", "pid": pid])
        process.interrupt()

        // Watchdog: escalate to SIGTERM after 3s, SIGKILL after 5s
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard let proc = self.recordProcess, proc.processIdentifier == pid, proc.isRunning else { return }

            VTTLogger.log("stop escalation", ["step": "SIGTERM", "pid": pid])
            kill(pid, SIGTERM)

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard let proc = self.recordProcess, proc.processIdentifier == pid, proc.isRunning else { return }
                VTTLogger.log("stop escalation", ["step": "SIGKILL", "pid": pid])
                kill(pid, SIGKILL)
            }
        }
        stopWatchdogWorkItem = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: watchdog)
    }

    private func handleRecordExit(_ status: Int32) {
        recordProcess = nil
        stopWatchdogWorkItem?.cancel()
        stopWatchdogWorkItem = nil
        VTTLogger.log("record process exited", ["status": status])

        guard let path = audioPath else {
            state = .idle
            HUDManager.shared.hide()
            audioPath = nil
            return
        }

        if status == 0 {
            transcribe(path: path)
        } else {
            lastError = "Recording exited with code \(status)"
            VTTLogger.log("recording error", ["code": status])
            state = .idle
            HUDManager.shared.hide()
            audioPath = nil
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func beginTranscribeWatchdog() {
        transcribeWatchdogWorkItem?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .transcribing else { return }
            VTTLogger.log("transcribe watchdog", ["action": "force_reset"])
            self.transcribeProcess?.terminate()
            self.serverReady = false
            self.isWhisperServerReady = false
            self.lastError = "Transcription timed out"
            self.resetTranscribeState()
            self.state = .idle
            self.audioPath = nil
            HUDManager.shared.hide()
        }
        transcribeWatchdogWorkItem = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0, execute: watchdog)
    }

    private func resetTranscribeState() {
        transcribeInFlight = false
        cancelTranscribeWatchdog()
    }

    private func cancelTranscribeWatchdog() {
        transcribeWatchdogWorkItem?.cancel()
        transcribeWatchdogWorkItem = nil
    }

    private func handleRMSLine(_ line: String) {
        guard let marker = line.range(of: "__RMS__") else {
            VTTLogger.log("record_cli", ["msg": line])
            return
        }
        let valStr = line[marker.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rms = Double(valStr) else { return }
        let level = min(rms * 20.0, 1.0)
        HUDManager.shared.pushAudioLevel(level)
    }

    private func transcribe(path: String) {
        guard !transcribeInFlight else {
            VTTLogger.log("transcribe skipped", ["reason": "already in flight"])
            return
        }
        transcribeInFlight = true
        state = .transcribing
        HUDManager.shared.showTranscribing()
        beginTranscribeWatchdog()
        if notificationsEnabled { NotificationManager.shared.send(title: "Nimbus VTT", body: "Transcribing\u{2026}") }

        if serverReady, serverProcess?.isRunning == true {
            transcribeViaServer(path: path)
        } else {
            transcribeViaSubprocess(path: path)
        }
    }

    private func transcribeViaServer(path: String) {
        let mode = settings?.postprocessMode ?? AppSettings.defaultPostprocessMode
        serverQueue.async { [weak self] in
            guard let self = self,
                  self.serverReady,
                  let stdin = self.serverStdinPipe?.fileHandleForWriting else {
                DispatchQueue.main.async {
                    self?.transcribeViaSubprocess(path: path)
                }
                return
            }

            var request = Data()
            var payload: [String: Any] = ["audio_path": path]
            payload["mode"] = mode
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                request = data
            }
            request.append(0x0A)

            do {
                try stdin.write(contentsOf: request)
            } catch {
                VTTLogger.log("server stdin write failed", ["error": error.localizedDescription])
                self.terminateServerForRecovery(reason: "stdin write failed")
                DispatchQueue.main.async {
                    self.transcribeViaSubprocess(path: path)
                }
                return
            }

            let responseData = self.readServerMessage(timeout: 20.0)

            let text: String
            if let responseData,
               let resp = String(data: responseData, encoding: .utf8),
               let json = try? JSONSerialization.jsonObject(with: Data(resp.utf8)) as? [String: Any] {
                text = (json["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let error = json["error"] as? String, !error.isEmpty {
                    VTTLogger.log("server transcribe error", ["error": error])
                    DispatchQueue.main.async {
                        self.lastError = "Transcription failed: \(error)"
                    }
                }
            } else {
                VTTLogger.log("server response timeout")
                self.terminateServerForRecovery(reason: "response timeout or malformed json")
                DispatchQueue.main.async {
                    self.transcribeViaSubprocess(path: path)
                }
                return
            }

            DispatchQueue.main.async {
                self.handleTranscriptionComplete(text: text, audioPath: path)
            }
        }
    }

    private func transcribeViaSubprocess(path: String) {
        guard let python = venvPythonPath(), let cli = cliScriptPath() else {
            lastError = "Setup incomplete."
            state = .idle
            resetTranscribeState()
            HUDManager.shared.hide()
            return
        }

        let mode = settings?.postprocessMode ?? AppSettings.defaultPostprocessMode
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [cli, "transcribe", "--input", path, "--mode", mode]
        configureProcessEnvironment(process)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            transcribeProcess = process

            DispatchQueue.global().async { [weak self] in
                process.waitUntilExit()
                let status = process.terminationStatus
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if status != 0 {
                        VTTLogger.log("subprocess transcribe failed", ["status": status, "stderr": stderr])
                        self.lastError = "Transcription failed (exit \(status)): \(stderr.isEmpty ? "unknown error" : stderr)"
                        self.state = .idle
                        self.audioPath = nil
                        try? FileManager.default.removeItem(atPath: path)
                        self.resetTranscribeState()
                        HUDManager.shared.hide()
                        return
                    }
                    self.handleTranscriptionComplete(text: text, audioPath: path)
                }
            }
        } catch {
            lastError = "Transcription failed: \(error.localizedDescription)"
            state = .idle
            audioPath = nil
            try? FileManager.default.removeItem(atPath: path)
            resetTranscribeState()
            HUDManager.shared.hide()
        }
    }

    private func handleTranscriptionComplete(text: String, audioPath: String) {
        resetTranscribeState()
        lastTranscription = text
        transcribeProcess = nil
        self.audioPath = nil
        try? FileManager.default.removeItem(atPath: audioPath)

        if text.isEmpty {
            VTTLogger.log("transcribed chars=0")
            if lastError.isEmpty {
                lastError = "No speech detected or transcription failed"
            }
            state = .idle
            HUDManager.shared.hide()
            return
        }

        VTTLogger.log("transcribed", ["chars": text.count])
        lastError = ""

        // Track history + stats
        totalCharsTranscribed += text.count
        sessionCount += 1
        transcriptionHistory.insert(text, at: 0)
        if transcriptionHistory.count > 5 {
            transcriptionHistory = Array(transcriptionHistory.prefix(5))
        }

        PasteManager.shared.setClipboard(text: text)
        VTTLogger.log("clipboard success", ["reason": "pre_paste_copy", "chars": text.count])

        // Hide HUD before paste so the floating panel does not compete for focus.
        HUDManager.shared.hide()

        if outputMode == "paste" {
            let pasted = PasteManager.shared.paste(text: text)
            if pasted {
                VTTLogger.log("paste success")
            }
            if !pasted {
                VTTLogger.log("paste fallback clipboard")
                PasteManager.shared.setClipboard(text: text)
                lastError = "Paste failed \u{2014} text copied to clipboard"
            }
        } else {
            PasteManager.shared.setClipboard(text: text)
            VTTLogger.log("clipboard success")
        }

        accessibilityGranted = PasteManager.shared.isAccessibilityTrusted()

        if soundEnabled { SoundManager.shared.playDone() }
        if notificationsEnabled {
            NotificationManager.shared.send(title: "Nimbus VTT", body: String(text.prefix(80)))
        }

        state = .idle
        HUDManager.shared.showPasted(chars: text.count)
    }

    func quitCleanup() {
        isQuitting = true
        recordProcess?.interrupt()
        if let path = audioPath {
            try? FileManager.default.removeItem(atPath: path)
            audioPath = nil
        }
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            if let proc = self.recordProcess, proc.isRunning {
                Thread.sleep(forTimeInterval: 1.0)
                kill(proc.processIdentifier, SIGTERM)
            }
        }
        transcribeProcess?.terminate()
        stopServerSync()

        HUDManager.shared.hide()
    }
}
