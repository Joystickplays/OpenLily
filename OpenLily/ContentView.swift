//
//  ContentView.swift
//  OpenLily
//
//  Created by zabruh on 21/10/26.
//

import SwiftUI
import QuickLook

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            Theme.paper

            switch model.phase {
            case .start:
                StartView()
                    .transition(.opacity)
            case .scanning:
                ScanningView()
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case .ready:
                MainView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .ignoresSafeArea()
        .quickLookPreview($model.quickLookURL)
    }
}

private struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            RingStage()
            Sidebar()
                .frame(width: 420)
        }
        .overlay { ParticleLayer() }
        .overlay { DragGhost() }
        .overlay { CountdownOverlay() }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
        .frame(width: 1440, height: 900)
}
