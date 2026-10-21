//
//  OpenLilyApp.swift
//  OpenLily
//
//  Created by zabruh on 21/10/26.
//

import SwiftUI

@main
struct OpenLilyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r")
                    .disabled(model.scanURL == nil)
                Button("Scan Something Else") { model.backToStart() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Lily") {
                Button("Zoom In") { model.zoomStep(1) }
                    .keyboardShortcut("=")
                Button("Zoom Out") { model.zoomStep(-1) }
                    .keyboardShortcut("-")
                Button("Actual Size") { model.resetCamera() }
                    .keyboardShortcut("0")
                Button("Up One Level") { model.goUp() }
                    .keyboardShortcut(.upArrow)
                Divider()
                ForEach(ColorMode.allCases) { mode in
                    Button("Color by \(mode.rawValue)") { model.colorMode = mode }
                }
                Divider()
                Button("Let Them Fall") { model.letThemFall() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.compost.isEmpty)
            }
        }
    }
}
