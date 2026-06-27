import Combine
import AppKit
import QuartzCore

class HUDManager: ObservableObject {
    static let shared = HUDManager()

    @Published var mode: Mode = .hidden
    @Published var elapsed: Double = 0
    @Published var audioLevel: Double = 0
    @Published var audioHistory: [Double] = Array(repeating: 0, count: 20)
    @Published var opacity: Double = 0
    @Published var scale: CGFloat = 0.94

    enum Mode: Equatable {
        case hidden
        case recording
        case transcribing
        case pasted(String)
    }

    private var panel: NSPanel?
    private var contentBackground: NSView?
    private var symbolContainer: NSView?
    private var symbolView: NSImageView?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var meterTrackLayer: CALayer?
    private var meterFillLayer: CALayer?
    private var activityRingLayer: CAShapeLayer?
    private var timer: Timer?
    private var startTime: Date?
    private var hideToken: UUID?
    private var renderedPresentationKind: String?

    private init() {}

    private struct HUDPresentation {
        let kind: String
        let title: String
        let detail: String
        let symbolName: String
        let accent: NSColor
        let background: NSColor
        let border: NSColor
    }

    func pushAudioLevel(_ level: Double) {
        DispatchQueue.main.async {
            let clamped = min(max(level, 0), 1)
            self.audioLevel = clamped
            self.audioHistory.removeFirst()
            self.audioHistory.append(clamped)
            if case .recording = self.mode {
                self.updateMeter(level: clamped, animated: true)
            }
        }
    }

    func showRecording() {
        DispatchQueue.main.async {
            self.mode = .recording
            self.startTime = Date()
            self.audioHistory = Array(repeating: 0, count: 20)
            self.startTimer()
            self.showPanel()
        }
    }

    func showTranscribing() {
        DispatchQueue.main.async {
            self.mode = .transcribing
            self.audioLevel = 0
            self.startTime = Date()
            self.startTimer()
            self.showPanel()
        }
    }

