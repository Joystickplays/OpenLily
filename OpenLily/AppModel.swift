//
//  AppModel.swift
//  OpenLily
//

import SwiftUI
import AppKit
import Observation

enum Phase: Equatable {
    case start, scanning, ready
}

enum SidebarTab: Equatable {
    case inView, smart
}

struct Camera: Equatable {
    var scale: Double = 1
    var pan: CGSize = .zero
}

struct VolumeInfo: Identifiable, Equatable {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    let importantFree: Int64

    var used: Int64 { max(0, total - free) }
    var purgeable: Int64 { max(0, importantFree - free) }
    var isRoot: Bool { url.path == "/" }
    var id: URL { url }
}

struct BinDrag {
    var nodes: [FileNode]
    var point: CGPoint
    var overBin: Bool
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String?
    var canUndo = false

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct Particle {
    let origin: CGPoint
    let velocity: CGVector
    let angle: Double
    let spin: Double
    let size: Double
    let color: Color
    let born: Date
    let life: Double
}

enum Hit {
    case none
    case center
    case node(FileNode)
}

private struct TrashRecord {
    let node: FileNode
    let parent: FileNode
    let original: URL
    let trashed: URL
}

@Observable
final class AppModel {
    // MARK: Start
    var phase: Phase = .start
    var volumes: [VolumeInfo] = []
    var hasFullDiskAccess = true

    // MARK: Scan
    var progress = Scanner.Progress()
    var scanTitle = ""
    var scanURL: URL?
    var scanVolume: VolumeInfo?
    var scannedAt = Date()
    var deniedCount = 0
    @ObservationIgnored private var scanner: Scanner?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    // MARK: Tree
    var root: FileNode?
    var focus: FileNode?
    var focusFrom: FileNode?
    var focusEpoch: Double = 0
    var smart = SmartReport()
    /// Bumped whenever sizes in the tree change, since the nodes themselves aren't observable.
    var revision = 0
    var colorMode: ColorMode = .folder
    var sidebarTab: SidebarTab = .inView

    // MARK: Camera
    var camera = Camera()
    var ringSize: CGSize = .zero {
        didSet { if oldValue != ringSize { refreshInView() } }
    }

    // MARK: Hover
    var hovered: FileNode?
    var hoveringCenter = false
    var calloutAnchor: CGPoint?

    // MARK: In view
    var inView: [FileNode] = []
    var inViewAnchor: FileNode?

    // MARK: Compost
    var compost: [FileNode] = []
    var compostIDs: Set<ObjectIdentifier> = []
    var drag: BinDrag?
    var binPulse = 0
    @ObservationIgnored var binFrame: CGRect = .zero
    @ObservationIgnored var chipFrames: [ObjectIdentifier: CGRect] = [:]

    // MARK: Falling
    var countdown: Int?
    var dying: [ObjectIdentifier: Int64] = [:]
    var growing = false
    var wiltEpoch: Double = 0
    var particles: [Particle] = []
    var shake = 0
    var toast: Toast?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var lastTrash: [TrashRecord] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    // MARK: Search
    var searchText = "" {
        didSet { if oldValue != searchText { scheduleSearch() } }
    }
    var search: SearchResult?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    var quickLookURL: URL?

    init() {
        refreshVolumes()
        // Dev convenience: OPENLILY_SCAN=/some/path skips the start screen.
        if let path = ProcessInfo.processInfo.environment["OPENLILY_SCAN"] {
            Task { self.scan(URL(fileURLWithPath: path)) }
        }
    }

    // MARK: - Volumes

    func refreshVolumes() {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let free = Int64(v.volumeAvailableCapacity ?? 0)
            return VolumeInfo(
                url: url,
                name: v.volumeName ?? url.lastPathComponent,
                total: Int64(total),
                free: free,
                importantFree: v.volumeAvailableCapacityForImportantUsage ?? free
            )
        }
        if let current = scanVolume, let fresh = volumes.first(where: { $0.url == current.url }) {
            scanVolume = fresh
        }
        // TCC.db is only readable with Full Disk Access, which makes it a cheap probe.
        let fd = Darwin.open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        hasFullDiskAccess = fd >= 0
        if fd >= 0 { close(fd) }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Pick a folder or drive to bloom."
        if panel.runModal() == .OK, let url = panel.url {
            scan(url)
        }
    }

