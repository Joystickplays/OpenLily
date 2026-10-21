//
//  Smart.swift
//  OpenLily
//

import Foundation

/// Something that is probably safe (or worth a look) to throw away, with a reason a human can judge.
nonisolated struct SmartPick: Identifiable, Sendable {
    let node: FileNode
    let title: String
    let reason: String
    /// True when the thing regenerates itself (caches, build output). False means "have a look first".
    let safe: Bool

    var id: ObjectIdentifier { node.id }
}

nonisolated struct SmartReport: Sendable {
    var picks: [SmartPick] = []
    /// Bytes of safe picks inside each folder, for the "61% of it rebuilds itself" line.
    var reclaimable: [ObjectIdentifier: Int64] = [:]
    var safeBytes: Int64 = 0

    func pick(for node: FileNode) -> SmartPick? {
        picks.first { $0.node === node }
    }
}

nonisolated enum SmartScanner {
    private struct Rule {
        let title: String
        let reason: String
        let safe: Bool
    }

    static func analyze(root: FileNode, home: String) -> SmartReport {
        let lib = home + "/Library"
        let exact: [String: Rule] = [
            lib + "/Developer/Xcode/DerivedData": Rule(title: "Xcode DerivedData", reason: "Build cache. Rebuilds itself the next time you hit ⌘B.", safe: true),
            lib + "/Developer/Xcode/iOS DeviceSupport": Rule(title: "iOS DeviceSupport", reason: "Debug symbols, re-downloaded when you plug a device in.", safe: true),
            lib + "/Developer/Xcode/watchOS DeviceSupport": Rule(title: "watchOS DeviceSupport", reason: "Debug symbols, re-downloaded when needed.", safe: true),
            lib + "/Developer/Xcode/tvOS DeviceSupport": Rule(title: "tvOS DeviceSupport", reason: "Debug symbols, re-downloaded when needed.", safe: true),
            lib + "/Developer/Xcode/visionOS DeviceSupport": Rule(title: "visionOS DeviceSupport", reason: "Debug symbols, re-downloaded when needed.", safe: true),
            lib + "/Developer/CoreSimulator/Caches": Rule(title: "Simulator caches", reason: "Xcode regenerates these.", safe: true),
            lib + "/Developer/Xcode/Archives": Rule(title: "Xcode Archives", reason: "Old builds. Keep the ones you actually shipped.", safe: false),
            lib + "/Developer/CoreSimulator/Devices": Rule(title: "Simulators", reason: "Simulator devices pile up. Keep the ones you test on.", safe: false),
            lib + "/Application Support/MobileSync/Backup": Rule(title: "Device backups", reason: "Local iPhone/iPad backups. iCloud may already cover you.", safe: false),
            lib + "/Containers/com.docker.docker": Rule(title: "Docker", reason: "Images and volumes live in here. Prune from Docker rather than deleting.", safe: false),
            home + "/.Trash": Rule(title: "Trash", reason: "Already thrown out, just not gone yet.", safe: true),
            home + "/.npm/_cacache": Rule(title: "npm cache", reason: "Download cache. npm refills it on demand.", safe: true),
            home + "/.gradle/caches": Rule(title: "Gradle caches", reason: "Dependency cache. Re-downloaded on the next build.", safe: true),
            home + "/.cargo/registry": Rule(title: "Cargo registry", reason: "Crate downloads. Cargo fetches them again when needed.", safe: true),
            home + "/go/pkg/mod": Rule(title: "Go module cache", reason: "`go mod download` brings it back.", safe: true),
            home + "/.cache": Rule(title: "~/.cache", reason: "Tool caches. Some (like ML models) are big to re-download.", safe: false),
        ]
        let caches = lib + "/Caches"
        let downloads = home + "/Downloads"
        let now = Date().timeIntervalSince1970
        let monthYear = DateFormatter()
        monthYear.dateFormat = "MMM yyyy"
        let minimum: Int64 = 5_000_000

        var picks: [SmartPick] = []

        func add(_ node: FileNode, _ rule: Rule) {
            guard node.size >= minimum else { return }
            picks.append(SmartPick(node: node, title: rule.title, reason: rule.reason, safe: rule.safe))
        }

        func sibling(_ node: FileNode, named name: String) -> Bool {
            node.parent?.children.contains { $0.name == name } ?? false
        }

        func visit(_ node: FileNode, _ path: String) {
            guard node.isDirectory else {
                guard path.hasPrefix(home + "/"), node.size >= 20_000_000 else { return }
                let ext = (node.name as NSString).pathExtension.lowercased()
                let age = now - Double(node.modified)
                if path.hasPrefix(downloads + "/"), ["dmg", "pkg", "xip", "iso", "mpkg"].contains(ext) {
                    add(node, Rule(title: node.name, reason: "Installer in Downloads. Already installed it?", safe: false))
                } else if node.size >= 1_000_000_000, age > 365 * 86_400 {
                    let date = monthYear.string(from: Date(timeIntervalSince1970: Double(node.modified)))
                    add(node, Rule(title: node.name, reason: "Big and untouched since \(date).", safe: false))
                }
                return
            }
            if node.isSynthetic { return }
            if let rule = exact[path] {
                add(node, rule)
                return
            }
            if path == caches {
                for child in node.children where child.size >= 50_000_000 {
                    add(child, Rule(title: child.name, reason: "App cache. Apps quietly rebuild what they need.", safe: true))
                }
                return
            }
            if path.hasPrefix(home + "/") {
                let parentName = node.parent?.name ?? ""
                switch node.name {
                case "node_modules":
                    add(node, Rule(title: "node_modules · \(parentName)", reason: "npm packages. `npm install` brings them back.", safe: true))
                    return
                case "DerivedData":
                    add(node, Rule(title: "DerivedData · \(parentName)", reason: "Xcode build cache. Rebuilds itself.", safe: true))
                    return
                case "__pycache__":
                    add(node, Rule(title: "__pycache__ · \(parentName)", reason: "Compiled Python. Regenerated on import.", safe: true))
                    return
                case ".build" where sibling(node, named: "Package.swift"):
                    add(node, Rule(title: ".build · \(parentName)", reason: "SwiftPM build output. `swift build` recreates it.", safe: true))
                    return
                case "target" where sibling(node, named: "Cargo.toml"):
                    add(node, Rule(title: "target · \(parentName)", reason: "Rust build output. `cargo build` recreates it.", safe: true))
                    return
                case "Pods" where sibling(node, named: "Podfile"):
                    add(node, Rule(title: "Pods · \(parentName)", reason: "CocoaPods. `pod install` restores them.", safe: true))
                    return
                case ".next", ".nuxt", ".turbo", ".parcel-cache", ".angular":
                    if sibling(node, named: "package.json") {
                        add(node, Rule(title: "\(node.name) · \(parentName)", reason: "Web build cache. Rebuilt on the next dev run.", safe: true))
                        return
                    }
                case ".venv", "venv":
                    if node.children.contains(where: { $0.name == "pyvenv.cfg" }) {
                        add(node, Rule(title: "\(node.name) · \(parentName)", reason: "Python virtualenv. Recreate it from requirements.", safe: false))
                        return
                    }
                default:
                    break
                }
            }
            for child in node.children {
                visit(child, path == "/" ? "/" + child.name : path + "/" + child.name)
            }
        }

        visit(root, root.name)
        picks.sort { $0.node.size > $1.node.size }
        if picks.count > 200 { picks.removeLast(picks.count - 200) }

        var report = SmartReport(picks: picks)
        for pick in picks where pick.safe {
            report.safeBytes += pick.node.size
            var n: FileNode? = pick.node
            while let c = n {
                report.reclaimable[c.id, default: 0] += pick.node.size
                n = c.parent
            }
        }
        return report
    }
}

nonisolated struct SearchResult: Sendable {
    var query: String
    /// Topmost nodes whose name matches.
    var matches: Set<ObjectIdentifier> = []
    /// Folders that contain a match somewhere below.
    var ancestors: Set<ObjectIdentifier> = []
    var tops: [FileNode] = []
    var bytes: Int64 = 0
}

nonisolated enum SearchEngine {
    static func run(root: FileNode, query: String) -> SearchResult {
        var result = SearchResult(query: query)
        let q = query.trimmingCharacters(in: .whitespaces)
        // ".dmg" means "ends with .dmg", anything else is a plain substring.
        let suffix = q.hasPrefix(".") ? q.lowercased() : nil

        func matches(_ name: String) -> Bool {
            if let suffix { return name.lowercased().hasSuffix(suffix) }
            return name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }

        func visit(_ node: FileNode) -> Bool {
            if node.parent != nil, !node.isSynthetic, matches(node.name) {
                result.matches.insert(node.id)
                result.tops.append(node)
                result.bytes += node.size
                return true
            }
            var any = false
            for child in node.children where visit(child) { any = true }
            if any { result.ancestors.insert(node.id) }
            return any
        }

        _ = visit(root)
        result.tops.sort { $0.size > $1.size }
        return result
    }
}
