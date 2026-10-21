//
//  RingStage.swift
//  OpenLily
//

import SwiftUI

/// The left side of the main window: the lily itself plus everything floating over it.
struct RingStage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.paper

            if let state = renderState {
                RingCanvas(state: state, anim: anim)
                    .keyframeAnimator(initialValue: CGFloat(0), trigger: model.shake) { content, x in
                        content.offset(x: x)
                    } keyframes: { _ in
                        KeyframeTrack {
                            SpringKeyframe(-9, duration: 0.05)
                            SpringKeyframe(8, duration: 0.06)
                            SpringKeyframe(-5, duration: 0.07)
                            SpringKeyframe(3, duration: 0.08)
                            SpringKeyframe(0, duration: 0.2)
                        }
                    }
            }

            RingInteraction(model: model)

            // Once the ring is zoomed under the header, fade the paper back in so the numbers stay legible.
            EllipticalGradient(colors: [Theme.paper, Theme.paper.opacity(0.85), Theme.paper.opacity(0)], center: .topLeading, startRadiusFraction: 0, endRadiusFraction: 0.5)
                .frame(width: 1100, height: 620)
                .offset(x: -40, y: -40)
                .opacity(model.camera.scale > 1.15 || model.camera.pan != .zero ? 1 : 0)
                .animation(.smooth, value: model.camera.scale > 1.15 || model.camera.pan != .zero)
                .allowsHitTesting(false)

            HeaderView()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("stage")) } action: { model.headerFrame = $0 }
                .padding(.leading, 48)
                .padding(.top, 52)

            HoverCallout()

            StageTools()
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .padding(.top, 20)
                .padding(.trailing, 24)

            BottomControls()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 40)
                .padding(.bottom, 36)

            ToastView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 96)
        }
        .clipped()
        .coordinateSpace(.named("stage"))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { model.ringSize = $0 }
    }

    private var renderState: RenderState? {
        guard let root = model.root, let focus = model.focus else { return nil }
        return RenderState(
            root: root,
            focus: focus,
            focusFrom: model.focusFrom ?? focus,
            focusEpoch: model.focusEpoch,
            revision: model.revision,
            wiltEpoch: model.wiltEpoch,
            dying: model.dying,
            growing: model.growing,
            compost: model.compostIDs,
            hovered: model.hovered,
            hoveredSmaller: model.hoveredSmaller?.parent,
            hoveringCenter: model.hoveringCenter,
            mode: model.colorMode,
            search: model.search,
            isVolume: model.isVolumeScan,
            avoid: model.headerFrame
        )
    }

    private var anim: RingAnim {
        RingAnim(
            focus: model.focusEpoch,
            wilt: model.wiltEpoch,
            scale: model.camera.scale,
            panX: model.camera.pan.width,
            panY: model.camera.pan.height
        )
    }
}

// MARK: - Header

private struct HeaderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text("\(model.scanTitle) · scanned \(model.relativeScanTime)".uppercased())
                    .font(.mono(11))
                    .tracking(1.1)
                    .foregroundStyle(Theme.inkSoft)
            }

            let _ = model.revision
            let used = model.scanVolume?.used ?? model.root?.size ?? 0
            let parts = Bytes.parts(used)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(parts.value)
                    .font(.serif(72, .medium, italic: true))
                    .tracking(-2)
                    .contentTransition(.numericText())
                if let volume = model.scanVolume {
                    Text("\(parts.unit) of \(Bytes.parts(volume.total).value)")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.inkSoft)
                } else {
                    Text("\(parts.unit) in \(Int(model.root?.items ?? 0).formatted()) files")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            .animation(.smooth, value: used)

            if let volume = model.scanVolume {
                let purgeable = volume.purgeable > 1_000_000_000 ? " · \(Bytes.string(volume.purgeable)) purgeable" : ""
                Text("\(Bytes.string(volume.free)) still free to grow into\(purgeable)")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.inkSoft)
            }

            Breadcrumbs()
                .padding(.top, 14)
        }
        .foregroundStyle(Theme.ink)
    }
}