    func scan(_ url: URL) {
        scanTask?.cancel()
        scanner?.cancel()
        refreshVolumes()

        let path = url.standardizedFileURL.path
        let volume = volumes.first { $0.url.standardizedFileURL.path == path }
        scanURL = url
        scanVolume = volume
        scanTitle = volume?.name ?? url.lastPathComponent
        progress = Scanner.Progress()
        clearSearch()
        withAnimation(.smooth(duration: 0.5)) { phase = .scanning }

        let scanner = Scanner(rootPath: path)
        self.scanner = scanner
        scanTask = Task { [weak self] in
            let poll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.progress = scanner.progress
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let root = await scanner.run()
            poll.cancel()
            guard let self, !scanner.isCancelled, self.scanner === scanner else { return }
            self.progress = scanner.progress
            self.addHiddenSpace(to: root, volume: volume)
            let report = await Self.analyze(root)
            self.install(root, report: report, denied: scanner.progress.denied)
        }
    }

    func cancelScan() {
        scanner?.cancel()
        scanTask?.cancel()
        scanner = nil
        withAnimation(.smooth(duration: 0.5)) { phase = root == nil ? .start : .ready }
    }

    func rescan() {
        if let scanURL { scan(scanURL) }
    }

    func backToStart() {
        refreshVolumes()
        withAnimation(.smooth(duration: 0.5)) { phase = .start }
    }

    private nonisolated static func analyze(_ root: FileNode) async -> SmartReport {
        await Task.detached(priority: .userInitiated) {
            SmartScanner.analyze(root: root, home: NSHomeDirectory())
        }.value
    }

    /// Space the volume says is used but we couldn't see: snapshots, other APFS volumes, locked folders.
    private func addHiddenSpace(to root: FileNode, volume: VolumeInfo?) {
        guard let volume else { return }
        let hidden = volume.used - root.size
        guard hidden > max(500_000_000, volume.used / 200) else { return }
        let node = FileNode(name: "Hidden space", parent: root, isDirectory: false)
        node.size = hidden
        node.isSynthetic = true
        root.children.append(node)
        root.children.sort { $0.size > $1.size }
        root.size += hidden
    }

    private func install(_ root: FileNode, report: SmartReport, denied: Int) {
        self.root = root
        focus = root
        focusFrom = root
        smart = report
        compost = []
        compostIDs = []
        dying = [:]
        hovered = nil
        camera = Camera()
        deniedCount = denied
        scannedAt = Date()
        lastTrash = []
        revision += 1
        refreshInView()
        withAnimation(.smooth(duration: 0.6)) { phase = .ready }
    }

    var isVolumeScan: Bool { scanVolume != nil }

    // MARK: - Geometry

    var viewport: Viewport {
        Viewport(size: ringSize, scale: camera.scale, pan: camera.pan)
    }

    func hitTest(_ p: CGPoint) -> Hit {
        guard let focus, ringSize.width > 0 else { return .none }
        let vp = viewport
        let w = vp.world(p)
        let r = hypot(w.x, w.y)
        if r <= Ring.core { return .center }

        var frac = Ring.angle(of: w) / (2 * .pi)
        var node = focus
        var a0 = 0.0, a1 = 2 * Double.pi
        var d = 1
        while true {
            let total = Double(node.size)
            guard total > 0, !node.children.isEmpty else { return .none }
            var acc = 0.0
            var hit: (FileNode, Double, Double)?
            for child in node.children {
                let f = Double(child.size) / total
                if frac < acc + f {
                    hit = (child, acc, f)
                    break
                }
                acc += f
            }
            guard let (child, start, f) = hit, f > 0 else { return .none }
            let ca0 = a0 + (a1 - a0) * start
            let ca1 = ca0 + (a1 - a0) * f
            let depth = Double(d)
            let ri = Ring.inner(depth), ro = Ring.outer(depth, scale: camera.scale)
            guard Ring.alpha(depth, scale: camera.scale) >= 0.4, (ca1 - ca0) * ro * vp.k >= 0.7 else { return .none }
            if r < ri - Ring.gap { return .none }
            if r <= ro + Ring.gap / 2 { return .node(child) }

            let deeper = child.hasChildren && Ring.alpha(depth + 1, scale: camera.scale) >= 0.4
            if deeper {
                node = child
                frac = (frac - start) / f
                a0 = ca0
                a1 = ca1
                d += 1
                continue
            }
            let tip = Ring.tip(ro: ro, span: ca1 - ca0, depth: depth)
            return r <= ro + tip ? .node(child) : .none
        }
    }

