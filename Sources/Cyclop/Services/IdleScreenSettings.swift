import AppKit
import SwiftUI

/// Idle Screen look: which ASCII animation plays, and the accent colour for each.
@MainActor
final class IdleScreenSettings: ObservableObject {
    static let shared = IdleScreenSettings()

    enum Style: String, CaseIterable, Identifiable {
        case agents, matrix, life, stars, portrait

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .agents: "Agents"
            case .matrix: "Matrix"
            case .life: "Life"
            case .stars: "Stars"
            case .portrait: "Portrait"
            }
        }

        var defaultHex: String {
            switch self {
            case .agents: "#59EB8C"
            case .matrix: "#33FF66"
            case .life: "#7DFFB3"
            case .stars: "#F0E6A8"
            case .portrait: "#8EC5FF"
            }
        }
    }

    private static let styleKey = "idleScreen.style"
    private static let colorsKey = "idleScreen.colors"

    @Published var style: Style {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey) }
    }

    @Published private(set) var hexByStyle: [String: String]

    var accent: Color { color(for: style) }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.styleKey)
        switch raw {
        case "waves", "fireflies": style = .life
        case "tunnel", "helix": style = .portrait
        case let value?:
            style = Style(rawValue: value) ?? .agents
        default:
            style = .agents
        }
        hexByStyle = UserDefaults.standard.dictionary(forKey: Self.colorsKey) as? [String: String] ?? [:]
        migrateColorKeys()
    }

    private func migrateColorKeys() {
        var next = hexByStyle
        if next["life"] == nil {
            next["life"] = next["fireflies"] ?? next["waves"]
        }
        if next["portrait"] == nil {
            next["portrait"] = next["helix"] ?? next["tunnel"]
        }
        next = next.compactMapValues { $0 }
        if next != hexByStyle {
            hexByStyle = next
            UserDefaults.standard.set(hexByStyle, forKey: Self.colorsKey)
        }
    }

    func color(for style: Style) -> Color {
        Color(hex: hexByStyle[style.rawValue] ?? style.defaultHex) ?? Color(hex: style.defaultHex)!
    }

    func hex(for style: Style) -> String {
        hexByStyle[style.rawValue] ?? style.defaultHex
    }

    func setHex(_ hex: String, for style: Style) {
        let normalized = hex.uppercased()
        if hexByStyle[style.rawValue]?.uppercased() == normalized { return }
        var next = hexByStyle
        next[style.rawValue] = normalized
        hexByStyle = next
        UserDefaults.standard.set(next, forKey: Self.colorsKey)
    }

    func setColor(_ color: Color, for style: Style) {
        guard let hex = color.hexString else { return }
        setHex(hex, for: style)
    }

    /// The stored colour as the two things the pane actually lets one move.
    /// Brightness comes back untouched so that editing a hue cannot quietly
    /// wash out a colour that was picked dim on purpose.
    func hsb(for style: Style) -> (hue: Double, saturation: Double, brightness: Double) {
        let ns = NSColor(color(for: style)).usingColorSpace(.sRGB) ?? .white
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }

    func setHSB(hue: Double, saturation: Double, brightness: Double, for style: Style) {
        let color = NSColor(
            hue: CGFloat(hue),
            saturation: CGFloat(saturation),
            brightness: CGFloat(brightness),
            alpha: 1
        )
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        setHex(String(format: "#%02X%02X%02X", r, g, b), for: style)
    }
}

private extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt64(value, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255,
            opacity: 1
        )
    }

    var hexString: String? {
        let ns = NSColor(self)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
