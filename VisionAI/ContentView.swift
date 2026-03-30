//
//  ContentView.swift
//  Vision AI
//
//  Created by Integrate AI on 1/13/26.
//

import SwiftUI
import AVFoundation
import Speech
import FoundationModels

enum InputMode: String, CaseIterable {
    case camera = "Camera"
    case voice = "Voice"
    case conversation = "Conversation"
}

struct ContentView: View {
    @State private var camera = CameraManager()
    @State private var vlmManager = VLMManager()
    @State private var speechAnalyzer = SpeechAnalyzerManager()
    @State private var conversationAnalyzer = ConversationAnalyzer()
    @State private var conversationResult: ConversationResult?
    @State private var description = ""
    @State private var statusMessage = ""
    @State private var isLoading = false
    @State private var bpReading: BloodPressureReading?
    @State private var vitalSigns: VitalSignsReading?
    @State private var inputMode: InputMode = .camera

    let describer = SceneDescriber()

    var body: some View {
        ZStack {
            if inputMode == .camera {
                CameraView(session: camera.session)
                    .ignoresSafeArea()
            } else {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
            }

            VStack {
                // 模型選擇器 (僅 Camera 模式顯示)
                if inputMode == .camera {
                    Picker("Model", selection: $vlmManager.selectedModel) {
                        ForEach(SupportedModel.allCases) { model in
                            Text(model.rawValue).tag(model)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .disabled(vlmManager.loadingProgress > 0 && vlmManager.loadingProgress < 1 || vlmManager.isSwitching)
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
                }
                
                // 輸入模式切換
                Picker("Input", selection: $inputMode) {
                    ForEach(InputMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                
                Spacer()

                // Camera 模式：模型載入進度
                if inputMode == .camera {
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
                }

                // 語音模式 UI
                if inputMode == .voice {
                    VStack(spacing: 16) {
                        if speechAnalyzer.isListening {
                            VStack {
                                Image(systemName: "mic.fill")
                                    .font(.largeTitle)
                                    .foregroundColor(.red)
                                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: speechAnalyzer.isListening)
                                Text("Listening...")
                                    .font(.headline)
                            }
                        } else if isLoading {
                            VStack(spacing: 8) {
                                ProgressView("Analyzing conversation...")
                                if !statusMessage.isEmpty {
                                    Text(statusMessage)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else if speechAnalyzer.transcribedText.isEmpty && vitalSigns == nil {
                            VoiceInputGuide()
                        }
                        
                        if !speechAnalyzer.transcribedText.isEmpty {
                            ScrollView {
                                Text(speechAnalyzer.transcribedText)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 120)
                            .padding()
                            .background(.ultraThinMaterial)
                            .cornerRadius(12)
                        }
                        
                        if let error = speechAnalyzer.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        Button {
                            Task {
                                if speechAnalyzer.isListening {
                                    await speechAnalyzer.stopListening()
                                    
                                    // 檢查是否有任何辨識文字
                                    let text = speechAnalyzer.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !text.isEmpty else {
                                        description = "No speech detected. Please try again."
                                        return
                                    }
                                    
                                    // 開始分析對話
                                    isLoading = true
                                    statusMessage = "Extracting vital signs..."
                                    
                                    do {
                                        let result = try await describer.parseVitalSignsFromConversation(text)
                                        vitalSigns = result
                                        bpReading = BloodPressureReading(
                                            SYS: result.SYS,
                                            DIA: result.DIA,
                                            PUL: result.PUL
                                        )
                                    } catch {
                                        // Fallback to regex only if there's actual text
                                        if let fallback = describer.parseVitalSignsFallback(text) {
                                            vitalSigns = fallback
                                            bpReading = BloodPressureReading(
                                                SYS: fallback.SYS,
                                                DIA: fallback.DIA,
                                                PUL: fallback.PUL
                                            )
                                        } else {
                                            description = "Could not parse vital signs. Try saying: 收縮壓120 舒張壓80 脈搏72"
                                        }
                                    }
                                    
                                    isLoading = false
                                    statusMessage = ""
                                } else {
                                    vitalSigns = nil
                                    bpReading = nil
                                    description = ""
                                    do {
                                        try await speechAnalyzer.startListening()
                                    } catch {
                                        description = "Failed to start speech recognition: \(error.localizedDescription)"
                                    }
                                }
                            }
                        } label: {
                            Label(speechAnalyzer.isListening ? "Stop" : "Start Voice Input", systemImage: speechAnalyzer.isListening ? "stop.fill" : "mic.fill")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(isLoading)
                    }
                    .padding()
                }
                
                // Conversation 模式 UI
                if inputMode == .conversation {
                    ConversationModeView(
                        analyzer: conversationAnalyzer,
                        result: $conversationResult
                    )
                    .padding()
                }

                // Vital Signs 顯示卡片
                if let vs = vitalSigns, hasAnyValue(vs) {
                    VitalSignsCard(vitalSigns: vs)
                        .padding()
                } else if let reading = bpReading {
                    // 血壓卡片（相機模式）
                    HStack(spacing: 30) {
                        VStack {
                            Text("SYS:")
                                .font(.headline)
                            Text("\(reading.SYS ?? 0)")
                                .font(.title)
                                .fontWeight(.bold)
                            Text("mmHg")
                                .font(.caption)
                        }
                        VStack {
                            Text("DIA:")
                                .font(.headline)
                            Text("\(reading.DIA ?? 0)")
                                .font(.title)
                                .fontWeight(.bold)
                            Text("mmHg")
                                .font(.caption)
                        }
                        VStack {
                            Text("PUL:")
                                .font(.headline)
                            Text("\(reading.PUL ?? 0)")
                                .font(.title)
                                .fontWeight(.bold)
                            Text("bpm")
                                .font(.caption)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .padding()
                } else if !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                        .padding()
                }

                // Camera 模式：讀取血壓按鈕
                if inputMode == .camera {
                    Button("Read Blood Pressure") {
                        Task {
                            await MainActor.run {
                                isLoading = true
                                statusMessage = "📸 Capturing image..."
                                bpReading = nil
                                vitalSigns = nil
                                description = ""
                            }
                            if let image = await camera.capturePhoto() {
                                await MainActor.run { statusMessage = "🧠 Analyzing with AI..." }
                                if let result = try? await describer.describeBP(image: image, vlmManager: vlmManager, onStatusUpdate: { status in
                                    Task { @MainActor in
                                        statusMessage = status
                                    }
                                }) {
                                    await MainActor.run { bpReading = result }
                                } else {
                                    await MainActor.run { description = "Unable to read blood pressure." }
                                }
                            } else {
                                await MainActor.run { description = "Failed to capture image. Please check camera permissions." }
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
        }
        .onAppear { 
            camera.startSession()
            Task { 
                do {
                    try await vlmManager.loadModel()
                } catch {
                    print("❌ 模型載入失敗：\(error)")
                    description = "模型載入失敗：\(error.localizedDescription)"
                }
                
                do {
                    try await speechAnalyzer.initialize()
                } catch {
                    print("❌ SpeechAnalyzer 初始化失敗：\(error)")
                    description = "SpeechAnalyzer 初始化失敗：\(error.localizedDescription)"
                }
            }
        }
        .onDisappear { camera.stopSession() }
    }
}

// MARK: - Vital Signs 卡片元件
struct VitalSignsCard: View {
    let vitalSigns: VitalSignsReading
    
    var body: some View {
        VStack(spacing: 16) {
            // 血壓
            if vitalSigns.SYS != nil || vitalSigns.DIA != nil || vitalSigns.PUL != nil {
                HStack(spacing: 20) {
                    if vitalSigns.SYS != nil {
                        VitalSignItem(label: "SYS", value: "\(vitalSigns.SYS!)", unit: "mmHg")
                    }
                    if vitalSigns.DIA != nil {
                        VitalSignItem(label: "DIA", value: "\(vitalSigns.DIA!)", unit: "mmHg")
                    }
                    if vitalSigns.PUL != nil {
                        VitalSignItem(label: "PUL", value: "\(vitalSigns.PUL!)", unit: "bpm")
                    }
                }
            }
            
            // 其他數值
            HStack(spacing: 20) {
                if let bs = vitalSigns.bloodSugar {
                    VitalSignItem(label: "血糖", value: "\(bs)", unit: "mg/dL", color: .orange)
                }
                if let temp = vitalSigns.temperature {
                    VitalSignItem(label: "體溫", value: String(format: "%.1f", temp), unit: "°C", color: .orange)
                }
                if let spo2 = vitalSigns.spO2 {
                    VitalSignItem(label: "血氧", value: "\(spo2)", unit: "%", color: .blue)
                }
            }
            
            // 沒有任何數值時
            if vitalSigns.SYS == nil && vitalSigns.DIA == nil && vitalSigns.PUL == nil &&
               vitalSigns.bloodSugar == nil && vitalSigns.temperature == nil && vitalSigns.spO2 == nil {
                Text("No vital signs detected")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }
}

struct VitalSignItem: View {
    let label: String
    let value: String
    let unit: String
    var color: Color = .primary
    
    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(color)
            Text(unit)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Helper Functions
func hasAnyValue(_ vs: VitalSignsReading) -> Bool {
    return vs.SYS != nil || vs.DIA != nil || vs.PUL != nil ||
           vs.bloodSugar != nil || vs.temperature != nil || vs.spO2 != nil
}

// MARK: - Voice Input Guide (使用提示)
struct VoiceInputGuide: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            
            Text("量測時自然說出數值即可")
                .font(.headline)
            Text("Say vital signs naturally")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Divider().padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 8) {
                GuideRow(text: "收縮壓 120，舒張壓 80，脈搏 72")
                GuideRow(text: "體溫 36.5，血糖 98，血氧 97")
                GuideRow(text: "SYS 120, DIA 80, PUL 72")
            }
            
            Text("支援：血壓 / 血糖 / 體溫 / 血氧")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }
}

struct GuideRow: View {
    let text: String
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.callout)
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Conversation Mode View

struct ConversationModeView: View {
    @Bindable var analyzer: ConversationAnalyzer
    @Binding var result: ConversationResult?
    
    var body: some View {
        VStack(spacing: 16) {
            if analyzer.isRecording {
                VStack {
                    Image(systemName: "mic.fill")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                        .scaleEffect(CGFloat(1.0 + Double(analyzer.audioLevel) * 2))
                        .animation(.easeInOut(duration: 0.1).repeatForever(autoreverses: true), value: analyzer.audioLevel)
                    Text("Recording conversation...")
                        .font(.headline)
                }
                
                Text("Tap Stop to analyze patient mood")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if analyzer.isProcessing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(analyzer.processingStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if let result = result {
                ConversationResultCard(result: result)
            } else {
                ConversationInputGuide()
            }
            
            if let error = analyzer.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            Button {
                Task {
                    if analyzer.isRecording {
                        await analyzer.stopRecording()
                        if let r = try? await analyzer.analyzeConversation() {
                            result = r
                        }
                    } else {
                        do {
                            try await analyzer.startRecording()
                        } catch {
                            analyzer.errorMessage = error.localizedDescription
                        }
                    }
                }
            } label: {
                Label(
                    analyzer.isRecording ? "Stop & Analyze" : "Start Recording",
                    systemImage: analyzer.isRecording ? "stop.fill" : "mic.fill"
                )
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(analyzer.isProcessing)
        }
    }
}

// MARK: - Conversation Input Guide

struct ConversationInputGuide: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            
            Text("Record Conversation")
                .font(.headline)
            Text("Talk naturally with patient")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Divider().padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 8) {
                GuideRow(text: "Records full conversation")
                GuideRow(text: "Identifies patient vs nurse")
                GuideRow(text: "Analyzes patient mood")
                GuideRow(text: "Extracts vital signs")
            }
            
            Text("Supports: Blood pressure / Blood sugar / Temperature / SpO2")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }
}

// MARK: - Conversation Result Card

struct ConversationResultCard: View {
    let result: ConversationResult
    
    var body: some View {
        VStack(spacing: 12) {
            // 患者心情
            if let mood = result.patientMood {
                HStack(spacing: 12) {
                    Image(systemName: moodIcon(for: mood))
                        .font(.title)
                        .foregroundColor(moodColor(for: mood))
                    VStack(alignment: .leading) {
                        Text("Patient Mood")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Text(mood)
                                .font(.headline)
                            if let confidence = result.moodConfidence, confidence > 0 {
                                Text("\(Int(confidence * 100))%")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    Spacer()
                }
                .padding()
                .background(moodColor(for: mood).opacity(0.1))
                .cornerRadius(12)
            }
            
            // 生命徵象
            if let vs = result.vitalSigns, hasAnyValue(vs) {
                VitalSignsCard(vitalSigns: vs)
            }
            
            // 對話紀錄
            if !result.fullTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcript")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ScrollView {
                        Text(result.fullTranscript)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(12)
            }
            
            // 錯誤訊息
            if let error = result.moodReasoning, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private func moodIcon(for mood: String) -> String {
        switch mood {
        case "平穩": return "face.smiling"
        case "開心": return "face.smiling.inverse"
        case "焦慮": return "face.smiling"
        case "疲倦": return "zzz"
        case "不安": return "exclamationmark.triangle"
        case "積極": return "hand.thumbsup"
        case "混亂": return "questionmark.circle"
        case "煩躁": return "xmark.circle"
        default: return "person.fill"
        }
    }
    
    private func moodColor(for mood: String) -> Color {
        switch mood {
        case "平穩", "開心", "積極": return .green
        case "焦慮", "不安", "混亂": return .orange
        case "疲倦": return .blue
        case "煩躁": return .red
        default: return .secondary
        }
    }
}
