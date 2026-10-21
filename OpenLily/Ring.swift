//
//  Ring.swift
//  OpenLily
//

import SwiftUI

/// Geometry of the lily, in "world" units (the mockup's SVG units, center at 0,0).
///
/// Angles run clockwise from 12 o'clock. Depth is continuous so focus changes can
/// slide rings inward and outward. Each ring is thinner than the one inside it, so
/// infinitely many fit inside a finite radius and zooming in reveals deeper levels.
nonisolated enum Ring {
    static let core = 64.0
    static let r0 = 72.0
    static let thickness = 108.0
    static let falloff = 0.78
    static let gap = 4.0
    /// World radius that fits the stage at zoom 1 (rings, petal tips and labels).
    static let fit = 470.0
    static let reach = 640.0

    static func inner(_ d: Double) -> Double {
        if d >= 1 { return r0 + thickness * (1 - pow(falloff, d - 1)) / (1 - falloff) }
        return r0 * max(0, d)
    }

    /// The gap between rings stays about the same on screen however far you zoom.
    static func outer(_ d: Double, scale: Double = 1) -> Double {
        inner(d + 1) - gap / max(1, scale) * min(1, max(0, d))
    }

    /// How many levels show at a zoom. Three at 1×, like the mockup; more as you zoom in.
    static func visibleDepth(_ scale: Double) -> Double {
        3 + max(0, log2(scale)) * 2.2
    }

    static func alpha(_ d: Double, scale: Double) -> Double {
        min(1, max(0, visibleDepth(scale) - d + 1))
    }

    static func tip(ro: Double, span: Double, depth d: Double) -> Double {
        guard span < .pi * 0.9 else { return 0 }
        return max(6, min(78 * pow(falloff, max(0, d - 3)), ro * span * 0.85))
    }

    static func point(_ r: Double, _ a: Double) -> CGPoint {
        CGPoint(x: r * sin(a), y: -r * cos(a))
    }

    static func angle(of p: CGPoint) -> Double {
        let a = atan2(p.x, -p.y)
        return a < 0 ? a + 2 * .pi : a
    }

    /// Bounding box of an annular sector.
    static func box(_ ri: Double, _ ro: Double, _ a0: Double, _ a1: Double) -> CGRect {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ p: CGPoint) {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        add(point(ri, a0)); add(point(ro, a0))
        add(point(ri, a1)); add(point(ro, a1))
        var q = (a0 / (.pi / 2)).rounded(.up) * (.pi / 2)
        while q < a1 {
            add(point(ro, q))
            q += .pi / 2
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether an annular sector really overlaps a rect (not just its bounding box).
    static func intersects(_ rect: CGRect, _ ri: Double, _ ro: Double, _ a0: Double, _ a1: Double) -> Bool {
        guard box(ri, ro, a0, a1).intersects(rect) else { return false }
        let probes = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.midY),
        ]
        for p in probes {
            let r = hypot(p.x, p.y)
            if r >= ri, r <= ro {
                let a = angle(of: p)
                if a >= a0, a <= a1 { return true }
            }
        }
        let steps = 24
        for i in 0...steps {
            let a = a0 + (a1 - a0) * Double(i) / Double(steps)
            if rect.contains(point(ri, a)) || rect.contains(point(ro, a)) || rect.contains(point((ri + ro) / 2, a)) {
                return true
            }
        }
        for i in 0...8 {
            let r = ri + (ro - ri) * Double(i) / 8
            if rect.contains(point(r, a0)) || rect.contains(point(r, a1)) { return true }
        }
        return false
    }

    /// A ring segment with straight radial sides. With a tip, the outer edge curves out into a petal point.
    static func segment(center c: CGPoint, k: Double, ri: Double, ro: Double, a0: Double, a1: Double, tip: Double) -> Path {
        func p(_ r: Double, _ a: Double) -> CGPoint {
            CGPoint(x: c.x + r * k * sin(a), y: c.y - r * k * cos(a))
        }
        let span = a1 - a0
        var path = Path()
        path.move(to: p(ri, a0))
        path.addLine(to: p(ro, a0))
        if tip > 0.5 {
            let m = (a0 + a1) / 2
            path.addCurve(to: p(ro + tip, m), control1: p(ro + tip * 0.55, a0 + span * 0.03), control2: p(ro + tip * 0.95, m - span * 0.3))
            path.addCurve(to: p(ro, a1), control1: p(ro + tip * 0.95, m + span * 0.3), control2: p(ro + tip * 0.55, a1 - span * 0.03))
        } else {
            path.addRelativeArc(center: c, radius: ro * k, startAngle: .radians(a0 - .pi / 2), delta: .radians(span))
        }
        path.addLine(to: p(ri, a1))
        if ri * k > 0.01 {
            path.addRelativeArc(center: c, radius: ri * k, startAngle: .radians(a1 - .pi / 2), delta: .radians(-span))
        }
        path.closeSubpath()
        return path
    }
}

