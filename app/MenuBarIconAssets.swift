import AppKit
import SwiftUI

enum MenuBarIconAssets {
    private static var cache: [String: NSImage] = [:]

    static func image(for state: RecorderManager.State) -> NSImage? {
        let name: String
        switch state {
        case .idle: name = "MenuBarIdle"
        case .recording: name = "MenuBarRecording"
        case .transcribing: name = "MenuBarTranscribing"
        }
        return load(named: name, template: state != .recording)
    }

    private static func load(named name: String, template: Bool) -> NSImage? {
        let key = "\(name)-\(template)"
        if let cached = cache[key] { return cached }

        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = template
        cache[key] = image
        return image
    }
}

struct MenuBarIcon: View {
    let state: RecorderManager.State
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        Group {
            if let nsImage = MenuBarIconAssets.image(for: state) {
                Image(nsImage: nsImage)
                    .renderingMode(state == .recording ? .original : .template)
                    .frame(width: 18, height: 18)
                    .opacity(state == .recording ? pulseOpacity : 1.0)
            } else {
                Image(systemName: fallbackSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(fallbackTint)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 18, height: 18)
                    .opacity(state == .recording ? pulseOpacity : 1.0)
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .onAppear { startPulseIfNeeded() }
            .onChangeCompat(of: state) { _ in startPulseIfNeeded() }
    }

    private func startPulseIfNeeded() {
        guard state == .recording else {
            pulseOpacity = 1.0
            return
        }
        pulseOpacity = 1.0
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.5
        }
    }

    private var fallbackSymbol: String {
        switch state {
        case .idle: return "cloud.fill"
        case .recording: return "waveform.circle.fill"
        case .transcribing: return "cloud.fill"
        }
    }

    private var fallbackTint: Color {
        switch state {
        case .idle: return NimbusTheme.frost
        case .recording: return NimbusTheme.record
        case .transcribing: return NimbusTheme.sky
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: return "Nimbus VTT idle"
        case .recording: return "Nimbus VTT recording"
        case .transcribing: return "Nimbus VTT transcribing"
        }
    }
}