    func node(at p: CGPoint) -> FileNode? {
        if case .node(let n) = hitTest(p) { return n }
        return nil
    }

    /// Where a node currently sits on the ring (relative to the focus), if it does.
    func sector(of node: FileNode) -> (a0: Double, a1: Double, depth: Double)? {
        guard let focus, node !== focus else { return nil }
        var chain: [FileNode] = []
        var n: FileNode? = node
        while let c = n, c !== focus {
            chain.append(c)
            n = c.parent
        }
        guard n === focus else { return nil }
        var a0 = 0.0, a1 = 2 * Double.pi
        var parent = focus
        for child in chain.reversed() {
            let total = Double(parent.size)
            guard total > 0 else { return nil }
            var before = 0.0
            for c in parent.children {
                if c === child { break }
                before += Double(c.size)
            }
            let span = a1 - a0
            a0 += span * before / total
            a1 = a0 + span * Double(child.size) / total
            parent = child
        }
        return (a0, a1, Double(chain.count))
    }

    /// The middle of a node's segment on screen, clamped to the deepest ring currently showing.
    func anchorPoint(of node: FileNode) -> CGPoint? {
        guard let s = sector(of: node) else { return nil }
        let d = min(s.depth, floor(Ring.visibleDepth(camera.scale)))
        let r = (Ring.inner(d) + Ring.outer(d)) / 2
        return viewport.screen(Ring.point(r, (s.a0 + s.a1) / 2))
    }

    // MARK: - In view

    /// What the sidebar lists: walk down while only one folder is on screen, then list the visible ones.
    func refreshInView() {
        guard let focus, ringSize.width > 0 else { return }
        let vp = viewport
        let world = vp.worldRect
        let scale = camera.scale
        var anchor = focus
        var a0 = 0.0, a1 = 2 * Double.pi
        var d = 1
        var visible: [FileNode] = []
        let outerEdge = Ring.outer(Ring.visibleDepth(scale)) + 80

        while true {
            let depth = Double(d)
            let total = Double(anchor.size)
            guard total > 0, Ring.alpha(depth, scale: scale) >= 0.5 else { break }
            let ri = Ring.inner(depth), ro = Ring.outer(depth)
            var found: [(FileNode, Double, Double)] = []
            var a = a0
            for child in anchor.children {
                let span = (a1 - a0) * Double(child.size) / total
                if span * ro * vp.k < 2 { break }
                if Ring.intersects(world, ri, outerEdge, a, a + span) {
                    found.append((child, a, a + span))
                }
                a += span
            }
            if found.count == 1, let only = found.first, only.0.hasChildren,
               Ring.alpha(depth + 1, scale: scale) >= 0.5 {
                anchor = only.0
                a0 = only.1
                a1 = only.2
                d += 1
                continue
            }
            visible = found.map(\.0)
            break
        }
        if inViewAnchor !== anchor { inViewAnchor = anchor }
        if visible.map(\.id) != inView.map(\.id) { inView = visible }
    }

    // MARK: - Hover & navigation

    func hover(at p: CGPoint?) {
        guard drag == nil, let p else {
            if hovered != nil { hovered = nil }
            hoveringCenter = false
            return
        }
        switch hitTest(p) {
        case .node(let n):
            if hovered !== n { hovered = n }
            hoveringCenter = false
            calloutAnchor = p
        case .center:
            if hovered != nil { hovered = nil }
            hoveringCenter = true
        case .none:
            if hovered != nil { hovered = nil }
            hoveringCenter = false
        }
    }

