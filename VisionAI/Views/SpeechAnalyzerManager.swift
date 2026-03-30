//
//  SpeechAnalyzerManager.swift
//  Vision AI
//
//  SpeechAnalyzer + VoiceAnalytics for iOS 26+
//  預留 SRSpeechExpression 接口
//

import Foundation
import Speech
import AVFoundation
import CoreMedia
import Observation

// MARK: - VoiceAnalytics 情緒結果
struct VoiceEmotionResult: Codable {
    var overallMood: String
    var energy: String
    var stability: String
    var confidence: Double
    
    var rawPitch: Double?
    var rawJitter: Double?
    var rawShimmer: Double?
}

// MARK: - SRSpeechExpression 結果（預留 - 僅供技術驗證）
// ⚠️ 需要 Apple 研究用途授權，無法上架 App Store
struct SpeechExpressionResult: Codable {
    var valence: Double?
    var activation: Double?
    var dominance: Double?
    var mood: Double?
    var confidence: Double?
}

// MARK: - Speech Analyzer Manager
@Observable
@MainActor
final class SpeechAnalyzerManager {
    
    // MARK: - Public Output
    var transcribedText: String = ""
    var isListening: Bool = false
    var isInitialized: Bool = false
    var errorMessage: String?
    var voiceEmotionResult: VoiceEmotionResult?
    // var speechExpressionResult: SpeechExpressionResult?  // 預留接口
    
    // MARK: - Private Components
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioEngine: AVAudioEngine?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var targetAudioFormat: AVAudioFormat?  // SpeechAnalyzer 要求的 Int16 格式
    
