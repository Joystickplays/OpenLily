//
//  Scanner.swift
//  OpenLily
//

import Foundation
import Synchronization

/// Parallel directory walker built on getattrlistbulk(2).
///
/// One syscall returns a whole batch of entries with their name, type, allocated size,
/// modification date and inode, which is far cheaper than stat-ing each file. Worker
/// threads share a stack of directories; whoever is free takes the next one.
nonisolated final class Scanner: @unchecked Sendable {
    struct Progress: Sendable, Equatable {
        var files = 0
        var directories = 0
        var bytes: Int64 = 0
        var denied = 0
        var current = ""
    }

    let rootPath: String

    private let files = Atomic<Int>(0)
    private let directories = Atomic<Int>(0)
    private let bytes = Atomic<Int64>(0)
    private let denied = Atomic<Int>(0)
    private let cancelled = Atomic<Bool>(false)
    private let current = Mutex<String>("")
    private let seenHardLinks = Mutex<Set<UInt64>>([])

    private let condition = NSCondition()
    private var queue: [Job] = []
    private var pending = 0
    private var allowedDevices: Set<Int32> = []
    private var skippedPaths: Set<String> = []

    private struct Job {
        let node: FileNode
        let path: String
    }

    init(rootPath: String) {
        self.rootPath = rootPath
    }

    var progress: Progress {
        Progress(
            files: files.load(ordering: .relaxed),
            directories: directories.load(ordering: .relaxed),
            bytes: bytes.load(ordering: .relaxed),
            denied: denied.load(ordering: .relaxed),
            current: current.withLock { $0 }
        )
    }

    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    func cancel() {
        cancelled.store(true, ordering: .relaxed)
    }

    func run() async -> FileNode {
        await withCheckedContinuation { continuation in
            // A big stack: finalize() recurses once per nesting level.
            let thread = Thread { continuation.resume(returning: self.scan()) }
            thread.stackSize = 64 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    // MARK: - Walk

    private func scan() -> FileNode {
        var info = stat()
        if lstat(rootPath, &info) == 0 { allowedDevices.insert(info.st_dev) }
        if rootPath == "/" {
            // The writable Data volume is firmlinked into / (Users, Applications, Library…).
            // Walk it through those firmlinks, never through its mount point, and leave other volumes alone.
            if lstat("/System/Volumes/Data", &info) == 0 { allowedDevices.insert(info.st_dev) }
            skippedPaths = ["/System/Volumes", "/Volumes", "/dev", "/net", "/home"]
        }

        let root = FileNode(name: rootPath, parent: nil, isDirectory: true)
        enqueue([Job(node: root, path: rootPath)])

        let workers = min(16, max(4, ProcessInfo.processInfo.activeProcessorCount))
        let group = DispatchGroup()
        for _ in 0..<workers {
            group.enter()
            let thread = Thread {
                self.work()
                group.leave()
            }
            thread.stackSize = 1 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.wait()

        Self.finalize(root)
        return root
    }

    private func enqueue(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        condition.lock()
        queue.append(contentsOf: jobs)
        pending += jobs.count
        if jobs.count > 1 { condition.broadcast() } else { condition.signal() }
        condition.unlock()
    }

    private func next() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty && pending > 0 { condition.wait() }
        return queue.popLast()
    }

    private func finish() {
        condition.lock()
        pending -= 1
        if pending == 0 { condition.broadcast() }
        condition.unlock()
    }

    private func work() {
        let size = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        while let job = next() {
            if !isCancelled { list(job, buffer, size) }
            finish()
        }
    }

    private func list(_ job: Job, _ buffer: UnsafeMutableRawPointer, _ bufferSize: Int) {
        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == EPERM || errno == EACCES { denied.wrappingAdd(1, ordering: .relaxed) }
            return
        }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Attr.returned | Attr.error | Attr.name | Attr.devID | Attr.objType | Attr.modTime | Attr.fileID
        request.fileattr = Attr.linkCount | Attr.allocSize

        let base = job.path == "/" ? "" : job.path
        var children: [FileNode] = []
        var subdirectories: [Job] = []
        var fileCount = 0
        var byteCount: Int64 = 0

        while !isCancelled {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            guard count > 0 else { break }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }

                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                // Order follows getattrlist(2): error first, then common attrs by bit, then file attrs.
                if returned.commonattr & Attr.error != 0 {
                    let error = field.loadUnaligned(as: UInt32.self)
                    field += 4
                    if error != 0 { continue }
                }
                guard returned.commonattr & Attr.name != 0 else { continue }
                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let name = String(cString: (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                field += MemoryLayout<attrreference_t>.size

                var device: Int32 = 0
                if returned.commonattr & Attr.devID != 0 {
                    device = field.loadUnaligned(as: Int32.self)
                    field += 4
                }
                var type: UInt32 = 0
                if returned.commonattr & Attr.objType != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var modified: UInt32 = 0
                if returned.commonattr & Attr.modTime != 0 {
                    modified = UInt32(clamping: field.loadUnaligned(as: Int.self))
                    field += MemoryLayout<timespec>.size
                }
                var inode: UInt64 = 0
                if returned.commonattr & Attr.fileID != 0 {
                    inode = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }

                switch type {
                case 2: // VDIR
                    let path = base + "/" + name
                    guard allowedDevices.contains(device), !skippedPaths.contains(path) else { continue }
                    let node = FileNode(name: name, parent: job.node, isDirectory: true)
                    node.modified = modified
                    children.append(node)
                    subdirectories.append(Job(node: node, path: path))

                case 1: // VREG
                    var links: UInt32 = 1
                    if returned.fileattr & Attr.linkCount != 0 {
                        links = field.loadUnaligned(as: UInt32.self)
                        field += 4
                    }
                    var allocated: Int64 = 0
                    if returned.fileattr & Attr.allocSize != 0 {
                        allocated = field.loadUnaligned(as: Int64.self)
                        field += 8
                    }
                    // Hard links share their blocks: count them once.
                    if links > 1, !seenHardLinks.withLock({ $0.insert(inode).inserted }) {
                        allocated = 0
                    }
                    let node = FileNode(name: name, parent: job.node, isDirectory: false)
                    node.size = allocated
                    node.modified = modified
                    node.kind = FileKind.of(name: name)
                    children.append(node)
                    fileCount += 1
                    byteCount += allocated

                default:
                    continue
                }
            }
        }

        job.node.children = children
        files.wrappingAdd(fileCount, ordering: .relaxed)
        bytes.wrappingAdd(byteCount, ordering: .relaxed)
        if directories.wrappingAdd(1, ordering: .relaxed).newValue % 64 == 0 {
            current.withLock { $0 = job.path }
        }
        enqueue(subdirectories)
    }

    // MARK: - Totals

    /// Sums sizes bottom-up, sorts children big-first and works out each folder's dominant kind.
    @discardableResult
    private static func finalize(_ node: FileNode) -> SIMD8<Int64> {
        var kinds = SIMD8<Int64>(repeating: 0)
        guard node.isDirectory else {
            kinds[Int(node.kind.rawValue)] = node.size
            return kinds
        }
        var size: Int64 = 0
        var items: Int32 = 0
        var newest = node.modified
        for child in node.children {
            kinds &+= finalize(child)
            size += child.size
            items += child.items
            newest = max(newest, child.modified)
        }
        node.children.sort { $0.size > $1.size }
        node.size = size
        node.items = items
        node.modified = newest

        if FileKind.of(name: node.name) == .app {
            node.kind = .app
        } else if size > 0 {
            var best = 0
            for i in 1..<8 where kinds[i] > kinds[best] { best = i }
            node.kind = FileKind(rawValue: UInt8(best)) ?? .other
        }
        return kinds
    }
}

nonisolated private enum Attr {
    static let returned: attrgroup_t = 0x8000_0000 // ATTR_CMN_RETURNED_ATTRS
    static let error: attrgroup_t = 0x2000_0000 // ATTR_CMN_ERROR
    static let name: attrgroup_t = 0x0000_0001 // ATTR_CMN_NAME
    static let devID: attrgroup_t = 0x0000_0002 // ATTR_CMN_DEVID
    static let objType: attrgroup_t = 0x0000_0008 // ATTR_CMN_OBJTYPE
    static let modTime: attrgroup_t = 0x0000_0400 // ATTR_CMN_MODTIME
    static let fileID: attrgroup_t = 0x0200_0000 // ATTR_CMN_FILEID
    static let linkCount: attrgroup_t = 0x0000_0001 // ATTR_FILE_LINKCOUNT
    static let allocSize: attrgroup_t = 0x0000_0004 // ATTR_FILE_ALLOCSIZE
}
