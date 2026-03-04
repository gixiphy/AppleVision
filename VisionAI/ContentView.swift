//
//  ContentView.swift
//  Vision AI
//
//  Created by Integrate AI on 1/13/26.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @StateObject private var vlmManager = VLMManager()
    @State private var description = ""
    @State private var isLoading = false

    let describer = SceneDescriber()

    var body: some View {
        ZStack {
            CameraView(session: camera.session)
                .ignoresSafeArea()

            VStack {
                Spacer()

                if isLoading {
                    ProgressView("Analyzing…")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                } else if !vlmManager.isModelLoaded {
                    ProgressView("Loading VLM Model...")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }

                Text(description)
                    .font(.callout)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .padding()

                Button("Read Blood Pressure") {
                    Task {
                        isLoading = true
                        if let image = await camera.capturePhoto() {
//                            description = (try? await describer.describe(image: image))
//                                ?? "Unable to describe scene."
                            description = (try? await describer.describeBP(image: image, vlmManager: vlmManager))
                                ?? "Unable to read blood pressure."
                        }
                        isLoading = false
                    }
                }
                .disabled(!vlmManager.isModelLoaded)
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.bottom, 40)
            }
        }
        .onAppear { 
            camera.session.startRunning() 
            Task { try? await vlmManager.loadModel() }
        }
        .onDisappear { camera.session.stopRunning() }
    }
}
