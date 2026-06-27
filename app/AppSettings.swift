import Foundation
import Combine
import ServiceManagement

class AppSettings: ObservableObject {
    static let defaultInitialPrompt =
        "This is a dictated note for a macOS productivity app. " +
        "Transcribe exactly what the speaker says, using proper punctuation, " +
        "capitalization, and grammar. Preserve technical terms, identifiers, " +
        "URLs, file paths, and email addresses verbatim. Use em-dashes for " +
        "pauses, not hyphens. Do not add filler such as 'um', 'uh', 'like', " +
        "or 'you know'. Do not add sign-offs like 'thank you' or 'thanks'. " +
        "Keep the output concise and ready to paste into a document or chat."

    static let defaultPostprocessMode = "agent_handoff"
    static let defaultPrimaryHotkey = "f1"
    static let defaultSecondaryHotkey = "option+space"

    private static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoiceToText")
    private static var configURL: URL {
        supportDir.appendingPathComponent("config.json")
    }

    private let supportDir = AppSettings.supportDir
    private var configURL: URL { AppSettings.configURL }

    var venvPythonPath: String {
        supportDir.appendingPathComponent("venv/bin/python").path
    }

    var cliScriptPath: String {
        Bundle.main.path(forResource: "voice_to_text", ofType: "py") ?? ""
    }

    var isSetupComplete: Bool {
        FileManager.default.fileExists(atPath: venvPythonPath) && !cliScriptPath.isEmpty
    }

    @Published var model: String
    @Published var language: String
    @Published var outputMode: String
    @Published var notificationsEnabled: Bool
    @Published var soundEnabled: Bool
    @Published var soundVolume: Double
    @Published var launchAtLogin: Bool
    @Published var showWindowOnLaunch: Bool
    @Published var vadThreshold: Double
    @Published var initialPrompt: String
    @Published var postprocessMode: String
    @Published var inputDeviceIndex: Int?
    @Published var primaryHotkey: String
    @Published var secondaryHotkey: String
    @Published var configError: String = ""

    let availableModels: [(id: String, label: String)] = [
        ("mlx-community/whisper-large-v3-turbo", "Large v3 Turbo (accurate)"),
        ("mlx-community/whisper-large-v3-mlx", "Large v3"),
        ("mlx-community/whisper-medium-mlx", "Medium"),
        ("mlx-community/whisper-small.en-mlx", "Small English (fast)"),
        ("mlx-community/whisper-small-mlx", "Small"),
        ("mlx-community/whisper-tiny", "Tiny (fastest)")
    ]

    let availableLanguages: [(String, String)] = [
        ("Auto", ""),
        ("English", "en"),
        ("Spanish", "es"),
        ("French", "fr"),
        ("German", "de"),
        ("Italian", "it"),
        ("Portuguese", "pt"),
        ("Japanese", "ja"),
        ("Chinese", "zh"),
        ("Korean", "ko")
    ]

    var postprocessModeLabel: String {
        availablePostprocessModes.first { $0.id == postprocessMode }?.label ?? postprocessMode
    }

    let availablePostprocessModes: [(id: String, label: String)] = [
        ("off", "Off (raw Whisper output)"),
        ("agent_handoff", "Agent handoff (Recommended)"),
        ("natural_prose", "Natural prose"),
        ("code_aware", "Code/technical aware"),
        ("minimal", "Minimal cleanup")
    ]

    init() {
        model = "mlx-community/whisper-large-v3-turbo"
        language = "en"
        outputMode = "paste"
        notificationsEnabled = true
        soundEnabled = true
        soundVolume = 0.7
        launchAtLogin = false
        showWindowOnLaunch = false
        vadThreshold = 0.005
        initialPrompt = Self.defaultInitialPrompt
        postprocessMode = Self.defaultPostprocessMode
        inputDeviceIndex = nil
        primaryHotkey = Self.defaultPrimaryHotkey
        secondaryHotkey = Self.defaultSecondaryHotkey
        applyConfig(Self.loadConfigDict())
    }

    func reloadFromDisk() {
        applyConfig(Self.loadConfigDict())
    }

