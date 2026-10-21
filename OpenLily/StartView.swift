//
//  StartView.swift
//  OpenLily
//

import SwiftUI
import AppKit

struct StartView: View {
    @Environment(AppModel.self) private var model
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 20)

            LilyMark(progress: 1)
                .frame(width: 190, height: 190)

            VStack(spacing: 8) {
                Text("OpenLily")
                    .font(.serif(64, .medium, italic: true))
                    .tracking(-1.5)
                Text("See what's quietly blooming on your disk.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.inkSoft)
            }

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    ForEach(model.volumes) { volume in
                        VolumeCard(volume: volume)
                    }
                    PlaceCard(title: "Home", subtitle: "~/" + NSUserName(), symbol: "house") {
                        model.scan(URL(fileURLWithPath: NSHomeDirectory()))
                    }
                    PlaceCard(title: "A folder…", subtitle: "or drop one here", symbol: "folder.badge.plus") {
                        model.chooseFolder()
                    }
                }
            }
            .padding(.horizontal, 40)

            if !model.hasFullDiskAccess {
                HStack(spacing: 12) {
                    Image(systemName: "lock.open")
                        .font(.system(size: 15, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Give OpenLily Full Disk Access")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Otherwise Mail, Messages, Safari and friends stay hidden and macOS asks about each folder.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkSoft)
                    }
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.glass)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular.tint(Theme.review.color.opacity(0.25)), in: .rect(cornerRadius: 20))
            }

            Spacer(minLength: 20)
        }
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Theme.bloom.color, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.scan(url)
            return true
        } isTargeted: { dropping = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshVolumes()
        }
    }
}

private struct VolumeCard: View {
    @Environment(AppModel.self) private var model
    let volume: VolumeInfo
    @State private var hovering = false

    var body: some View {
        Button { model.scan(volume.url) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: volume.url.path))
                        .resizable()
                        .frame(width: 38, height: 38)
                    Spacer()
                    Text(Bytes.string(volume.free) + " free")
                        .font(.mono(10.5))
                        .foregroundStyle(Theme.inkSoft)
                }
                Text(volume.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Bytes.parts(volume.used).value)
                        .font(.serif(26, .semibold, italic: true))
                    Text("\(Bytes.parts(volume.used).unit) of \(Bytes.string(volume.total))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSoft)
                }
                GeometryReader { geo in
                    let f = Double(volume.used) / Double(max(1, volume.total))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.ink.opacity(0.08))
                        Capsule()
                            .fill(LinearGradient(colors: Theme.petals.prefix(4).map(\.color), startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, geo.size.width * f))
                    }
                }
                .frame(height: 7)
            }
            .padding(18)
            .frame(width: 230)
            .contentShape(RoundedRectangle(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .scaleEffect(hovering ? 1.03 : 1)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
    }
}

private struct PlaceCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .regular))
                    .frame(height: 38)
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
            }
            .padding(18)
            .frame(width: 150, height: 150, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        .scaleEffect(hovering ? 1.03 : 1)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
    }
}

/// A small breathing lily, used as the logo and while scanning.
struct LilyMark: View {
    /// 0…1 grows the petals out; values below 1 also make them sway more.
    var progress: Double
    var spinning = false

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let k = Double(min(size.width, size.height)) / (2 * 300)
                let count = 13
                let turn = spinning ? t * 0.25 : 0
                let weights = [1.0, 0.8, 1.3, 0.7, 1.1, 0.9, 1.2, 0.75, 1.0, 0.85, 1.15, 0.7, 0.95]
                let total = weights.reduce(0, +)
                var a = turn
                for i in 0..<count {
                    let span = weights[i] / total * 2 * .pi
                    let wave = 0.5 + 0.5 * sin(t * (spinning ? 2.4 : 1.1) - Double(i) * 0.5)
                    let grow = 0.35 + 0.65 * progress
                    let ro = 118 + (70 + 30 * wave) * grow
                    let tip = (42 + 26 * wave) * grow
                    let inner = Ring.segment(center: c, k: k, ri: 72, ro: 116, a0: a, a1: a + span, tip: 0)
                    ctx.fill(inner, with: .color(Theme.petals[i].color))
                    ctx.stroke(inner, with: .color(Theme.paper), lineWidth: 2)
                    let outer = Ring.segment(center: c, k: k, ri: 120, ro: ro, a0: a, a1: a + span, tip: tip)
                    ctx.fill(outer, with: .color(Theme.petals[i].mix(.white, 0.3).color))
                    ctx.stroke(outer, with: .color(Theme.paper), lineWidth: 2)
                    a += span
                }
                let rc = Ring.core * k
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - rc, y: c.y - rc, width: rc * 2, height: rc * 2)), with: .color(Theme.ink))
                for i in 0..<20 {
                    let b = Double(i) * 18 * .pi / 180 + turn * 0.5
                    let pr = (50 + Double(i % 2) * 4) * k
                    let r = (i % 3 == 0 ? 2.6 : 1.8) * k
                    let p = CGPoint(x: c.x + sin(b) * pr, y: c.y - cos(b) * pr)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(Theme.pollen))
                }
            }
        }
    }
}
