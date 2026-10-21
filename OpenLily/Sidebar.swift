//
//  Sidebar.swift
//  OpenLily
//

import SwiftUI

/// Right column: what's in view on the ring (or smart picks), and the compost bin.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Group {
                switch model.sidebarTab {
                case .inView: InViewList()
                case .smart: SmartList()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            CompostCard()
        }
        .padding(EdgeInsets(top: 52, leading: 32, bottom: 32, trailing: 36))
        .frame(maxHeight: .infinity)
        .background(Theme.paper)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.rule).frame(width: 1)
        }
        .foregroundStyle(Theme.ink)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            tab("In view", .inView)
            tab("Smart picks · \(model.smart.picks.count)", .smart)
            Spacer(minLength: 0)
            if model.sidebarTab == .inView {
                Text("\(model.inView.count) PETALS")
                    .font(.mono(11))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.numericText())
            }
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.ink).frame(height: 1)
        }
    }

    private func tab(_ title: String, _ tab: SidebarTab) -> some View {
        let on = model.sidebarTab == tab
        return Button {
            withAnimation(.snappy(duration: 0.3)) { model.sidebarTab = tab }
        } label: {
            Text(title)
                .font(on ? .serif(26, .semibold, italic: true) : .system(size: 14))
                .foregroundStyle(on ? Theme.ink : Theme.inkSoft)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - In view

private struct InViewList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let anchor = model.inViewAnchor, anchor !== model.focus {
                Text("INSIDE \(anchor.displayName.uppercased())")
                    .font(.mono(10.5))
                    .tracking(0.8)
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.inView.prefix(80).enumerated()), id: \.element.id) { i, node in
                        NodeRow(node: node, number: i + 1)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(x: 24)),
                                removal: .opacity.combined(with: .offset(x: -12))
                            ))
                    }
                    if model.inView.isEmpty {
                        Text("Nothing big enough in view. Zoom out a little.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.inkSoft)
                            .padding(.top, 20)
                    }
                }
                .animation(.snappy(duration: 0.28), value: model.inView.map(\.id))
            }
            .scrollIndicators(.never)
        }
    }
}

private struct NodeRow: View {
    @Environment(AppModel.self) private var model
    let node: FileNode
    let number: Int

    var body: some View {
        let wilted = model.isComposted(node)
        let lit = model.hovered === node
        let _ = model.revision
        HStack(spacing: 12) {
            Text(String(format: "%02d", number))
                .font(.serif(14, .regular, italic: true))
                .foregroundStyle(Theme.inkSoft)
                .frame(width: 24, alignment: .leading)
            PetalShape()
                .fill(wilted ? Theme.wilt : model.swatch(for: node).color)
                .overlay { if wilted { PetalShape().stroke(Theme.wiltStroke, style: StrokeStyle(lineWidth: 1, dash: [2, 2])) } }
                .frame(width: 10, height: 16)
            Text(node.displayName)
                .font(.system(size: 15, weight: .medium))
                .strikethrough(wilted, color: Theme.wiltStroke)
                .lineLimit(1)
                .truncationMode(.middle)
            if node.hasChildren {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.inkSoft)
                    .opacity(lit ? 1 : 0)
            }
            Spacer(minLength: 8)
            Text(Bytes.string(node.size))
                .font(.serif(17))
                .monospacedDigit()
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.ink.opacity(lit ? 0.06 : 0))
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rule).frame(height: 1)
        }
        .opacity(wilted ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { model.hoverFromList($0 ? node : nil) }
        .onTapGesture { model.open(node) }
        .gesture(binDrag(for: node, model: model))
        .contextMenu { NodeMenu(node: node) }
    }
}

func binDrag(for node: FileNode, model: AppModel) -> some Gesture {
    DragGesture(minimumDistance: 6, coordinateSpace: .global)
        .onChanged { value in
            if model.drag == nil {
                model.beginDrag([node], at: value.location)
            } else {
                model.moveDrag(to: value.location)
            }
        }
        .onEnded { _ in model.endDrag() }
}

struct NodeMenu: View {
    @Environment(AppModel.self) private var model
    let node: FileNode

    var body: some View {
        if node.hasChildren {
            Button("Open Up", systemImage: "arrow.up.left.and.arrow.down.right") { model.drill(into: node) }
        }
        if !node.isSynthetic {
            Button("Quick Look", systemImage: "eye") { model.quickLook(node) }
            Button("Reveal in Finder", systemImage: "folder") { model.reveal(node) }
            Button("Copy Path", systemImage: "doc.on.doc") { model.copyPath(node) }
            Divider()
            let inBin = model.compostIDs.contains(node.id)
            Button(inBin ? "Take Out of Compost" : "Add to Compost", systemImage: inBin ? "arrow.uturn.backward" : "leaf") {
                model.toggleCompost(node)
            }
        }
    }
}

// MARK: - Smart picks

private struct SmartList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.smart.safeBytes > 0 {
                Button { model.compostAllSafe() } label: {
                    HStack {
                        Image(systemName: "leaf.fill")
                        Text("Compost everything that rebuilds itself")
                        Spacer()
                        Text(Bytes.string(model.smart.safeBytes)).font(.serif(14))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Theme.safe.color.opacity(0.3)).interactive(), in: .capsule)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.smart.picks) { pick in
                        SmartRow(pick: pick)
                    }
                    if model.smart.picks.isEmpty {
                        Text("Nothing obviously wasteful. Tidy disk!")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.inkSoft)
                            .padding(.top, 20)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

private struct SmartRow: View {
    @Environment(AppModel.self) private var model
    let pick: SmartPick

    var body: some View {
        let inBin = model.isComposted(pick.node)
        HStack(spacing: 12) {
            PetalShape()
                .fill((pick.safe ? Theme.safe : Theme.review).color)
                .frame(width: 10, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(pick.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(pick.reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(Bytes.string(pick.node.size))
                .font(.serif(16))
                .monospacedDigit()
            Button { model.toggleCompost(pick.node) } label: {
                Image(systemName: inBin ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(inBin ? .regular.tint(Theme.bloom.color.opacity(0.5)).interactive() : .regular.interactive(), in: .circle)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.ink.opacity(model.hovered === pick.node ? 0.06 : 0))
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { model.hoverFromList($0 ? pick.node : nil) }
        .onTapGesture { model.reveal(pick.node) }
        .gesture(binDrag(for: pick.node, model: model))
        .contextMenu { NodeMenu(node: pick.node) }
    }
}
