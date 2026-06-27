import AppKit
import SwiftUI

enum NimbusTheme {
    static let cloudNavy = Color(red: 0.99, green: 0.96, blue: 0.90)
    static let midnight = Color(red: 0.92, green: 0.80, blue: 0.62)
    static let storm = Color(red: 0.50, green: 0.39, blue: 0.28)
    static let frost = Color(red: 0.25, green: 0.21, blue: 0.17)
    static let sky = Color(red: 0.82, green: 0.52, blue: 0.16)
    static let success = Color(red: 0.22, green: 0.58, blue: 0.38)
    static let warning = Color(red: 0.82, green: 0.45, blue: 0.12)
    static let record = Color(red: 0.92, green: 0.36, blue: 0.22)
    static let cream = Color(red: 1.0, green: 0.985, blue: 0.94)
    static let parchment = Color(red: 0.95, green: 0.86, blue: 0.69)
    static let cocoa = Color(red: 0.42, green: 0.30, blue: 0.21)

    static let cardFill = Color.white.opacity(0.64)
    static let cardBorder = Color(red: 0.58, green: 0.39, blue: 0.18).opacity(0.16)
    static let elevatedFill = Color.white.opacity(0.78)

    static let nsPanelBackground = NSColor(calibratedRed: 0.995, green: 0.955, blue: 0.86, alpha: 0.96)
    static let nsPanelBackgroundDeep = NSColor(calibratedRed: 0.94, green: 0.80, blue: 0.58, alpha: 0.96)
    static let nsFrost = NSColor(calibratedRed: 0.25, green: 0.21, blue: 0.17, alpha: 1.0)
    static let nsSky = NSColor(calibratedRed: 0.82, green: 0.52, blue: 0.16, alpha: 1.0)
    static let nsSuccess = NSColor(calibratedRed: 0.22, green: 0.58, blue: 0.38, alpha: 1.0)
    static let nsWarning = NSColor(calibratedRed: 0.82, green: 0.45, blue: 0.12, alpha: 1.0)
    static let nsRecord = NSColor(calibratedRed: 0.92, green: 0.36, blue: 0.22, alpha: 1.0)
}
