import AppKit
import ApplicationServices

class PasteManager {
    static let shared = PasteManager()

    private var frontmostApp: NSRunningApplication?
    private var savedClipboard: [(NSPasteboard.PasteboardType, Data)]?
    private var clipboardGeneration = 0
    private let clipboardRestoreDelay: TimeInterval = 1.5
    private let activationDelayMicros: useconds_t = 250_000
    private let focusRetryCount = 3
    private let focusRetryDelayMicros: useconds_t = 120_000

    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXTextAttachment",
        "AXWebArea",
        "AXSearchField",
        "AXScrollArea",
    ]

    private init() {}

    func captureFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        guard !isSelf(app) else {
            VTTLogger.log("capture skipped", ["reason": "frontmost is self"])
            return
        }
        frontmostApp = app
        VTTLogger.log(
            "captured frontmost app",
            ["name": app.localizedName ?? "unknown", "bundle": app.bundleIdentifier ?? "unknown", "pid": app.processIdentifier]
        )
    }

    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): kCFBooleanTrue] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func saveClipboard() {
        clipboardGeneration += 1
        let pb = NSPasteboard.general
        var saved: [(NSPasteboard.PasteboardType, Data)] = []
        if let types = pb.types {
            for type in types {
                if let data = pb.data(forType: type) {
                    saved.append((type, data))
                }
            }
        }
        savedClipboard = saved.isEmpty ? nil : saved
        VTTLogger.log("clipboard saved", ["items": saved.count, "gen": clipboardGeneration])
    }

    func restoreClipboard() {
        guard let saved = savedClipboard else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        for (type, data) in saved {
            pb.setData(data, forType: type)
        }
        VTTLogger.log("clipboard restored", ["items": saved.count])
        savedClipboard = nil
    }

    func setClipboard(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        VTTLogger.log("clipboard set", ["chars": text.count])
    }

    func paste(text: String) -> Bool {
        guard isAccessibilityTrusted() else {
            VTTLogger.log("permission missing", ["type": "accessibility"])
            requestAccessibility()
            return false
        }

        guard let app = resolveTargetApp() else {
            VTTLogger.log("paste skipped", ["reason": "no target app"])
            return false
        }

        activate(app)

        // Direct AX insertion — never touches the clipboard.
        if let method = insertDirectly(into: app, text: text) {
            VTTLogger.log("paste success", ["method": method])
            return true
        }

        // Clipboard + exactly one Cmd+V fallback.
        saveClipboard()
        let restoreGen = clipboardGeneration
        setClipboard(text: text)
        let expectedClipboard = text
        activate(app)

        if simulateCommandV(into: app, expectedText: expectedClipboard) {
            scheduleClipboardRestore(generation: restoreGen)
            VTTLogger.log("paste success", ["method": "cmd_v"])
            return true
        }

        savedClipboard = nil
        VTTLogger.log("paste failed", ["target": app.localizedName ?? "unknown"])
        return false
    }

    // MARK: - Target resolution

    private func resolveTargetApp() -> NSRunningApplication? {
        if let stored = frontmostApp, !stored.isTerminated, !isSelf(stored) {
            return stored
        }

        if let current = NSWorkspace.shared.frontmostApplication,
           !current.isTerminated,
           !isSelf(current) {
            VTTLogger.log("paste target fallback", [
                "name": current.localizedName ?? "unknown",
                "reason": "captured target unavailable"
            ])
            frontmostApp = current
            return current
        }

        return nil
    }

    private func isSelf(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private func activate(_ app: NSRunningApplication) {
        _ = app.activate(options: [.activateAllWindows])
        usleep(activationDelayMicros)
    }

    // MARK: - Direct AX insertion

    private func insertDirectly(into app: NSRunningApplication, text: String) -> String? {
        for attempt in 1...focusRetryCount {
            if attempt > 1 {
                activate(app)
                usleep(focusRetryDelayMicros)
            }

            guard let element = focusedElement(in: app) else {
                VTTLogger.log("paste ax no focus", ["attempt": attempt])
                continue
            }

            if insertViaSelectedText(element, text: text) {
                return "ax_selected_text"
            }

            if insertViaValue(element, text: text) {
                return "ax_value"
            }

            // Try editable descendant (Terminal, some Electron views)
            if let child = firstEditableChild(of: element),
               insertViaSelectedText(child, text: text) || insertViaValue(child, text: text) {
                return "ax_descendant"
            }
        }
        return nil
    }

    private func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef {
            guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
            return (focused as! AXUIElement)
        }

        let system = AXUIElementCreateSystemWide()
        var systemFocusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &systemFocusedRef) == .success,
              let systemFocused = systemFocusedRef else {
            return nil
        }

        guard CFGetTypeID(systemFocused) == AXUIElementGetTypeID() else { return nil }
        let element = systemFocused as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier else {
            return nil
        }
        return element
    }

    private func elementRole(_ element: AXUIElement) -> String? {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success else {
            return nil
        }
        return roleRef as? String
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        if let role = elementRole(element), Self.editableRoles.contains(role) {
            return true
        }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }

        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }

        return false
    }

    private func insertViaSelectedText(_ element: AXUIElement, text: String) -> Bool {
        guard isEditable(element) else { return false }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }

        let err = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return err == .success
    }

    private func insertViaValue(_ element: AXUIElement, text: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }

        var valueRef: CFTypeRef?
        let currentValue: String
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
           let value = valueRef as? String {
            currentValue = value
        } else {
            currentValue = ""
        }

        let insertLocation = selectedTextLocation(in: element, fallback: currentValue.count)
        let safeLocation = min(max(0, insertLocation), currentValue.count)
        let index = currentValue.index(currentValue.startIndex, offsetBy: safeLocation)
        var newValue = currentValue
        newValue.insert(contentsOf: text, at: index)

        let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newValue as CFTypeRef)
        return err == .success
    }

    private func firstEditableChild(of element: AXUIElement) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if isEditable(child) {
                return child
            }
            if let found = firstEditableChild(of: child) {
                return found
            }
        }
        return nil
    }

    private func selectedTextLocation(in element: AXUIElement, fallback: Int) -> Int {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let axValue = rangeRef else {
            return fallback
        }

        guard CFGetTypeID(axValue) == AXValueGetTypeID() else { return fallback }
        let typedValue = axValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(typedValue) == .cfRange,
              AXValueGetValue(typedValue, .cfRange, &range) else {
            return fallback
        }
        return range.location
    }

    // MARK: - Cmd+V fallback

    private func simulateCommandV(into app: NSRunningApplication, expectedText: String) -> Bool {
        activate(app)

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            VTTLogger.log("cmd+v aborted", ["reason": "focus shifted before paste"])
            return false
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        cmdUp?.flags = .maskCommand

        cmdDown?.post(tap: .cgSessionEventTap)
        cmdUp?.post(tap: .cgSessionEventTap)

        // Verify the paste succeeded by checking the clipboard reflects our text.
        usleep(150_000)
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        let ok = pasted == expectedText
        if !ok {
            VTTLogger.log("cmd+v verification failed", ["expected_chars": expectedText.count, "actual_chars": pasted.count])
        }
        return ok
    }

    private func scheduleClipboardRestore(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) { [weak self] in
            guard let self = self, self.clipboardGeneration == generation else { return }
            self.restoreClipboard()
        }
    }
}
