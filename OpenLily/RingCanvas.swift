//
//  RingCanvas.swift
//  OpenLily
//

import SwiftUI

/// Everything that animates on the ring, as one interpolatable vector.
///
/// `focus` and `wilt` are epochs: each transition bumps the target by 1, and the
/// renderer reads progress as how far the animated value has come from the previous epoch.
nonisolated struct RingAnim: VectorArithmetic {
    var focus: Double
    var wilt: Double
    var scale: Double
    var panX: Double
    var panY: Double

    static var zero: RingAnim { RingAnim(focus: 0, wilt: 0, scale: 0, panX: 0, panY: 0) }

    static func + (a: RingAnim, b: RingAnim) -> RingAnim {
        RingAnim(focus: a.focus + b.focus, wilt: a.wilt + b.wilt, scale: a.scale + b.scale, panX: a.panX + b.panX, panY: a.panY + b.panY)
    }

    static func - (a: RingAnim, b: RingAnim) -> RingAnim {
        RingAnim(focus: a.focus - b.focus, wilt: a.wilt - b.wilt, scale: a.scale - b.scale, panX: a.panX - b.panX, panY: a.panY - b.panY)
    }

    mutating func scale(by rhs: Double) {
        focus *= rhs
        wilt *= rhs
        scale *= rhs
        panX *= rhs
        panY *= rhs
    }

    var magnitudeSquared: Double {
        focus * focus + wilt * wilt + scale * scale + panX * panX + panY * panY
    }
}

/// A snapshot of the model for one frame, taken in `body` so Observation sees the reads.
struct RenderState {
    let root: FileNode
    let focus: FileNode
    let focusFrom: FileNode
    let focusEpoch: Double
    /// Unused while drawing; read so the ring redraws when tree sizes change.
    let revision: Int
    let wiltEpoch: Double
    let dying: [ObjectIdentifier: Int64]
    let growing: Bool
    let compost: Set<ObjectIdentifier>
    let hovered: FileNode?
    /// Folder whose "smaller items" petal is under the pointer.
    let hoveredSmaller: FileNode?
    let hoveringCenter: Bool
    let mode: ColorMode
    let search: SearchResult?
    let isVolume: Bool
}

struct RingCanvas: View, Animatable {
    let state: RenderState
    var anim: RingAnim

    var animatableData: RingAnim {
        get { anim }
        set { anim = newValue }
    }

    var body: some View {
        Canvas { ctx, size in
            RingRenderer(state: state, anim: anim, size: size).draw(&ctx)
        }
    }
}

final class RingRenderer {
    private struct Bases {
        var from: RGB?
        var to: RGB?
        var root: RGB?
    }

    private struct Label {
        let name: String
        let size: String
        let angle: Double
        let alpha: Double
    }

    private let s: RenderState
    private let vp: Viewport
    private let ft: Double
    private let wt: Double
    private let painter: Painter
    private let world: CGRect
    private let k: Double
    private var fx0 = 0.0
    private var fx1 = 1.0
    private var fdepth = 0.0
    private var fromDepth = 0
    private var toDepth = 0
    private var hoverPath: Path?
    private var labels: [Label] = []
    private var innerLabels = 0
    private let petals = Theme.petals

    init(state: RenderState, anim: RingAnim, size: CGSize) {
        s = state
        vp = Viewport(size: size, scale: anim.scale, pan: CGSize(width: anim.panX, height: anim.panY))
        ft = min(1, max(0, anim.focus - (state.focusEpoch - 1)))
        wt = min(1, max(0, anim.wilt - (state.wiltEpoch - 1)))
        painter = Painter(mode: state.mode)
        world = vp.worldRect
        k = vp.k
    }

    // MARK: - Sizes while things wilt or regrow

    private func eff(_ n: FileNode) -> Double {
        guard !s.dying.isEmpty, let b = s.dying[n.id] else { return Double(n.size) }
        return max(0, Double(n.size) - Double(b) * (s.growing ? 1 - wt : wt))
    }

    /// A node's slice of the whole tree as fractions of the root circle.
    private func span(of node: FileNode) -> (Double, Double, Int) {
        let chain = node.lineage
        var x0 = 0.0, x1 = 1.0
        for i in chain.indices.dropFirst() {
            let parent = chain[i - 1], child = chain[i]
            let total = eff(parent)
            guard total > 0 else { break }
            var before = 0.0
            for c in parent.children {
                if c === child { break }
                before += eff(c)
            }
            let w = x1 - x0
            x0 += w * before / total
            x1 = x0 + w * eff(child) / total
        }
        return (x0, x1, chain.count - 1)
    }

    private func angle(_ x: Double) -> Double {
        let w = fx1 - fx0
        guard w > 1e-15 else { return 0 }
        return min(1, max(0, (x - fx0) / w)) * 2 * .pi
    }

    // MARK: - Draw