    // MARK: - 初始化
    func initialize() async throws {
        guard !isInitialized else { return }
        
        if #available(iOS 26, *) {
            try await initializeiOS26()
        } else {
            throw SpeechAnalyzerError.unsupportedLocale
        }
    }
    
    @available(iOS 26, *)
    private func initializeiOS26() async throws {
        // 1. 檢查 SpeechTranscriber 是否可用
        guard SpeechTranscriber.isAvailable else {
            throw SpeechAnalyzerError.unsupportedLocale
        }
        
        // 2. 建立 SpeechTranscriber（使用 progressive 预设用于实时语音）
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            throw SpeechAnalyzerError.unsupportedLocale
        }
        
        let transcriberInstance = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        transcriber = transcriberInstance
        
        // 3. 檢查並下載資產
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriberInstance]) {
            try await request.downloadAndInstall()
        }
        
        // 4. 取得 SpeechAnalyzer 支援的最佳音訊格式（Int16）
        guard let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriberInstance]) else {
            throw SpeechAnalyzerError.initializationFailed
        }
        targetAudioFormat = bestFormat
        
        // 5. 建立 SpeechAnalyzer
        let analyzerInstance = SpeechAnalyzer(modules: [transcriberInstance])
        analyzer = analyzerInstance
        
        // 6. 設定 Audio Engine
        audioEngine = AVAudioEngine()
        
        isInitialized = true
    }
    
    // MARK: - 請求權限
    func requestAuthorization() async -> Bool {
        // 請求麥克風權限
        let micStatus = await AVAudioApplication.requestRecordPermission()
        guard micStatus else {
            errorMessage = "Microphone permission denied"
            return false
        }
        
        // 請求語音辨識權限
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    
    // MARK: - 開始錄音
    func startListening() async throws {
        guard let analyzer = analyzer,
              let transcriber = transcriber,
              let audioEngine = audioEngine else {
            throw SpeechAnalyzerError.notInitialized
        }
        
        // 請求權限
        let authorized = await requestAuthorization()
        guard authorized else {
            throw SpeechAnalyzerError.authorizationDenied
        }
        
        // 設定 Audio Session
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        
        // 建立 AsyncStream（音訊輸入）
        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputBuilder = inputBuilder
        
        // 重置狀態
        transcribedText = ""
        voiceEmotionResult = nil
        errorMessage = nil
        
        // 啟動結果監聽 Task
        Task {
            do {
                for try await result in transcriber.results {
                    // 取得轉錄文字
                    let text = String(result.text.characters)
                    
                    // 更新文字
                    self.transcribedText = text
                    
                    // MARK: - VoiceAnalytics 情緒分析（預留）
                    // SpeechTranscriber.Result 可能需要配置特定選項才能取得 voice analytics
                    // 這裡預留接口，未來可以通過 result.metadata 取得
                    // if let metadata = result.metadata {
                    //     for segment in metadata {
                    //         if let voiceAnalytics = segment.voiceAnalytics {
                    //             // 分析情緒
                    //         }
                    //     }
                    // }
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
        
        // 啟動 Analyzer
        try await analyzer.start(inputSequence: inputSequence)
        
        // 從 AVAudioEngine 餵入音訊（需轉換 Float32 → Int16）
        let inputNode = audioEngine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        
        guard let targetFormat = targetAudioFormat else {
            throw SpeechAnalyzerError.initializationFailed
        }
        
        // 建立格式轉換器：麥克風 Float32 → SpeechAnalyzer Int16
        guard let converter = AVAudioConverter(from: micFormat, to: targetFormat) else {
            throw SpeechAnalyzerError.audioEngineError
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            // 計算目標 buffer 的 frame 容量
            let ratio = targetFormat.sampleRate / micFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCapacity
            ) else { return }
            
            // 執行格式轉換
            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            guard status != .error, error == nil else { return }
            
            let input = AnalyzerInput(buffer: convertedBuffer)
            self.inputBuilder?.yield(input)
        }
        
        try audioEngine.start()
        isListening = true
    }
    
    // MARK: - 停止錄音
    func stopListening() async {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        inputBuilder?.finish()
        inputBuilder = nil
        
        if let analyzer = analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        
        isListening = false
    }
    
    // MARK: - VoiceAnalytics 情緒分析實現（預留方法）
    // 未來可以從 SpeechTranscriber.Result 的 metadata 中取得 voice analytics
    private func analyzeVoiceEmotion(
        pitch: Double,
        jitter: Double,
        shimmer: Double,
        voicing: Double
    ) -> VoiceEmotionResult {
        // 閾值（需根據實際數據調整）
        let jitterThreshold: Double = 0.03   // 3%
        let shimmerThreshold: Double = 0.5   // 0.5 dB
        
        // 判斷能量（基於 jitter）
        let energy: String
        if jitter > jitterThreshold * 1.5 {
            energy = "high"
        } else if jitter < jitterThreshold * 0.5 {
            energy = "low"
        } else {
            energy = "normal"
        }
        
        // 判斷穩定性（基於 shimmer）
        let stability: String
        if shimmer > shimmerThreshold * 1.5 {
            stability = "unstable"
        } else if shimmer < shimmerThreshold * 0.5 {
            stability = "stable"
        } else {
            stability = "moderate"
        }
        
        // 判斷整體情緒
        let overallMood: String
        if jitter > jitterThreshold * 2 && shimmer > shimmerThreshold * 2 {
            overallMood = "焦慮"
        } else if energy == "low" && stability == "stable" {
            overallMood = "平靜"
        } else if energy == "low" {
            overallMood = "疲倦"
        } else if stability == "unstable" {
            overallMood = "不安"
        } else if voicing > 0.8 && energy == "high" {
            overallMood = "積極"
        } else {
            overallMood = "正常"
        }
        
        // 計算置信度（基於數據完整性）
        let confidence: Double
        if voicing > 0.5 && jitter >= 0 && shimmer >= 0 {
            confidence = 0.8
        } else {
            confidence = 0.5
        }
        
        return VoiceEmotionResult(
            overallMood: overallMood,
            energy: energy,
            stability: stability,
            confidence: confidence,
            rawPitch: pitch,
            rawJitter: jitter,
            rawShimmer: shimmer
        )
    }
    
    // MARK: - SRSpeechExpression 接口（僅供技術驗證 / Technical Testing Only）
    // ================================================================================
    // ⚠️ 重要提醒 / IMPORTANT:
    // - SRSpeechExpression 來自 SensorKit 框架
    // - 使用需要 Apple 研究用途授權 (com.apple.developer.sensorkit.reader.allow)
    // - 僅供技術驗證 (Technical Verification) 使用
    // - 無法上架 App Store (會被拒絕)
    //
    // 使用方式 / Usage:
    // 1. 需要向 Apple 提交研究計劃並獲得批准
    // 2. 在 entitlements 中新增 com.apple.developer.sensorkit.reader.allow
    // 3. 從 SRSpeechMetrics 取得 speechExpression
    //
    // @available(iOS 26, *)
    // func analyzeSpeechExpression(_ expression: SRSpeechExpression) -> SpeechExpressionResult {
    //     return SpeechExpressionResult(
    //         valence: expression.valence,
    //         activation: expression.activation,
    //         dominance: expression.dominance,
    //         mood: expression.mood,
    //         confidence: expression.confidence
    //     )
    // }
    // ================================================================================
}

// MARK: - 錯誤類型
enum SpeechAnalyzerError: LocalizedError {
    case notInitialized
    case unsupportedLocale
    case authorizationDenied
    case audioEngineError
    case initializationFailed
    
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "SpeechAnalyzer not initialized"
        case .unsupportedLocale:
            return "Unsupported locale for speech recognition"
        case .authorizationDenied:
            return "Speech recognition authorization denied"
        case .audioEngineError:
            return "Audio engine error"
        case .initializationFailed:
            return "Failed to initialize SpeechAnalyzer"
        }
    }
}