    private static func loadConfigDict() -> [String: Any] {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: configURL)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                VTTLogger.log("config load failed", ["reason": "root is not object", "path": configURL.path])
                return [:]
            }
            return dict
        } catch {
            VTTLogger.log("config load failed", ["error": error.localizedDescription, "path": configURL.path])
            return [:]
        }
    }

    private func applyConfig(_ config: [String: Any]) {
        var validationErrors: [String] = []
        let modelIDs = Set(availableModels.map(\.id))
        let languageIDs = Set(availableLanguages.map(\.1))
        let postprocessIDs = Set(availablePostprocessModes.map(\.id))

        model = validatedString(
            config["model"],
            defaultValue: "mlx-community/whisper-large-v3-turbo",
            allowed: modelIDs,
            key: "model",
            errors: &validationErrors
        )
        language = validatedString(
            config["language"],
            defaultValue: "en",
            allowed: languageIDs,
            key: "language",
            errors: &validationErrors
        )
        outputMode = validatedString(
            config["output_mode"],
            defaultValue: "paste",
            allowed: ["paste", "clipboard"],
            key: "output_mode",
            errors: &validationErrors
        )
        notificationsEnabled = config["notifications_enabled"] as? Bool ?? true
        soundEnabled = config["sound_enabled"] as? Bool ?? true
        soundVolume = min(max(config["sound_volume"] as? Double ?? 0.7, 0.0), 1.0)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        showWindowOnLaunch = config["show_window_on_launch"] as? Bool ?? false
        vadThreshold = min(max(config["vad_threshold"] as? Double ?? 0.005, 0.001), 0.05)
        initialPrompt = (config["initial_prompt"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultInitialPrompt
        postprocessMode = validatedString(
            config["postprocess_mode"],
            defaultValue: Self.defaultPostprocessMode,
            allowed: postprocessIDs,
            key: "postprocess_mode",
            errors: &validationErrors
        )

        if let idx = config["input_device_index"] as? Int {
            inputDeviceIndex = idx
        } else if let idx = config["input_device_index"] as? NSNumber {
            inputDeviceIndex = idx.intValue
        } else {
            inputDeviceIndex = nil
        }

        primaryHotkey = validatedHotkey(
            config["primary_hotkey"] as? String,
            defaultValue: Self.defaultPrimaryHotkey,
            key: "primary_hotkey",
            errors: &validationErrors
        )
        secondaryHotkey = validatedHotkey(
            config["secondary_hotkey"] as? String,
            defaultValue: Self.defaultSecondaryHotkey,
            key: "secondary_hotkey",
            errors: &validationErrors
        )

        configError = validationErrors.joined(separator: "\n")
        for error in validationErrors {
            VTTLogger.log("config value invalid", ["error": error])
        }
    }

    private func validatedString(
        _ value: Any?,
        defaultValue: String,
        allowed: Set<String>,
        key: String,
        errors: inout [String]
    ) -> String {
        guard let string = value as? String, allowed.contains(string) else {
            if value != nil {
                errors.append("\(key) invalid; using \(defaultValue)")
            }
            return defaultValue
        }
        return string
    }

    private func validatedHotkey(
        _ value: String?,
        defaultValue: String,
        key: String,
        errors: inout [String]
    ) -> String {
        guard let value = value, Self.isValidHotkeySpec(value) else {
            if value != nil {
                errors.append("\(key) invalid; using \(defaultValue)")
            }
            return defaultValue
        }
        return value
    }

    static func isValidHotkeySpec(_ spec: String) -> Bool {
        let parts = spec
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let key = parts.last else { return false }

        let validKeys = Set([
            "space",
            "f1", "f2", "f3", "f4", "f5", "f6",
            "f7", "f8", "f9", "f10", "f11", "f12"
        ])
        guard validKeys.contains(key) else { return false }

        let validModifiers = Set(["option", "alt", "command", "cmd", "control", "ctrl", "shift"])
        return parts.dropLast().allSatisfy { validModifiers.contains($0) }
    }

    func save() {
        var config: [String: Any] = [:]

        do {
            if FileManager.default.fileExists(atPath: configURL.path) {
                let data = try Data(contentsOf: configURL)
                if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    config = dict
                } else {
                    VTTLogger.log("config save read skipped", ["reason": "root is not object"])
                }
            }
        } catch {
            configError = "Could not read existing config: \(error.localizedDescription)"
            VTTLogger.log("config save read failed", ["error": error.localizedDescription])
        }

        config["model"] = model
        config["language"] = language.isEmpty ? nil : language
        config["output_mode"] = outputMode
        config["notifications_enabled"] = notificationsEnabled
        config["sound_enabled"] = soundEnabled
        config["sound_volume"] = soundVolume
        config["show_window_on_launch"] = showWindowOnLaunch
        config["vad_threshold"] = vadThreshold
        config["initial_prompt"] = initialPrompt.isEmpty ? nil : initialPrompt
        config["postprocess_mode"] = postprocessMode
        if let idx = inputDeviceIndex {
            config["input_device_index"] = idx
        } else {
            config.removeValue(forKey: "input_device_index")
        }
        config["primary_hotkey"] = primaryHotkey
        config["secondary_hotkey"] = secondaryHotkey

        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
            try data.write(to: configURL)
            if configError.hasPrefix("Could not") {
                configError = ""
            }
            VTTLogger.log("config saved")
        } catch {
            configError = "Could not save config: \(error.localizedDescription)"
            VTTLogger.log("config save failed", ["error": error.localizedDescription])
        }

        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
                VTTLogger.log("login item registered successfully")
            } else {
                try SMAppService.mainApp.unregister()
                VTTLogger.log("login item unregistered successfully")
            }
        } catch {
            VTTLogger.log("login item change failed", ["error": error.localizedDescription])
        }
    }
}
