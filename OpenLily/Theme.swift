//
//  Theme.swift
//  OpenLily
//

import SwiftUI
import AppKit

/// A plain sRGB triple. Ring colors get mixed per depth, so they need real components.
nonisolated struct RGB: Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    static let white = RGB(0xFFFFFF)

    func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    var color: Color { Color(red: r, green: g, blue: b) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

enum Theme {
    static let petals: [RGB] = [
        0xE9738A, 0xF29E6D, 0xE8C15A, 0xB48FE0, 0x6FB59A, 0xE58FB8, 0xF4A98E,
        0xB9C2B4, 0xD2C6B8, 0x8FB3E8, 0xC7A0D8, 0xA3D1B5, 0xF0B0C4,
    ].map { RGB($0) }

    static let paper = Color.dynamic(light: 0xF7F0EA, dark: 0x17140F)
    static let ink = Color.dynamic(light: 0x1F2A24, dark: 0xF4EEE2)
    static let inkSoft = Color.dynamic(light: 0x5B635D, dark: 0xA59D92)
    static let rule = Color.dynamic(light: 0xE6DAD0, dark: 0x2D2721)
    static let smaller = Color.dynamic(light: 0xE4DAD0, dark: 0x564C43)
    static let wilt = Color.dynamic(light: 0xD8CFC4, dark: 0x4A4139)
    static let wiltStroke = Color(hex: 0xC2405E)
    static let pollen = Color(hex: 0xE8B23A)

    static let compost = Color(hex: 0x2E2620)
    static let compostChip = Color(hex: 0x3D332B)
    static let compostText = Color(hex: 0xF4EEE2)
    static let bloom = RGB(0xE9738A)
    static let bloomInk = Color(hex: 0x2A1015)

    static let hidden = RGB(0xBDB4AA)
    static let safe = RGB(0x6FB59A)
    static let review = RGB(0xE8C15A)
}

extension Color {
    init(hex: UInt32) {
        let c = RGB(hex)
        self.init(red: c.r, green: c.g, blue: c.b)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return RGB(isDark ? dark : light).nsColor
        })
    }
}

extension Font {
    /// Stand-in for Fraunces: the system serif (New York) reads the same way.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold, italic: Bool = false) -> Font {
        let font = Font.system(size: size, weight: weight, design: .serif)
        return italic ? font.italic() : font
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Finder-style (base 1000) byte formatting, split so the number and unit can be styled apart.
nonisolated enum Bytes {
    static func parts(_ bytes: Int64) -> (value: String, unit: String) {
        let v = Double(max(0, bytes))
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        for (scale, unit) in units where v >= scale {
            let x = v / scale
            let decimals = unit == "GB" || unit == "TB" || x < 100
            return (String(format: decimals ? "%.1f" : "%.0f", x), unit)
        }
        return ("\(Int(v))", "B")
    }

    static func string(_ bytes: Int64) -> String {
        let p = parts(bytes)
        return "\(p.value) \(p.unit)"
    }
}

/// The little petal from the mockup's list rows (a 10×16 box: straight sides, pointed top).
nonisolated struct PetalShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 10
        let sy = rect.height / 16
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + x * sx, y: rect.maxY + y * sy)
        }
        var p = Path()
        p.move(to: pt(-5, 0))
        p.addLine(to: pt(-5, -8))
        p.addCurve(to: pt(0, -16), control1: pt(-5, -12), control2: pt(-2, -15))
        p.addCurve(to: pt(5, -8), control1: pt(2, -15), control2: pt(5, -12))
        p.addLine(to: pt(5, 0))
        p.closeSubpath()
        return p
    }
}