private struct Breadcrumbs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let focus = model.focus, focus.parent != nil {
            let chain = focus.lineage
            GlassEffectContainer {
                HStack(spacing: 2) {
                    ForEach(Array(chain.enumerated()), id: \.element.id) { i, node in
                        if i > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.inkSoft)
                        }
                        Button {
                            model.drill(into: node)
                        } label: {
                            Text(i == 0 ? model.scanTitle : node.displayName)
                                .font(.system(size: 12, weight: node === focus ? .semibold : .regular))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(node === focus)
                    }
                }
                .padding(.horizontal, 6)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

// MARK: - Callout

private struct HoverCallout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.drag == nil, let anchor = model.calloutAnchor, let content {
            let size = model.ringSize
            let x = min(max(anchor.x + 150, 140), size.width - 140)
            let y = min(max(anchor.y - 70, 90), size.height - 90)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    PetalShape()
                        .fill(content.petal)
                        .frame(width: 10, height: 13)
                    Text(content.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(Bytes.string(content.bytes))
                    .font(.serif(28))
                    .tracking(-0.5)
                Text(content.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSoft)
                    .lineSpacing(2)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: 240, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .position(x: x, y: y)
            .animation(.smooth(duration: 0.18), value: CGPoint(x: x, y: y))
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private var content: (title: String, bytes: Int64, detail: String, petal: Color)? {
        if let node = model.hovered {
            let petal = model.isComposted(node) ? Theme.wilt : model.swatch(for: node).color
            return (node.displayName, node.size, model.detail(for: node), petal)
        }
        if let group = model.hoveredSmaller {
            let action = group.parent === model.focus ? "Click to zoom in on them." : "Click to open \(group.parent.displayName)."
            return (group.title, group.bytes, "Too thin to draw one by one.\n\(action)", Theme.smaller)
        }
        return nil
    }
}

// MARK: - Top-right tools

private struct StageTools: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searching: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .trailing, spacing: 10) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Theme.inkSoft)
                        TextField("Find  (try .dmg)", text: $model.searchText)
                            .textFieldStyle(.plain)
                            .focused($searching)
                            .frame(width: 170)
                            .onExitCommand { model.clearSearch(); searching = false }
                        if !model.searchText.isEmpty {
                            Button { model.clearSearch() } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkSoft)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .glassEffect(.regular.interactive(), in: .capsule)

                    Button { model.rescan() } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .help("Rescan (⌘R)")

                    Button { model.backToStart() } label: {
                        Image(systemName: "externaldrive").frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .help("Scan something else")
                }
            }
            .foregroundStyle(Theme.ink)

            if let search = model.search {
                HStack(spacing: 10) {
                    Text(search.tops.isEmpty ? "No matches" : "\(search.tops.count.formatted()) matches · \(Bytes.string(search.bytes))")
                        .font(.system(size: 12.5, weight: .medium))
                    if !search.tops.isEmpty {
                        Button("Compost all") { model.compostSearchResults() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.bloom.color)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if model.deniedCount > 0 && !model.hasFullDiskAccess {
                Button { model.openFullDiskAccessSettings() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                        Text("\(model.deniedCount) folders were locked · Grant Full Disk Access")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.review.color.opacity(0.35)).interactive(), in: .capsule)
            }
        }
        .background {
            Button("") { searching = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }
}

// MARK: - Bottom controls

private struct BottomControls: View {
    @Environment(AppModel.self) private var model
    @Namespace private var modeSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Legend()

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    HStack(spacing: 2) {
                        ForEach(ColorMode.allCases) { mode in
                            let on = model.colorMode == mode
                            Button {
                                withAnimation(.snappy(duration: 0.3)) { model.colorMode = mode }
                            } label: {
                                Text(mode.rawValue)
                                    .font(.system(size: 13, weight: on ? .semibold : .medium))
                                    .foregroundStyle(on ? Theme.paper : Theme.ink)
                                    .padding(.horizontal, 16)
                                    .frame(height: 32)
                                    .background {
                                        if on {
                                            Capsule().fill(Theme.ink)
                                                .matchedGeometryEffect(id: "mode", in: modeSpace)
                                        }
                                    }
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .glassEffect(.regular.interactive(), in: .capsule)

                    HStack(spacing: 0) {
                        Button { model.zoomStep(-1) } label: {
                            Text("−").font(.system(size: 18)).frame(width: 32, height: 32).contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        Button { model.resetCamera() } label: {
                            Text("\(Int((model.camera.scale * 100).rounded()))%")
                                .font(.mono(12))
                                .frame(minWidth: 48)
                                .contentTransition(.numericText())
                        }
                        .buttonStyle(.plain)
                        .help("Reset zoom (0)")
                        Button { model.zoomStep(1) } label: {
                            Text("+").font(.system(size: 18)).frame(width: 32, height: 32).contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(4)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .foregroundStyle(Theme.ink)
        }
    }
}

private struct Legend: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let entries: [(String, RGB)] = switch model.colorMode {
        case .folder: []
        case .kind: FileKind.allCases.map { ($0.title, $0.rgb) }
        case .age: AgeBand.all.map { ($0.title, $0.rgb) }
        }
        if !entries.isEmpty {
            HStack(spacing: 12) {
                ForEach(entries, id: \.0) { title, rgb in
                    HStack(spacing: 5) {
                        PetalShape().fill(rgb.color).frame(width: 7, height: 11)
                        Text(title).font(.system(size: 11.5))
                    }
                }
            }
            .foregroundStyle(Theme.inkSoft)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .glassEffect(.regular, in: .capsule)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .id(model.colorMode)
        }
    }
}

// MARK: - Toast

private struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title).font(.serif(17, .semibold, italic: true))
                    if let detail = toast.detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.inkSoft).lineLimit(1)
                    }
                }
                if toast.canUndo {
                    Button("Undo") { model.undoLastFall() }
                        .buttonStyle(.glass)
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