    func draw(_ ctx: inout GraphicsContext) {
        let from = span(of: s.focusFrom)
        let to = span(of: s.focus)
        fx0 = from.0 + (to.0 - from.0) * ft
        fx1 = from.1 + (to.1 - from.1) * ft
        fdepth = Double(from.2) + Double(to.2 - from.2) * ft
        fromDepth = from.2
        toDepth = to.2

        visit(s.root, 0, 1, depth: 0, index: 0, bases: Bases(), wilted: false, lit: false, ctx: &ctx)

        if let hoverPath {
            ctx.stroke(hoverPath, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
        }
        drawLabels(&ctx)
        drawCenter(&ctx)
    }

    private func visit(_ node: FileNode, _ x0: Double, _ x1: Double, depth: Int, index: Int, bases: Bases, wilted: Bool, lit: Bool, ctx: inout GraphicsContext) {
        let a0 = angle(x0), a1 = angle(x1)
        let span = a1 - a0
        guard span > 1e-7 else { return }
        let d = Double(depth) - fdepth
        let scale = vp.scale

        let isWilted = wilted || s.compost.contains(node.id)
        let isLit = lit || (s.search?.matches.contains(node.id) ?? false)
        let shown = s.search == nil || isLit || (s.search?.ancestors.contains(node.id) ?? false)

        if depth > 0, d > 0.02 {
            let alpha = Ring.alpha(d, scale: scale)
            guard alpha > 0.01 else { return }
            let ri = Ring.inner(d), ro = Ring.outer(d, scale: vp.scale)
            guard span * ro * k >= 0.7, Ring.box(ri, Ring.reach, a0, a1).intersects(world) else { return }

            var tipFactor = node.hasChildren ? 1 - Ring.alpha(d + 1, scale: scale) : 1
            if node.hasChildren, let first = node.children.first, eff(node) > 0,
               Ring.isThin(span: span * eff(first) / eff(node), depth: d + 1, k: k) {
                tipFactor = 1
            }
            let tip = Ring.tip(ro: ro, span: span, depth: d) * tipFactor
            let path = Ring.segment(center: vp.center, k: k, ri: ri, ro: ro, a0: a0, a1: a1, tip: tip)

            let rgb = color(node, depth: depth, index: index, bases: bases)
            let a = shown ? alpha : alpha * 0.16
            if isWilted {
                ctx.fill(path, with: .color(Theme.wilt.opacity(a)))
                ctx.stroke(path, with: .color(Theme.wiltStroke.opacity(a)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: [5, 4]))
            } else {
                ctx.fill(path, with: .color(rgb.color.opacity(a)))
                ctx.stroke(path, with: .color(Theme.paper), style: StrokeStyle(lineWidth: min(2, span * ro * k * 0.3), lineJoin: .round))
            }
            if node === s.hovered { hoverPath = path }

            let labelled = d > 0.35 && d < 1.65 && span > 0.2
            if labelled && shown {
                labels.append(Label(name: node.isSynthetic ? node.name : node.displayName, size: Bytes.string(Int64(eff(node))), angle: (a0 + a1) / 2, alpha: max(0, 1 - abs(d - 1) / 0.65)))
            } else if shown {
                innerLabel(node, ri: ri, ro: ro, a0: a0, a1: a1, alpha: alpha, ctx: &ctx)
            }
        }

        // Children
        guard node.hasChildren else { return }
        let dChild = Double(depth + 1) - fdepth
        if dChild > 0.02, Ring.alpha(dChild, scale: scale) <= 0.01 { return }
        let total = eff(node)
        guard total > 0 else { return }
        let width = x1 - x0
        var x = x0
        for (i, child) in node.children.enumerated() {
            let cw = width * eff(child) / total
            guard cw > 0 else { continue }
            let ca0 = angle(x), ca1 = angle(x + cw)
            if dChild > 0.02, ca1 > ca0, Ring.isThin(span: ca1 - ca0, depth: dChild, k: k) {
                // Everything from here on is thinner still. If nothing in this folder is wide enough,
                // the folder just ends in a petal; otherwise the rest share one "smaller items" petal.
                if i > 0 {
                    drawSmaller(node, count: node.children.count - i, from: ca0, to: angle(x1), depth: dChild, dim: !(shown && s.search == nil), ctx: &ctx)
                }
                break
            }
            var next = bases
            if depth + 1 - toDepth == 1 { next.to = petals[i % petals.count] }
            if depth + 1 - fromDepth == 1 { next.from = petals[i % petals.count] }
            if depth == 0 { next.root = petals[i % petals.count] }
            visit(child, x, x + cw, depth: depth + 1, index: i, bases: next, wilted: isWilted, lit: isLit, ctx: &ctx)
            x += cw
        }
    }

    private func color(_ node: FileNode, depth: Int, index: Int, bases: Bases) -> RGB {
        let fallback = bases.root ?? petals[0]
        let target = painter.color(node, base: bases.to ?? fallback, depth: Double(depth - toDepth), index: index)
        guard ft < 1 else { return target }
        let source = painter.color(node, base: bases.from ?? fallback, depth: Double(depth - fromDepth), index: index)
        return source.mix(target, ft)
    }

    /// One soft petal standing in for all the slices too thin to draw on their own.
    private func drawSmaller(_ parent: FileNode, count: Int, from a0: Double, to a1: Double, depth d: Double, dim: Bool, ctx: inout GraphicsContext) {
        let span = a1 - a0
        guard span > 0, !Ring.isThin(span: span, depth: d, k: k) else { return }
        let ri = Ring.inner(d), ro = Ring.outer(d, scale: vp.scale)
        guard Ring.box(ri, Ring.reach, a0, a1).intersects(world) else { return }
        let path = Ring.segment(center: vp.center, k: k, ri: ri, ro: ro, a0: a0, a1: a1, tip: Ring.tip(ro: ro, span: span, depth: d))
        let alpha = Ring.alpha(d, scale: vp.scale) * (dim ? 0.3 : 1)
        ctx.fill(path, with: .color(Theme.smaller.opacity(alpha)))
        ctx.stroke(path, with: .color(Theme.inkSoft.opacity(0.35 * alpha)), style: StrokeStyle(lineWidth: 1, lineJoin: .round, dash: [2, 3]))
        if parent === s.hoveredSmaller { hoverPath = path }

        let mid = (ri + ro) / 2
        guard span * mid * k >= 26, (ro - ri) * k >= 18, alpha > 0.6 else { return }
        let p = vp.screen(Ring.point(mid, (a0 + a1) / 2))
        ctx.draw(
            Text("+\(count.formatted())").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.inkSoft.opacity(alpha)),
            at: p, anchor: .center
        )
    }