    func hide() {
        DispatchQueue.main.async {
            guard self.mode != .hidden || self.opacity > 0.01 else { return }
            self.stopTimer()
            let token = UUID()
            self.hideToken = token
            self.opacity = 0
            self.scale = 0.94
            let panel = self.panel
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel?.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self = self, self.hideToken == token else { return }
                self.mode = .hidden
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 0
                self.renderedPresentationKind = nil
                self.stopActivityAnimation()
            }
        }
    }

    func showPasted(chars: Int) {
        DispatchQueue.main.async {
            self.mode = .pasted("Pasted (\(chars) chars)")
            self.audioLevel = 0
            self.stopTimer()
            self.showPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, case .pasted = self.mode else { return }
                self.hide()
            }
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let start = self.startTime {
                self.elapsed = Date().timeIntervalSince(start)
                self.updatePanelContent()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsed = 0
    }

    func movePanelBy(delta: CGSize) {
        guard let panel = panel else { return }
        var frame = panel.frame
        frame.origin.x += delta.width
        frame.origin.y -= delta.height
        panel.setFrame(frame, display: true)
    }

    func savePanelPosition() {
        guard let panel = panel else { return }
        UserDefaults.standard.set(Double(panel.frame.origin.x), forKey: "hudPosX")
        UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: "hudPosY")
    }

    private func showPanel() {
        hideToken = nil
        if panel == nil {
            createPanel()
        }
        let wasVisible = panel?.isVisible == true
        updatePanelContent(animated: wasVisible)
        if wasVisible {
            panel?.orderFrontRegardless()
            panel?.alphaValue = 1.0
        } else {
            panel?.alphaValue = 0
            panel?.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel?.animator().alphaValue = 1.0
            }
        }
        self.opacity = 1.0
        self.scale = 1.0
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize()),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let contentView = NSView(frame: NSRect(origin: .zero, size: panelSize()))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        let background = NSView(frame: NSRect(x: 8, y: 8, width: 344, height: 132))
        background.wantsLayer = true
        background.layer?.cornerRadius = 48
        background.layer?.backgroundColor = NimbusTheme.nsPanelBackground.cgColor
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.62).cgColor
        background.layer?.borderWidth = 1
        background.layer?.shadowColor = NimbusTheme.nsSky.withAlphaComponent(0.55).cgColor
        background.layer?.shadowOpacity = 0.24
        background.layer?.shadowRadius = 40
        background.layer?.shadowOffset = NSSize(width: 0, height: -16)

        let symbolContainer = NSView(frame: NSRect(x: 28, y: 32, width: 68, height: 68))
        symbolContainer.wantsLayer = true
        symbolContainer.layer?.cornerRadius = 25
        symbolContainer.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.50).cgColor
        symbolContainer.layer?.borderColor = NimbusTheme.nsSky.withAlphaComponent(0.24).cgColor
        symbolContainer.layer?.borderWidth = 1
        symbolContainer.layer?.shadowColor = NimbusTheme.nsSky.cgColor
        symbolContainer.layer?.shadowOpacity = 0.30
        symbolContainer.layer?.shadowRadius = 18
        symbolContainer.layer?.shadowOffset = .zero

        let symbolView = NSImageView(frame: NSRect(x: 10, y: 10, width: 48, height: 48))
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolContainer.addSubview(symbolView)

        let activityRing = CAShapeLayer()
        activityRing.frame = symbolContainer.bounds
        activityRing.path = CGPath(ellipseIn: CGRect(x: 6, y: 6, width: 56, height: 56), transform: nil)
        activityRing.fillColor = NSColor.clear.cgColor
        activityRing.lineWidth = 2
        activityRing.opacity = 0
        activityRing.strokeColor = NimbusTheme.nsSky.withAlphaComponent(0.35).cgColor
        symbolContainer.layer?.insertSublayer(activityRing, at: 0)

        let title = NSTextField(labelWithString: "Nimbus VTT")
        title.frame = NSRect(x: 116, y: 76, width: 208, height: 30)
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = NimbusTheme.nsFrost
        title.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(labelWithString: "")
        detail.frame = NSRect(x: 118, y: 43, width: 206, height: 23)
        detail.font = .systemFont(ofSize: 15, weight: .medium)
        detail.textColor = NimbusTheme.nsFrost.withAlphaComponent(0.74)
        detail.lineBreakMode = .byTruncatingTail

        let meterTrack = CALayer()
        meterTrack.frame = CGRect(x: 118, y: 27, width: 190, height: 4)
        meterTrack.cornerRadius = 2
        meterTrack.backgroundColor = NimbusTheme.nsFrost.withAlphaComponent(0.10).cgColor
        meterTrack.opacity = 0

        let meterFill = CALayer()
        meterFill.frame = CGRect(x: 0, y: 0, width: 0, height: 4)
        meterFill.cornerRadius = 2
        meterFill.backgroundColor = NimbusTheme.nsRecord.cgColor
        meterTrack.addSublayer(meterFill)

        background.layer?.addSublayer(meterTrack)
        background.addSubview(symbolContainer)
        background.addSubview(title)
        background.addSubview(detail)
        contentView.addSubview(background)
        panel.contentView = contentView

        self.panel = panel
        self.contentBackground = background
        self.symbolContainer = symbolContainer
        self.symbolView = symbolView
        self.titleLabel = title
        self.detailLabel = detail
        self.meterTrackLayer = meterTrack
        self.meterFillLayer = meterFill
        self.activityRingLayer = activityRing
        updatePanelContent()

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { _ in
            let frame = panel.frame
            UserDefaults.standard.set(Double(frame.origin.x), forKey: "hudPosX")
            UserDefaults.standard.set(Double(frame.origin.y), forKey: "hudPosY")
        }

        positionPanel()
    }

    private func updatePanelContent(animated: Bool = false) {
        let presentation = presentation(for: mode)
        let didChangeKind = renderedPresentationKind != presentation.kind
        renderedPresentationKind = presentation.kind

        applyPanelAppearance(presentation, animated: animated && didChangeKind)
        if didChangeKind {
            applyActivityState(presentation, animated: animated)
        }
        guard animated && didChangeKind else {
            applyPanelText(presentation)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            titleLabel?.animator().alphaValue = 0
            detailLabel?.animator().alphaValue = 0
            symbolView?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self = self else { return }
            guard self.renderedPresentationKind == presentation.kind else { return }
            self.applyPanelText(presentation)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                self.titleLabel?.animator().alphaValue = 1
                self.detailLabel?.animator().alphaValue = 1
                self.symbolView?.animator().alphaValue = 1
            }
        }
    }

    private func applyPanelText(_ presentation: HUDPresentation) {
        titleLabel?.stringValue = presentation.title
        detailLabel?.stringValue = presentation.detail
        titleLabel?.textColor = NimbusTheme.nsFrost
        detailLabel?.textColor = NimbusTheme.nsFrost.withAlphaComponent(0.70)
        symbolView?.contentTintColor = presentation.accent
        if presentation.kind == "recording", let image = NSImage(named: "AppIcon") {
            symbolView?.image = image
        } else if let image = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: presentation.title) {
            image.isTemplate = true
            symbolView?.image = image
        }
    }

    private func applyPanelAppearance(_ presentation: HUDPresentation, animated: Bool) {
        let changes = { [weak self] in
            self?.contentBackground?.layer?.backgroundColor = presentation.background.cgColor
            self?.contentBackground?.layer?.borderColor = presentation.border.cgColor
            self?.contentBackground?.layer?.shadowColor = presentation.accent.withAlphaComponent(0.26).cgColor
            self?.symbolContainer?.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.50).cgColor
            self?.symbolContainer?.layer?.borderColor = presentation.accent.withAlphaComponent(0.24).cgColor
            self?.activityRingLayer?.strokeColor = presentation.accent.withAlphaComponent(0.42).cgColor
        }

        guard animated else {
            changes()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            changes()
        }
    }

    private func applyActivityState(_ presentation: HUDPresentation, animated: Bool) {
        meterFillLayer?.backgroundColor = presentation.accent.cgColor
        activityRingLayer?.strokeColor = presentation.accent.withAlphaComponent(0.42).cgColor

        stopActivityAnimation()

        switch presentation.kind {
        case "recording":
            activityRingLayer?.lineDashPattern = nil
            animateLayerOpacity(activityRingLayer, to: 0.72, duration: animated ? 0.18 : 0.0)
            animateLayerOpacity(meterTrackLayer, to: 1, duration: animated ? 0.18 : 0.0)
            updateMeter(level: max(audioLevel, 0.08), animated: animated)
            startRecordingPulse()
        case "transcribing":
            activityRingLayer?.lineDashPattern = [9, 7]
            animateLayerOpacity(activityRingLayer, to: 0.86, duration: animated ? 0.18 : 0.0)
            animateLayerOpacity(meterTrackLayer, to: 1, duration: animated ? 0.18 : 0.0)
            startTranscribingSweep()
            startRingRotation()
            playModeHandoff()
        case "pasted":
            activityRingLayer?.lineDashPattern = nil
            animateLayerOpacity(activityRingLayer, to: 0.58, duration: animated ? 0.18 : 0.0)
            animateLayerOpacity(meterTrackLayer, to: 1, duration: animated ? 0.18 : 0.0)
            updateMeter(level: 1, animated: animated)
            playModeHandoff()
        default:
            animateLayerOpacity(activityRingLayer, to: 0, duration: animated ? 0.14 : 0.0)
            animateLayerOpacity(meterTrackLayer, to: 0, duration: animated ? 0.14 : 0.0)
            updateMeter(level: 0, animated: animated)
        }
    }

    private func updateMeter(level: Double, animated: Bool) {
        guard let track = meterTrackLayer, let fill = meterFillLayer else { return }
        let clamped = min(max(level, 0), 1)
        let width = max(8, track.bounds.width * CGFloat(clamped))
        let changes = {
            fill.frame = CGRect(x: 0, y: 0, width: width, height: track.bounds.height)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(animated ? 0.08 : 0.0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        changes()
        CATransaction.commit()
    }

    private func startRecordingPulse() {
        guard let ring = activityRingLayer else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.36
        opacity.toValue = 0.82
        opacity.duration = 0.86
        opacity.autoreverses = true
        opacity.repeatCount = .infinity
        opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(opacity, forKey: "recordingOpacity")

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.94
        scale.toValue = 1.06
        scale.duration = 0.86
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ring.add(scale, forKey: "recordingScale")
    }

    private func startTranscribingSweep() {
        guard let track = meterTrackLayer, let fill = meterFillLayer else { return }
        let segmentWidth: CGFloat = 52

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.bounds = CGRect(x: 0, y: 0, width: segmentWidth, height: track.bounds.height)
        fill.position = CGPoint(x: -segmentWidth / 2, y: track.bounds.midY)
        CATransaction.commit()

        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -segmentWidth / 2
        sweep.toValue = track.bounds.width + segmentWidth / 2
        sweep.duration = 1.05
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fill.add(sweep, forKey: "transcribingSweep")
    }

    private func startRingRotation() {
        guard let ring = activityRingLayer else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 1.25
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.add(rotation, forKey: "transcribingRotation")
    }

    private func playModeHandoff() {
        guard let layer = symbolContainer?.layer else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1.0, 1.08, 0.98, 1.0]
        bounce.keyTimes = [0, 0.34, 0.72, 1]
        bounce.duration = 0.32
        bounce.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeOut)
        ]
        layer.add(bounce, forKey: "modeHandoff")
    }

    private func stopActivityAnimation() {
        activityRingLayer?.removeAllAnimations()
        meterFillLayer?.removeAnimation(forKey: "transcribingSweep")
    }

    private func animateLayerOpacity(_ layer: CALayer?, to value: Float, duration: TimeInterval) {
        guard let layer = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(duration == 0)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer.opacity = value
        CATransaction.commit()
    }

    private func presentation(for mode: Mode) -> HUDPresentation {
        switch mode {
        case .hidden:
            return HUDPresentation(
                kind: "hidden",
                title: "Nimbus VTT",
                detail: "Ready",
                symbolName: "cloud.fill",
                accent: NimbusTheme.nsFrost,
                background: NimbusTheme.nsPanelBackground,
                border: NimbusTheme.nsSky.withAlphaComponent(0.18)
            )
        case .recording:
            return HUDPresentation(
                kind: "recording",
                title: "RECORDING",
                detail: "Style: \(recordingStyleLabel())",
                symbolName: "mic.fill",
                accent: NimbusTheme.nsRecord,
                background: NimbusTheme.nsPanelBackground,
                border: NimbusTheme.nsRecord.withAlphaComponent(0.26)
            )
        case .transcribing:
            return HUDPresentation(
                kind: "transcribing",
                title: "TRANSCRIBING",
                detail: "Processing audio",
                symbolName: "cloud.fill",
                accent: NimbusTheme.nsSky,
                background: NimbusTheme.nsPanelBackgroundDeep,
                border: NimbusTheme.nsSky.withAlphaComponent(0.34)
            )
        case .pasted:
            return HUDPresentation(
                kind: "pasted",
                title: "PASTED",
                detail: "Copied and ready",
                symbolName: "checkmark.circle.fill",
                accent: NimbusTheme.nsSuccess,
                background: NimbusTheme.nsPanelBackground,
                border: NimbusTheme.nsSuccess.withAlphaComponent(0.32)
            )
        }
    }

    private func recordingStyleLabel() -> String {
        switch AppState.shared.settings?.postprocessMode ?? AppSettings.defaultPostprocessMode {
        case "off":
            return "Raw"
        case "natural_prose":
            return "Natural prose"
        case "code_aware":
            return "Code aware"
        case "minimal":
            return "Minimal"
        default:
            return "Agent handoff"
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func panelSize() -> NSSize {
        NSSize(width: 360, height: 148)
    }

    private func positionPanel() {
        guard let panel = panel else { return }

        let ud = UserDefaults.standard
        if let x = ud.object(forKey: "hudPosX") as? Double,
           let y = ud.object(forKey: "hudPosY") as? Double,
           let origin = clampedOrigin(NSPoint(x: x, y: y), size: panel.frame.size, requireVisible: true) {
            panel.setFrameOrigin(origin)
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screen = targetScreen else { return }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        var originX = visible.midX - size.width / 2
        var originY = visible.maxY - size.height - 12

        originX = max(visible.minX + 4, min(originX, visible.maxX - size.width - 4))
        originY = max(visible.minY + 4, min(originY, visible.maxY - size.height - 4))

        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }

    private func clampedOrigin(_ origin: NSPoint, size: NSSize, requireVisible: Bool = false) -> NSPoint? {
        let proposed = NSRect(origin: origin, size: size)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(proposed) }) ?? NSScreen.main else {
            return nil
        }
        if requireVisible && !screen.visibleFrame.intersects(proposed) {
            return nil
        }

        let visible = screen.visibleFrame
        let minX = visible.minX + 4
        let maxX = max(minX, visible.maxX - size.width - 4)
        let minY = visible.minY + 4
        let maxY = max(minY, visible.maxY - size.height - 4)
        return NSPoint(
            x: max(minX, min(origin.x, maxX)),
            y: max(minY, min(origin.y, maxY))
        )
    }
}
