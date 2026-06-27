import Carbon
import AppKit

private let hotkeyCallback: @convention(c) (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus = { _, event, userData in
    guard let event = event, let userData = userData else { return noErr }

    var hotkeyId = EventHotKeyID()
    let status = withUnsafeMutablePointer(to: &hotkeyId) { ptr -> OSStatus in
        var actualSize: UInt = 0
        return GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            Int(MemoryLayout<EventHotKeyID>.size),
            &actualSize,
            UnsafeMutableRawPointer(ptr)
        )
    }

    if status == noErr {
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async {
            manager.handleHotkey(id: hotkeyId.id)
        }
    }

    return noErr
}

struct HotkeyBinding: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String
}

class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    static let defaultPrimary = "f1"
    static let defaultSecondary = "option+space"

    @Published var primaryRegistered = false
    @Published var secondaryRegistered = false
    @Published var primaryError = ""
    @Published var secondaryError = ""
    @Published var primaryHotkeyLabel = "F1"
    @Published var secondaryHotkeyLabel = "Option+Space"
    @Published var fnKeyStandard = false

    weak var recorder: RecorderManager?
    weak var settings: AppSettings?

    private var eventHandler: EventHandlerRef?
    private var primaryRef: EventHotKeyRef?
    private var secondaryRef: EventHotKeyRef?

    private let hotkeySignature: OSType = 0x46545431
    private let primaryId: UInt32 = 1
    private let secondaryId: UInt32 = 2

    private init() {}

    func configure(settings: AppSettings) {
        self.settings = settings
        register()
    }

    func configureWithoutSettings() {
        VTTLogger.log("hotkey configure skipped", ["reason": "no settings"])
    }

    func register() {
        unregister()
        installHandler()
        registerPrimary()
        registerSecondary()
        checkFnState()
    }

    func resetToDefaults() {
        settings?.primaryHotkey = Self.defaultPrimary
        settings?.secondaryHotkey = Self.defaultSecondary
        settings?.save()
        register()
    }

    func unregister() {
        if let ref = primaryRef { UnregisterEventHotKey(ref); primaryRef = nil }
        if let ref = secondaryRef { UnregisterEventHotKey(ref); secondaryRef = nil }
        if let handler = eventHandler { RemoveEventHandler(handler); eventHandler = nil }
        primaryRegistered = false
        secondaryRegistered = false
        VTTLogger.log("hotkey unregistered")
    }

    private func checkFnState() {
        fnKeyStandard = UserDefaults.standard.bool(forKey: "com.apple.keyboard.fnState")
        VTTLogger.log("fn_key_state", ["standard": fnKeyStandard])
        if !fnKeyStandard, primaryHotkeyLabel.uppercased().hasPrefix("F") {
            VTTLogger.log("hotkey hint", ["msg": "F-keys are media keys. Enable System Settings > Keyboard > Keyboard Shortcuts > Function Keys > Use F1, F2, etc. as standard function keys. External keyboards (Razer Cynosa V2) typically send F1 directly without this setting."])
        }
    }

    private func installHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyCallback,
            1,
            &spec,
            selfPtr,
            &handler
        )
        if status != noErr {
            VTTLogger.log("hotkey handler install failed", ["error": status])
        } else {
            eventHandler = handler
        }
    }

    private func registerPrimary() {
        let spec = settings?.primaryHotkey ?? Self.defaultPrimary
        guard let binding = Self.parse(spec) else {
            primaryRegistered = false
            primaryError = "unsupported hotkey"
            primaryHotkeyLabel = spec
            VTTLogger.log("hotkey parse failed", ["key": spec])
            return
        }
        primaryHotkeyLabel = binding.label
        let id = EventHotKeyID(signature: hotkeySignature, id: primaryId)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            primaryRef = ref
            primaryRegistered = true
            primaryError = ""
            VTTLogger.log("hotkey registered", ["key": spec, "keycode": binding.keyCode, "modifiers": binding.modifiers])
        } else {
            primaryRegistered = false
            primaryError = "error \(status)"
            VTTLogger.log("hotkey registration failed", ["key": spec, "keycode": binding.keyCode, "error": status])
        }
    }

    private func registerSecondary() {
        let spec = settings?.secondaryHotkey ?? Self.defaultSecondary
        guard let binding = Self.parse(spec) else {
            secondaryRegistered = false
            secondaryError = "unsupported hotkey"
            secondaryHotkeyLabel = spec
            VTTLogger.log("hotkey parse failed", ["key": spec])
            return
        }
        secondaryHotkeyLabel = binding.label
        let id = EventHotKeyID(signature: hotkeySignature, id: secondaryId)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            secondaryRef = ref
            secondaryRegistered = true
            secondaryError = ""
            VTTLogger.log("hotkey registered", ["key": spec, "keycode": binding.keyCode, "modifiers": binding.modifiers])
        } else {
            secondaryRegistered = false
            secondaryError = "error \(status)"
            VTTLogger.log("hotkey registration failed", ["key": spec, "keycode": binding.keyCode, "error": status])
        }
    }

    func handleHotkey(id: UInt32) {
        if id == primaryId {
            VTTLogger.log("hotkey pressed", ["key": settings?.primaryHotkey ?? Self.defaultPrimary])
            recorder?.toggle()
        } else if id == secondaryId {
            VTTLogger.log("hotkey pressed", ["key": settings?.secondaryHotkey ?? Self.defaultSecondary])
            recorder?.toggle()
        }
    }

    static func parse(_ spec: String) -> HotkeyBinding? {
        let normalized = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return nil }

        let keyMap: [String: UInt32] = [
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
            "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
            "f11": 103, "f12": 111,
            "space": 49,
        ]

        let parts = normalized.split(separator: "+").map(String.init)
        var modifiers: UInt32 = 0
        var keyToken = ""

        if parts.count == 1 {
            keyToken = parts[0]
        } else {
            for part in parts.dropLast() {
                switch part {
                case "option", "alt": modifiers |= UInt32(optionKey)
                case "command", "cmd": modifiers |= UInt32(cmdKey)
                case "control", "ctrl": modifiers |= UInt32(controlKey)
                case "shift": modifiers |= UInt32(shiftKey)
                default: return nil
                }
            }
            keyToken = parts.last ?? ""
        }

        guard let keyCode = keyMap[keyToken] else { return nil }

        let label = displayLabel(parts: parts, keyToken: keyToken)

        return HotkeyBinding(keyCode: keyCode, modifiers: modifiers, label: label)
    }

    private static func displayLabel(parts: [String], keyToken: String) -> String {
        var labelParts: [String] = []
        if parts.count > 1 {
            for part in parts.dropLast() {
                switch part {
                case "option", "alt": labelParts.append("Option")
                case "command", "cmd": labelParts.append("Command")
                case "control", "ctrl": labelParts.append("Control")
                case "shift": labelParts.append("Shift")
                default: break
                }
            }
        }

        let keyLabel: String
        if keyToken.hasPrefix("f"), keyToken.count >= 2 {
            keyLabel = "F" + keyToken.dropFirst()
        } else if keyToken == "space" {
            keyLabel = "Space"
        } else {
            keyLabel = keyToken.capitalized
        }
        labelParts.append(keyLabel)
        return labelParts.joined(separator: "+")
    }
}
