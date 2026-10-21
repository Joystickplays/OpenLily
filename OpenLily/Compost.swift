//
//  Compost.swift
//  OpenLily
//

import SwiftUI

/// The bin. Things wait here (wilting on the ring) until you let them fall.
struct CompostCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let over = model.drag?.overBin == true
        let empty = model.compost.isEmpty
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Compost")
                    .font(.serif(30, .semibold, italic: true))
                Spacer()
                Text(Bytes.string(model.compostBytes))
                    .font(.serif(30))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.compostBytes)
            }

            Text(message(over: over))
                .font(.system(size: 13))
                .foregroundStyle(Theme.compostText.opacity(0.72))
                .contentTransition(.opacity)

            if !empty {
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(model.compost) { node in
                            CompostChip(node: node)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 132)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button { model.letThemFall() } label: {
                Text("Let them fall")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.bloomInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Theme.bloom.color).interactive(), in: .capsule)
            .disabled(empty)
            .opacity(empty ? 0.4 : 1)
        }
        .padding(22)
        .foregroundStyle(Theme.compostText)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Theme.compost)
                .shadow(color: Theme.bloom.color.opacity(over ? 0.55 : 0), radius: 24)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(Theme.bloom.color.opacity(over ? 1 : 0), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        }
        .scaleEffect(over ? 1.035 : 1)
        .keyframeAnimator(initialValue: 0.0, trigger: model.binPulse) { content, wobble in
            content.rotationEffect(.degrees(wobble))
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(-1.6, duration: 0.08)
                SpringKeyframe(1.2, duration: 0.1)
                SpringKeyframe(0, duration: 0.25)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: over)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: model.compost.map(\.id))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.binFrame = $0 }
    }

    private func message(over: Bool) -> String {
        if over { return "Let go. It'll wait here until you say so." }
        let n = model.compost.count
        switch n {
        case 0: return "Drag petals here. Nothing falls until you say so."
        case 1: return "1 petal wilting. It falls when you say so."
        default: return "\(n) petals wilting. They fall when you say so."
        }
    }
}

private struct CompostChip: View {
    @Environment(AppModel.self) private var model
    let node: FileNode
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Text(node.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize()
            Text(Bytes.string(node.size))
                .foregroundStyle(Theme.compostText.opacity(0.66))
            if hovering {
                Button {
                    withAnimation(.snappy) { model.removeFromCompost(node) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Theme.compostChip))
        .onHover { h in withAnimation(.snappy(duration: 0.2)) { hovering = h } }
        .help(node.path)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.chipFrames[node.id] = $0 }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

// MARK: - Countdown

struct CountdownOverlay: View {
    @Environment(AppModel.self) private var model

    private let lines = [
        3: "Saying goodbye…",
        2: "Last chance to blink.",
        1: "Petals loosening…",
    ]

    var body: some View {
        if let n = model.countdown {
            ZStack {
                // Keep the ring faintly visible: the point is to watch it go.
                Theme.paper.opacity(0.78)
                    .ignoresSafeArea()

                VStack(spacing: 10) {
                    Text("\(n)")
                        .font(.serif(240, .semibold, italic: true))
                        .foregroundStyle(Theme.bloom.color)
                        .contentTransition(.numericText(countsDown: true))
                        .shadow(color: Theme.bloom.color.opacity(0.35), radius: 40)
                        .scaleEffect(1 + 0.04 * Double(3 - n))
                    Text(lines[n] ?? "")
                        .font(.serif(28, .medium, italic: true))
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.opacity)
                    Text("\(model.compost.count) \(model.compost.count == 1 ? "item" : "items") · \(Bytes.string(model.compostBytes)) to the Trash")
                        .font(.mono(12))
                        .foregroundStyle(Theme.inkSoft)
                    Button { model.cancelCountdown() } label: {
                        Text("Wait, keep them!")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 18)
                }
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Falling petals

struct ParticleLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let particles = model.particles
        TimelineView(.animation(minimumInterval: nil, paused: particles.isEmpty)) { timeline in
            Canvas { ctx, _ in
                let now = timeline.date
                let gravity = 1100.0
                for p in particles {
                    let t = now.timeIntervalSince(p.born)
                    guard t >= 0, t < p.life else { continue }
                    let x = p.origin.x + p.velocity.dx * t
                    let y = p.origin.y + p.velocity.dy * t + 0.5 * gravity * t * t
                    let fade = 1 - pow(t / p.life, 3)
                    var c = ctx
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(p.angle + p.spin * t))
                    let w = p.size * 0.62, h = p.size
                    let petal = PetalShape().path(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                    c.fill(petal, with: .color(p.color.opacity(fade)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Drag ghost

struct DragGhost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let drag = model.drag, let first = drag.nodes.first {
            HStack(spacing: 9) {
                PetalShape()
                    .fill(model.swatch(for: first).color)
                    .frame(width: 13, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(first.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(Bytes.string(drag.nodes.reduce(0) { $0 + $1.size }))
                        .font(.mono(11))
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .fixedSize()
            .rotationEffect(.degrees(drag.overBin ? -7 : 3))
            .scaleEffect(drag.overBin ? 0.86 : 1)
            .position(x: drag.point.x + 70, y: drag.point.y - 14)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }
}
