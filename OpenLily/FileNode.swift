//
//  FileNode.swift
//  OpenLily
//

import Foundation

nonisolated enum FileKind: UInt8, CaseIterable, Sendable {
    case video, image, audio, document, code, archive, app, other

    var title: String {
        switch self {
        case .video: "Video"
        case .image: "Images"
        case .audio: "Audio"
        case .document: "Documents"
        case .code: "Code & dev"
        case .archive: "Archives"
        case .app: "Apps"
        case .other: "Other"
        }
    }

    var rgb: RGB {
        switch self {
        case .video: RGB(0xE9738A)
        case .image: RGB(0xF29E6D)
        case .audio: RGB(0xE8C15A)
        case .document: RGB(0x8FB3E8)
        case .code: RGB(0x6FB59A)
        case .archive: RGB(0xB48FE0)
        case .app: RGB(0xE58FB8)
        case .other: RGB(0xC9BFB3)
        }
    }

    static func of(name: String) -> FileKind {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return .other }
        let ext = name[name.index(after: dot)...]
        guard ext.count <= 10 else { return .other }
        return table[ext.lowercased()] ?? .other
    }

    private static let table: [String: FileKind] = {
        var t: [String: FileKind] = [:]
        let groups: [(FileKind, String)] = [
            (.video, "mov mp4 m4v mkv avi webm wmv flv mpg mpeg mts m2ts 3gp braw r3d mxf prproj fcpbundle"),
            (.image, "jpg jpeg png heic heif gif tif tiff bmp webp raw cr2 cr3 nef arw dng psd psb ai svg exr hdr kra afphoto sketch fig"),
            (.audio, "mp3 m4a aac wav aif aiff flac ogg opus alac caf logicx band mid midi"),
            (.document, "pdf doc docx pages key keynote numbers xls xlsx ppt pptx txt rtf md csv epub mobi"),
            (.code, "swift m h c cc cpp hpp js mjs ts tsx jsx py rb go rs java kt json yaml yml toml xml html css scss o a dylib so pch pcm swiftmodule swiftdoc dSYM jar class wasm sqlite db map cjs mjs cts mts node lock gradle plist storyboard xib nib car metallib bc ll"),
            (.archive, "zip gz tgz bz2 xz 7z rar tar dmg iso pkg xip img sparseimage sparsebundle qcow2 vmdk vdi raw"),
            (.app, "app appex framework bundle plugin"),
        ]
        for (kind, list) in groups {
            for ext in list.split(separator: " ") where t[String(ext).lowercased()] == nil {
                t[String(ext).lowercased()] = kind
            }
        }
        return t
    }()
}

/// One file or folder in the scanned tree.
///
/// Kept deliberately small: a full disk is millions of these. The parent pointer is
/// unowned(unsafe) because parents always own (and outlive) their children.
nonisolated final class FileNode: Identifiable, @unchecked Sendable {
    let name: String
    unowned(unsafe) var parent: FileNode?
    var children: [FileNode] = []
    /// Allocated bytes on disk (folders: sum of children).
    var size: Int64 = 0
    /// Files contained (1 for a file).
    var items: Int32
    /// Seconds since 1970; for folders, the newest thing inside.
    var modified: UInt32 = 0
    let isDirectory: Bool
    var kind: FileKind = .other
    /// Not a real file, e.g. the "Hidden space" slice.
    var isSynthetic = false

    init(name: String, parent: FileNode?, isDirectory: Bool) {
        self.name = name
        self.parent = parent
        self.isDirectory = isDirectory
        self.items = isDirectory ? 0 : 1
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }

    var path: String {
        var names: [String] = []
        var node: FileNode = self
        while let parent = node.parent {
            names.append(node.name)
            node = parent
        }
        guard !names.isEmpty else { return node.name }
        let rest = names.reversed().joined(separator: "/")
        return node.name.hasSuffix("/") ? node.name + rest : node.name + "/" + rest
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }

    var displayName: String {
        guard parent == nil else { return name }
        return name == "/" ? "Macintosh HD" : (name as NSString).lastPathComponent
    }

    var depth: Int {
        var d = 0
        var n = parent
        while let p = n {
            d += 1
            n = p.parent
        }
        return d
    }

    /// Root first, self last.
    var lineage: [FileNode] {
        var chain: [FileNode] = [self]
        var n = parent
        while let p = n {
            chain.append(p)
            n = p.parent
        }
        return chain.reversed()
    }

    func isDescendant(of other: FileNode) -> Bool {
        var n = parent
        while let p = n {
            if p === other { return true }
            n = p.parent
        }
        return false
    }

    var hasChildren: Bool { isDirectory && !children.isEmpty }
}
