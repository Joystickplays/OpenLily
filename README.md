# OpenLily

An open-source disk space visualizer for macOS, in the spirit of DaisyDisk, drawn as a lily.

Every folder is a ring segment sized by what it holds on disk. Folders nest outward, and wherever a branch ends it curves into a petal tip.

![OpenLily showing Xcode's Platforms folder as a lily, with a hover card, the In view sidebar and one item in the Compost](docs/screenshot.png)

## What it does

- **Fast parallel scan.** Uses `getattrlistbulk(2)` on a pool of worker threads. Counts allocated blocks (like `du`) and counts hard links once. Scanning `/` follows the APFS firmlinks into the Data volume without counting anything twice. Space the volume reports as used but the scan couldn't see shows up as **Hidden space**.
- **Zoom & pan, not just drill-down.** Pinch, ⌘-scroll or mouse wheel to zoom around the cursor. Two-finger scroll or drag empty space to pan. Deeper rings fade in as you zoom, and each ring is thinner than the one inside it, so the lily never runs out of room.
- **No hairlines.** Anything too thin to read on screen is folded into one soft "+N smaller items" petal at the end of its folder. Hover it to see what's inside; click it to zoom in or open the folder.
- **Click to open a folder.** The ring re-blooms around it. Click the center (or press Esc) to go back up, or use the breadcrumbs.
- **"In view" sidebar.** Lists what is actually on screen for the current zoom and pan. If only one folder is in view, it lists that folder's contents instead.
- **Smart picks.** Flags space you can safely get back and says why: Xcode DerivedData and DeviceSupport, `node_modules`, SwiftPM `.build`, Cargo `target`, Pods, app caches, package-manager caches and the Trash. Things that need a look first are flagged separately: old installers in Downloads, big files untouched for a year, simulators, device backups, Docker. "Compost everything that rebuilds itself" bins all the safe picks in one click.
- **Color by Folder, Kind or Age.**
- **Find.** Type to dim everything except matches; `.dmg` matches by extension. Then "Compost all" the results.
- **Compost.** Drag petals from the ring or rows from the sidebar into the bin. They wilt in place (dashed outline) until you press **Let them fall**: a 3‑2‑1 countdown you can cancel, then the petals burst off the ring and the ring closes over the gap. Items go to the **Trash**, and Undo puts them back. Undo needs Full Disk Access; without it, use Put Back in Finder.
- Quick Look (space), Reveal in Finder, right-click menus, ⌘F, ⌘R rescan, ⌘O scan a folder, dark mode, and Liquid Glass controls.

## Building

Open `OpenLily.xcodeproj` in Xcode 27 and run. Targets macOS 27.

The app is **not sandboxed**, because a disk scanner has to see the whole disk. For a complete scan, grant it Full Disk Access in System Settings → Privacy & Security; the start screen links there. Without it, macOS hides Mail, Messages, Safari data and similar folders.

Dev shortcut: set `OPENLILY_SCAN=/some/path` to skip the start screen and scan that path straight away. In Xcode, add it under Product → Scheme → Edit Scheme → Run → Environment Variables. From the command line:

```bash
xcodebuild -scheme OpenLily -derivedDataPath build/DerivedData build
open --env OPENLILY_SCAN=$HOME/Projects build/DerivedData/Build/Products/Debug/OpenLily.app
```

## Layout

| File | What's in it |
| --- | --- |
| `Scanner.swift` | Parallel `getattrlistbulk` walker and bottom-up totals |
| `FileNode.swift` | Tree node and file-kind table |
| `Smart.swift` | Smart-pick rules and search |
| `Ring.swift` | Lily geometry, camera, color painter |
| `RingCanvas.swift` | Canvas renderer with animated focus and wilt transitions |
| `RingInteraction.swift` | AppKit layer for trackpad, mouse and keys |
| `AppModel.swift` | App state: scanning, navigation, compost, trash and undo |
| `RingStage.swift`, `Sidebar.swift`, `Compost.swift`, `StartView.swift`, `ScanningView.swift` | Views |

## License

MIT. See [LICENSE](LICENSE).