    func hoverFromList(_ node: FileNode?) {
        guard drag == nil else { return }
        hovered = node
        if let node { calloutAnchor = anchorPoint(of: node) }
    }

    func click(at p: CGPoint, count: Int) {
        switch hitTest(p) {
        case .center: goUp()
        case .node(let n): open(n, count: count)
        case .none: break
        }
    }

    func open(_ node: FileNode, count: Int = 1) {
        if node.hasChildren {
            drill(into: node)
        } else if count >= 2, !node.isSynthetic {
            quickLookURL = node.url
        }
    }

    func drill(into node: FileNode) {
        guard let current = focus, node !== current, node === root || node.hasChildren else { return }
        focusFrom = current
        focus = node
        hovered = nil
        withAnimation(.smooth(duration: 0.7)) {
            focusEpoch += 1
            camera = Camera()
        }
        refreshInView()
    }

    func goUp() {
        if let parent = focus?.parent { drill(into: parent) }
    }

    // MARK: - Camera

    func pan(by delta: CGSize) {
        let limit = Ring.reach * viewport.k + max(ringSize.width, ringSize.height) / 2
        camera.pan.width = min(limit, max(-limit, camera.pan.width + delta.width))
        camera.pan.height = min(limit, max(-limit, camera.pan.height + delta.height))
        hovered = nil
        refreshInView()
    }

    func zoom(by factor: Double, around point: CGPoint?) {
        let anchor = point ?? CGPoint(x: ringSize.width / 2, y: ringSize.height / 2)
        let w = viewport.world(anchor)
        camera.scale = min(64, max(0.5, camera.scale * factor))
        let moved = viewport.screen(w)
        camera.pan.width += anchor.x - moved.x
        camera.pan.height += anchor.y - moved.y
        hovered = nil
        refreshInView()
    }

    func zoomStep(_ direction: Int) {
        withAnimation(.snappy(duration: 0.35)) {
            zoom(by: direction > 0 ? 1.6 : 1 / 1.6, around: nil)
        }
    }

    func resetCamera() {
        withAnimation(.smooth(duration: 0.5)) { camera = Camera() }
        refreshInView()
    }

    // MARK: - Colors

    func swatch(for node: FileNode) -> RGB {
        let painter = Painter(mode: colorMode)
        guard let focus else { return Theme.petals[0] }
        var chain: [FileNode] = []
        var n: FileNode? = node
        while let c = n, c !== focus {
            chain.append(c)
            n = c.parent
        }
        let index = node.parent?.children.firstIndex { $0 === node } ?? 0
        guard n === focus, let top = chain.last else {
            return painter.color(node, base: Theme.petals[0], depth: 1, index: index)
        }
        let topIndex = focus.children.firstIndex { $0 === top } ?? 0
        return painter.color(node, base: Theme.petals[topIndex % Theme.petals.count], depth: Double(chain.count), index: index)
    }

    // MARK: - Compost

    var compostBytes: Int64 { compost.reduce(0) { $0 + $1.size } }

    func isComposted(_ node: FileNode) -> Bool {
        var n: FileNode? = node
        while let c = n {
            if compostIDs.contains(c.id) { return true }
            n = c.parent
        }
        return false
    }