    private func innerLabel(_ node: FileNode, ri: Double, ro: Double, a0: Double, a1: Double, alpha: Double, ctx: inout GraphicsContext) {
        guard innerLabels < 40, alpha > 0.6 else { return }
        let mid = (ri + ro) / 2
        let arc = (a1 - a0) * mid * k
        let thick = (ro - ri) * k
        guard arc >= 96, thick >= 24 else { return }
        let p = vp.screen(Ring.point(mid, (a0 + a1) / 2))
        guard p.x > -50, p.y > -20, p.x < vp.size.width + 50, p.y < vp.size.height + 20 else { return }
        let text = ctx.resolve(Text(node.displayName).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0x1F2A24).opacity(0.7 * alpha)))
        let size = text.measure(in: CGSize(width: 1000, height: 40))
        guard size.width < min(arc, thick * 4) * 0.85 else { return }
        innerLabels += 1
        ctx.draw(text, at: p, anchor: .center)
    }

    private func drawLabels(_ ctx: inout GraphicsContext) {
        guard !labels.isEmpty else { return }
        let lr = Ring.outer(min(12, Ring.visibleDepth(vp.scale))) + 90
        for label in labels where label.alpha > 0.02 {
            let sx = sin(label.angle), cy = -cos(label.angle)
            let anchorX: Double = sx > 0.3 ? 0 : (sx < -0.3 ? 1 : 0.5)
            let y = cy * lr + (cy > 0.3 ? 10 : (cy < -0.3 ? -12 : 0))
            let p = vp.screen(CGPoint(x: sx * lr, y: y))
            let name = Text(label.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink.opacity(label.alpha))
            let size = Text(label.size).font(.mono(12)).foregroundStyle(Theme.inkSoft.opacity(label.alpha))
            ctx.draw(name, at: p, anchor: UnitPoint(x: anchorX, y: 1))
            ctx.draw(size, at: CGPoint(x: p.x, y: p.y + 17), anchor: UnitPoint(x: anchorX, y: 1))
        }
    }

    private func drawCenter(_ ctx: inout GraphicsContext) {
        let c = vp.center
        let rc = Ring.core * k
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - rc, y: c.y - rc, width: rc * 2, height: rc * 2)), with: .color(Theme.ink))
        for i in 0..<20 {
            let b = Double(i) * 18 * .pi / 180
            let pr = (50 + Double(i % 2) * 4) * k
            let r = (i % 3 == 0 ? 2.6 : 1.8) * k
            let p = CGPoint(x: c.x + sin(b) * pr, y: c.y - cos(b) * pr)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(Theme.pollen))
        }

        let tk = min(k, 1.6)
        let atRoot = s.focus === s.root
        let parts = Bytes.parts(Int64(eff(s.focus)))
        let small: String
        if s.hoveringCenter && !atRoot {
            small = "↑ BACK"
        } else if atRoot {
            small = s.isVolume ? "\(parts.unit) USED" : parts.unit
        } else {
            let name = s.focus.displayName.uppercased()
            small = name.count > 14 ? String(name.prefix(13)) + "…" : name
        }
        let big = atRoot ? parts.value : "\(parts.value) \(parts.unit)"
        let bigSize = (atRoot ? 30 : 20) * tk
        ctx.draw(
            Text(big).font(.serif(bigSize, .semibold, italic: true)).foregroundStyle(Theme.paper),
            at: CGPoint(x: c.x, y: c.y + 4 * tk), anchor: .bottom
        )
        ctx.draw(
            Text(small).font(.system(size: 9.5 * tk, weight: .semibold)).tracking(1).foregroundStyle(Theme.paper.opacity(0.75)),
            at: CGPoint(x: c.x, y: c.y + 9 * tk), anchor: .top
        )
    }
}
