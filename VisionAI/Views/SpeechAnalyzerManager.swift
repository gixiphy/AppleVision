//
//  SpeechAnalyzerManager.swift
//  Vision AI
//
//  SpeechAnalyzer + VoiceAnalytics for iOS 26+
//

import Foundation
import Speech
import AVFoundation
import CoreMedia
import Observation

// MARK: - Speech Analyzer Manager
@Observable
@MainActor
final class SpeechAnalyzerManager {
    
    // MARK: - Public Output
    var transcribedText: String = ""
    var isListening: Bool = false
    var isInitialized: Bool = false
    var errorMessage: String?
    
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
        errorMessage = nil
        
        // 啟動結果監聽 Task
        Task {
            do {
                for try await result in transcriber.results {
                    // 取得轉錄文字
                    let text = String(result.text.characters)
                    
                    // 更新文字
                    self.transcribedText = text
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