    /// Why a node may not go in the compost, or nil if it may.
    func protectedReason(_ node: FileNode) -> String? {
        if node.isSynthetic { return "Hidden space isn't a file you can bin." }
        if node.parent == nil { return "That's the whole scan. Pick something inside it." }
        let path = node.path
        let guarded = ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/private/var/vm", "/Library/Apple", "/cores"]
        if guarded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "macOS needs that one. Leaving it be."
        }
        if path == NSHomeDirectory() || path == "/Users" || path == "/Applications" || path == "/Library" || path == "/private" {
            return "Too important to bin in one go. Open it up and pick pieces."
        }
        return nil
    }

    func canDrag(_ node: FileNode) -> Bool {
        !node.isSynthetic && node.parent != nil
    }

    func addToCompost(_ nodes: [FileNode]) {
        var added = false
        for node in nodes {
            if let reason = protectedReason(node) {
                showToast(Toast(title: reason))
                continue
            }
            if isComposted(node) { continue }
            compost.removeAll { $0.isDescendant(of: node) }
            compost.append(node)
            added = true
        }
        compostIDs = Set(compost.map(\.id))
        if added {
            binPulse += 1
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func removeFromCompost(_ node: FileNode) {
        compost.removeAll { $0 === node }
        compostIDs = Set(compost.map(\.id))
    }

    func toggleCompost(_ node: FileNode) {
        if compostIDs.contains(node.id) {
            withAnimation(.snappy) { removeFromCompost(node) }
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) { addToCompost([node]) }
        }
    }

    func compostAllSafe() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
            addToCompost(smart.picks.filter(\.safe).map(\.node))
        }
    }

    func compostHovered() {
        if let hovered { toggleCompost(hovered) }
    }

    // MARK: - Dragging to the bin

    func beginDrag(_ nodes: [FileNode], at point: CGPoint) {
        let movable = nodes.filter(canDrag)
        guard !movable.isEmpty else { return }
        hovered = nil
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            drag = BinDrag(nodes: movable, point: point, overBin: binFrame.contains(point))
        }
    }

    func moveDrag(to point: CGPoint) {
        guard drag != nil else { return }
        drag?.point = point
        let over = binFrame.insetBy(dx: -14, dy: -14).contains(point)
        if drag?.overBin != over {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { drag?.overBin = over }
        }
    }

    func endDrag() {
        guard let d = drag else { return }
        if d.overBin {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { addToCompost(d.nodes) }
        }
        withAnimation(.easeOut(duration: 0.18)) { drag = nil }
    }

    // MARK: - Letting them fall

    func letThemFall() {
        guard !compost.isEmpty, countdown == nil else { return }
        countdownTask = Task { [weak self] in
            for n in [3, 2, 1] {
                guard let self, !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { self.countdown = n }
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                NSSound(named: "Tink")?.play()
                try? await Task.sleep(for: .milliseconds(950))
            }
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.countdown = nil }
            await self.destroy()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        withAnimation(.smooth(duration: 0.3)) { countdown = nil }
    }

    private func destroy() async {
        let doomed = compost
        guard !doomed.isEmpty else { return }
        spawnParticles(for: doomed)
        shake += 1
        NSSound(named: "Pop")?.play()

        let jobs = doomed.map { ($0, $0.url) }
        let results: [(FileNode, URL?, String?)] = await Task.detached(priority: .userInitiated) {
            jobs.map { node, url in
                do {
                    var out: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &out)
                    return (node, out as URL?, nil)
                } catch {
                    return (node, nil, error.localizedDescription)
                }
            }
        }.value

        var records: [TrashRecord] = []
        var failures: [String] = []
        for (node, trashed, error) in results {
            if let trashed, let parent = node.parent {
                records.append(TrashRecord(node: node, parent: parent, original: node.url, trashed: trashed))
            } else {
                failures.append(error ?? node.name)
            }
        }

        let gone = Set(records.map(\.node.id))
        compost.removeAll { gone.contains($0.id) }
        compostIDs = Set(compost.map(\.id))

        // Step the focus out of anything that's about to disappear.
        if let focus, let lost = records.first(where: { focus === $0.node || focus.isDescendant(of: $0.node) }) {
            drill(into: lost.parent)
        }

        var shrinking: [ObjectIdentifier: Int64] = [:]
        for r in records {
            var n: FileNode? = r.node
            while let c = n {
                shrinking[c.id, default: 0] += r.node.size
                n = c.parent
            }
        }
        dying = shrinking
        growing = false
        withAnimation(.easeInOut(duration: 1.1)) {
            wiltEpoch += 1
        } completion: { [weak self] in
            self?.commitRemoval(records)
        }

        let freed = records.reduce(Int64(0)) { $0 + $1.node.size }
        if records.isEmpty {
            showToast(Toast(title: "Nothing fell.", detail: failures.first))
        } else {
            // Without Full Disk Access macOS won't let us read ~/.Trash, so Undo has to go through Finder.
            refreshVolumes()
            var tail = hasFullDiskAccess ? "It's all in the Trash." : "It's in the Trash. Put Back from Finder if you miss it."
            if !failures.isEmpty { tail = "\(failures.count) couldn't move: \(failures[0])" }
            showToast(Toast(title: "Freed \(Bytes.string(freed))", detail: tail, canUndo: hasFullDiskAccess), seconds: 10)
        }
    }

    private func commitRemoval(_ records: [TrashRecord]) {
        for r in records {
            r.parent.children.removeAll { $0 === r.node }
            var n: FileNode? = r.parent
            while let c = n {
                c.size -= r.node.size
                c.items -= r.node.items
                n = c.parent
            }
        }
        dying = [:]
        lastTrash = records
        revision += 1
        refreshVolumes()
        refreshInView()
        reanalyze()
    }

    func undoLastFall() {
        let records = lastTrash
        guard !records.isEmpty else { return }
        lastTrash = []
        toast = nil
        Task {
            let moves = records.map { ($0.trashed, $0.original) }
            let restored: [Bool] = await Task.detached {
                moves.map { trashed, original in
                    (try? FileManager.default.moveItem(at: trashed, to: original)) != nil
                }
            }.value

            var growth: [ObjectIdentifier: Int64] = [:]
            for (r, ok) in zip(records, restored) where ok {
                let index = r.parent.children.firstIndex { $0.size < r.node.size } ?? r.parent.children.endIndex
                r.parent.children.insert(r.node, at: index)
                r.node.parent = r.parent
                var n: FileNode? = r.parent
                while let c = n {
                    c.size += r.node.size
                    c.items += r.node.items
                    n = c.parent
                }
                var m: FileNode? = r.node
                while let c = m {
                    growth[c.id, default: 0] += r.node.size
                    m = c.parent
                }
            }
            dying = growth
            growing = true
            revision += 1
            withAnimation(.spring(response: 0.9, dampingFraction: 0.8)) {
                wiltEpoch += 1
            } completion: {
                self.dying = [:]
                self.growing = false
            }
            let count = restored.filter { $0 }.count
            if count == records.count {
                showToast(Toast(title: "Back where they were."))
            } else if count == 0 {
                showToast(Toast(title: "The Trash wouldn't open.", detail: "Use Put Back in Finder, or give OpenLily Full Disk Access."), seconds: 7)
            } else {
                showToast(Toast(title: "Restored \(count) of \(records.count).", detail: "Put the rest back from Finder."), seconds: 7)
            }
            refreshVolumes()
            refreshInView()
            reanalyze()
        }
    }

    private func reanalyze() {
        guard let root else { return }
        Task {
            let report = await Self.analyze(root)
            if self.root === root { smart = report }
        }
    }

    private func spawnParticles(for nodes: [FileNode]) {
        let now = Date()
        var fresh: [Particle] = []
        let vp = viewport
        let budget = 520
        for node in nodes {
            let color = swatch(for: node).color
            if let s = sector(of: node) {
                let d = min(s.depth, floor(Ring.visibleDepth(camera.scale)))
                let ri = Ring.inner(d), ro = Ring.outer(d)
                let arc = (s.a1 - s.a0) * ro * vp.k
                let count = min(140, max(8, Int(arc / 5)))
                for _ in 0..<count where fresh.count < budget {
                    let a = Double.random(in: s.a0...max(s.a0, s.a1))
                    let r = Double.random(in: ri...ro)
                    let p = vp.screen(Ring.point(r, a))
                    let out = Ring.point(1, a)
                    let burst = Double.random(in: 80...260)
                    fresh.append(Particle(
                        origin: p,
                        velocity: CGVector(dx: out.x * burst + .random(in: -40...40), dy: out.y * burst - .random(in: 60...220)),
                        angle: .random(in: 0...(2 * .pi)),
                        spin: .random(in: -7...7),
                        size: .random(in: 7...15),
                        color: color,
                        born: now.addingTimeInterval(.random(in: 0...0.25)),
                        life: .random(in: 1.4...2.3)
                    ))
                }
            }
            if let chip = chipFrames[node.id] {
                for _ in 0..<12 {
                    fresh.append(Particle(
                        origin: CGPoint(x: .random(in: chip.minX...chip.maxX), y: .random(in: chip.minY...chip.maxY)),
                        velocity: CGVector(dx: .random(in: -120...120), dy: .random(in: -260 ... -60)),
                        angle: .random(in: 0...(2 * .pi)),
                        spin: .random(in: -8...8),
                        size: .random(in: 6...11),
                        color: color,
                        born: now,
                        life: .random(in: 1.2...1.9)
                    ))
                }
            }
        }
        particles.append(contentsOf: fresh)
        Task {
            try? await Task.sleep(for: .seconds(3))
            let cutoff = Date().addingTimeInterval(-2.6)
            particles.removeAll { $0.born < cutoff }
        }
    }

    // MARK: - Toasts

    func showToast(_ t: Toast, seconds: Double = 4) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { toast = t }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { if toast == t { toast = nil } }
        }
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, let root else {
            withAnimation(.smooth) { search = nil }
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                SearchEngine.run(root: root, query: query)
            }.value
            guard !Task.isCancelled, searchText.trimmingCharacters(in: .whitespaces) == query else { return }
            withAnimation(.smooth) { search = result }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        search = nil
    }

    func compostSearchResults() {
        guard let search else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
            addToCompost(search.tops.filter { protectedReason($0) == nil })
        }
    }

    // MARK: - Finder bits

    func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func copyPath(_ node: FileNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    func quickLook(_ node: FileNode) {
        guard !node.isSynthetic else { return }
        quickLookURL = node.url
    }

    func quickLookHovered() {
        if let hovered { quickLook(hovered) }
    }

    func contextMenu(for node: FileNode) -> NSMenu {
        let menu = NSMenu()
        if node.hasChildren {
            menu.addItem(ActionMenuItem("Open Up", symbol: "arrow.up.left.and.arrow.down.right") { [weak self] in self?.drill(into: node) })
        }
        if !node.isSynthetic {
            menu.addItem(ActionMenuItem("Quick Look", symbol: "eye") { [weak self] in self?.quickLook(node) })
            menu.addItem(ActionMenuItem("Reveal in Finder", symbol: "folder") { [weak self] in self?.reveal(node) })
            menu.addItem(ActionMenuItem("Copy Path", symbol: "doc.on.doc") { [weak self] in self?.copyPath(node) })
            menu.addItem(.separator())
            let inBin = compostIDs.contains(node.id)
            menu.addItem(ActionMenuItem(inBin ? "Take Out of Compost" : "Add to Compost", symbol: inBin ? "arrow.uturn.backward" : "leaf") { [weak self] in
                self?.toggleCompost(node)
            })
        }
        return menu
    }

    // MARK: - Summary strings

    var relativeScanTime: String {
        let seconds = Date().timeIntervalSince(scannedAt)
        if seconds < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: scannedAt, relativeTo: Date())
    }

    func detail(for node: FileNode) -> String {
        var lines: [String] = []
        if node.isSynthetic {
            lines.append("Snapshots, other APFS volumes, purgeable files and folders macOS wouldn't show us.")
            return lines.joined(separator: "\n")
        }
        let home = NSHomeDirectory()
        var path = node.path
        if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
        lines.append(path)

        var facts: [String] = []
        if node.isDirectory { facts.append("\(Int(node.items).formatted()) files") }
        switch colorMode {
        case .kind: facts.append(node.kind.title.lowercased())
        case .age, .folder:
            if node.modified > 0 {
                let date = Date(timeIntervalSince1970: Double(node.modified))
                facts.append("touched " + date.formatted(.relative(presentation: .named)))
            }
        }
        lines.append(facts.joined(separator: " · "))

        if let pick = smart.pick(for: node) {
            lines.append(pick.reason)
        } else if let r = smart.reclaimable[node.id], node.size > 0 {
            let pct = Int((Double(r) / Double(node.size) * 100).rounded())
            if pct >= 5 { lines.append("\(pct)% of it rebuilds itself") }
        }
        if compostIDs.contains(node.id) { lines.append("Wilting in the compost") }
        return lines.joined(separator: "\n")
    }
}

/// NSMenuItem that runs a closure, for the ring's right-click menu.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() {
        handler()
    }
}