/// Camera: maps world units to the ring stage's points.
nonisolated struct Viewport {
    var size: CGSize
    var scale: Double
    var pan: CGSize

    var k: Double { scale * Double(min(size.width, size.height)) / (2 * Ring.fit) }

    var center: CGPoint {
        CGPoint(x: size.width / 2 + min(40, size.width * 0.03) + pan.width, y: size.height / 2 + 18 + pan.height)
    }

    func screen(_ w: CGPoint) -> CGPoint {
        CGPoint(x: center.x + w.x * k, y: center.y + w.y * k)
    }

    func world(_ s: CGPoint) -> CGPoint {
        CGPoint(x: (s.x - center.x) / k, y: (s.y - center.y) / k)
    }

    var worldRect: CGRect {
        let a = world(.zero)
        let b = world(CGPoint(x: size.width, y: size.height))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
}

enum ColorMode: String, CaseIterable, Identifiable {
    case folder = "Folder"
    case kind = "Kind"
    case age = "Age"

    var id: Self { self }
}

struct AgeBand {
    let limit: Double
    let rgb: RGB
    let title: String

    static let all: [AgeBand] = [
        AgeBand(limit: 7 * 86_400, rgb: RGB(0xE9738A), title: "This week"),
        AgeBand(limit: 31 * 86_400, rgb: RGB(0xF29E6D), title: "This month"),
        AgeBand(limit: 183 * 86_400, rgb: RGB(0xE8C15A), title: "6 months"),
        AgeBand(limit: 365 * 86_400, rgb: RGB(0x6FB59A), title: "This year"),
        AgeBand(limit: 3 * 365 * 86_400, rgb: RGB(0x8FB3E8), title: "1–3 years"),
        AgeBand(limit: .infinity, rgb: RGB(0xB7AEC4), title: "Older"),
    ]

    static func of(_ modified: UInt32, now: Double) -> AgeBand {
        let age = now - Double(modified)
        return all.first { age < $0.limit } ?? all[all.count - 1]
    }
}

/// Picks segment colors. Folder mode follows the mockup: a hue per top-level petal,
/// lightened toward white as you go outward, alternating slightly between siblings.
struct Painter {
    let mode: ColorMode
    let now = Date().timeIntervalSince1970

    static func lighten(_ d: Double) -> Double {
        if d <= 1 { return 0 }
        if d <= 2 { return 0.28 * (d - 1) }
        if d <= 3 { return 0.28 + 0.22 * (d - 2) }
        return min(0.72, 0.5 + 0.07 * (d - 3))
    }

    func color(_ node: FileNode, base: RGB, depth: Double, index: Int) -> RGB {
        if node.isSynthetic { return Theme.hidden }
        let parity = Double(index % 2)
        switch mode {
        case .folder:
            return base.mix(.white, Self.lighten(depth) + (depth > 1.5 ? parity * 0.08 : 0))
        case .kind:
            return node.kind.rgb.mix(.white, min(0.36, max(0, depth - 1) * 0.1) + parity * 0.05)
        case .age:
            return AgeBand.of(node.modified, now: now).rgb.mix(.white, min(0.3, max(0, depth - 1) * 0.08) + parity * 0.05)
        }
    }
}
