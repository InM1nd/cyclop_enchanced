import AppKit
import SwiftUI

struct PickedColor: Equatable, Identifiable {
    var id: String { hex }
    /// sRGB components 0…1
    let red: Double
    let green: Double
    let blue: Double

    var hex: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    var rgbLabel: String {
        let r = Int((red * 255).rounded())
        let g = Int((green * 255).rounded())
        let b = Int((blue * 255).rounded())
        return "\(r), \(g), \(b)"
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt32(value, radix: 16) else { return nil }
        red = Double((int >> 16) & 0xFF) / 255
        green = Double((int >> 8) & 0xFF) / 255
        blue = Double(int & 0xFF) / 255
    }

    init?(nsColor: NSColor) {
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        red = Double(rgb.redComponent)
        green = Double(rgb.greenComponent)
        blue = Double(rgb.blueComponent)
    }
}

/// Screen eyedropper and a short history of picked colours — the Digital
/// Color Meter people leave floating, shrunk into the notch.
@MainActor
final class ColorPickerStore: ObservableObject {
    @Published private(set) var current: PickedColor?
    @Published private(set) var recent: [PickedColor] = []
    @Published private(set) var isSampling = false

    private static let recentKey = "colorPicker.recent"
    private static let recentLimit = 8
    private let defaults = UserDefaults.standard

    init() {
        let stored = defaults.stringArray(forKey: Self.recentKey) ?? []
        recent = stored.compactMap(PickedColor.init(hex:))
        current = recent.first
    }

    func pickFromScreen() {
        guard !isSampling else { return }
        isSampling = true
        // System sampler runs above every window, including ours.
        NSColorSampler().show { [weak self] color in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSampling = false
                guard let color, let picked = PickedColor(nsColor: color) else { return }
                self.apply(picked, copy: true)
            }
        }
    }

    func selectRecent(_ color: PickedColor) {
        apply(color, copy: true)
    }

    func copyHex() {
        guard let current else { return }
        copy(current.hex)
    }

    func copyRGB() {
        guard let current else { return }
        copy(current.rgbLabel)
    }

    private func apply(_ color: PickedColor, copy shouldCopy: Bool) {
        current = color
        var next = recent.filter { $0.hex != color.hex }
        next.insert(color, at: 0)
        if next.count > Self.recentLimit {
            next = Array(next.prefix(Self.recentLimit))
        }
        recent = next
        defaults.set(next.map(\.hex), forKey: Self.recentKey)
        if shouldCopy { copy(color.hex) }
    }

    private func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
