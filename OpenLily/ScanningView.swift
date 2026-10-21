//
//  ScanningView.swift
//  OpenLily
//

import SwiftUI

struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.progress
        let fraction: Double? = model.scanVolume.map { min(0.99, Double(p.bytes) / Double(max(1, $0.used))) }

        VStack(spacing: 26) {
            ZStack {
                LilyMark(progress: fraction ?? 0.6, spinning: true)
                    .frame(width: 360, height: 360)
                    .animation(.smooth, value: fraction)
                if let fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.serif(24, .semibold, italic: true))
                        .foregroundStyle(Theme.paper)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: Int(fraction * 100))
                }
            }

            VStack(spacing: 8) {
                Text("Counting petals in \(model.scanTitle)…")
                    .font(.serif(30, .semibold, italic: true))
                Text("\(p.files.formatted()) files · \(p.directories.formatted()) folders · \(Bytes.string(p.bytes))")
                    .font(.mono(12))
                    .foregroundStyle(Theme.inkSoft)
                    .contentTransition(.numericText())
                Text(p.current.isEmpty ? " " : p.current)
                    .font(.mono(11))
                    .foregroundStyle(Theme.inkSoft.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
            }

            Button("Stop") { model.cancelScan() }
                .buttonStyle(.glass)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
    }
}
