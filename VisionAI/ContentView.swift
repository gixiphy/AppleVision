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
    @State private var statusMessage = ""
    @State private var isLoading = false

    let describer = SceneDescriber()

    var body: some View {
        ZStack {
            CameraView(session: camera.session)
                .ignoresSafeArea()

            VStack {
                // 模型選擇器 (置頂)
                Picker("Model", selection: $vlmManager.selectedModel) {
                    ForEach(SupportedModel.allCases) { model in
                        Text(model.rawValue).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(12)
                .disabled(vlmManager.loadingProgress > 0 && vlmManager.loadingProgress < 1)
                .onChange(of: vlmManager.selectedModel) { oldValue, newValue in
                    Task {
                        do {
                            try await vlmManager.switchModel(to: newValue)
                        } catch {
                            print("❌ 模型載入失敗：\(error)")
                            description = "模型載入失敗：\(error.localizedDescription)"
                        }
                    }
                }
                
                Spacer()

                if isLoading {
                    VStack(spacing: 8) {
                        ProgressView("Analyzing…")
                        if !statusMessage.isEmpty {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                } else if !vlmManager.isModelLoaded {
                    VStack {
                        ProgressView("Loading \(vlmManager.selectedModel.rawValue)...")
                        ProgressView(value: vlmManager.loadingProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 200)
                            .padding(.top, 4)
                        Text("\(Int(vlmManager.loadingProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                }

                if !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                        .padding()
                }

                Button("Read Blood Pressure") {
                    Task {
                        await MainActor.run {
                            isLoading = true
                            statusMessage = "📸 Capturing image..."
                            description = ""
                        }
                        if let image = await camera.capturePhoto() {
                            await MainActor.run { statusMessage = "🧠 Analyzing with AI..." }
                            let result = (try? await describer.describeBP(image: image, vlmManager: vlmManager, onStatusUpdate: { status in
                                Task { @MainActor in
                                    statusMessage = status
                                }
                            })) ?? "Unable to read blood pressure."
                            await MainActor.run { description = result }
                        }
                        await MainActor.run {
                            statusMessage = ""
                            isLoading = false
                        }
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
            Task { 
                do {
                    try await vlmManager.loadModel()
                } catch {
                    print("❌ 模型載入失敗：\(error)")
                    // 如果發生錯誤，顯示在 UI 上，避免無限轉圈圈
                    description = "模型載入失敗：\(error.localizedDescription)"
                }
            }
        }
        .onDisappear { camera.session.stopRunning() }
    }
}
