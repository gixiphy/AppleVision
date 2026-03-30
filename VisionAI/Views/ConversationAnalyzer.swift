//
//  ConversationAnalyzer.swift
//  Vision AI
//
//  Records nurse-patient conversation, transcribes, and analyzes patient mood
//  Uses SFSpeechRecognizer for transcription + FoundationModels for mood analysis
//  TODO: Add speech-swift Sortformer for speaker diarization
//

import Foundation
import AVFoundation
import Speech
import FoundationModels

struct DiarizedSegment: Codable, Identifiable {
    var id = UUID()
    var speakerId: Int
    var label: String
    var startTime: Double
    var endTime: Double
    var text: String
}

struct ConversationResult: Codable {
    var fullTranscript: String
    var segments: [DiarizedSegment]
    var patientSegments: [DiarizedSegment]
    var patientMood: String?
    var moodConfidence: Double?
    var moodReasoning: String?
    var vitalSigns: VitalSignsReading?
}

@Observable
@MainActor
final class ConversationAnalyzer {
    
    var isRecording: Bool = false
    var isProcessing: Bool = false
    var result: ConversationResult?
    var processingStatus: String = ""
    var errorMessage: String?
    var audioLevel: Float = 0.0
    
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [AVAudioPCMBuffer] = []
    private var audioFormat: AVAudioFormat?
    private var recordingStartTime: Date?
    
    private let sceneDescriber = SceneDescriber()
    
    // MARK: - Recording
    
    func startRecording() async throws {
        guard !isRecording else { return }
        
        let authorized = await requestPermissions()
        guard authorized else {
            throw ConversationAnalyzerError.permissionDenied
        }
        
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            throw ConversationAnalyzerError.audioEngineError
        }
        
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        audioFormat = format
        
        audioBuffer.removeAll()
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            Task { @MainActor in
                self?.audioBuffer.append(buffer)
                
                let channelData = buffer.floatChannelData?[0]
                let frameLength = Int(buffer.frameLength)
                if frameLength > 0 {
                    var sum: Float = 0
                    for i in 0..<frameLength {
                        sum += abs(channelData?[i] ?? 0)
                    }
                    self?.audioLevel = sum / Float(frameLength)
                }
            }
        }
        
        try audioEngine.start()
        recordingStartTime = Date()
        isRecording = true
        result = nil
        errorMessage = nil
    }
    
    func stopRecording() async {
        guard isRecording else { return }
        
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioLevel = 0
        
        isRecording = false
    }
    
    // MARK: - Analysis
    
    func analyzeConversation() async throws -> ConversationResult {
        isProcessing = true
        processingStatus = "Processing audio..."
        errorMessage = nil
        
        defer { isProcessing = false }
        
        processingStatus = "Transcribing conversation..."
        
        guard let audioBuffer = combineAudioBuffer(), !audioBuffer.isEmpty else {
            throw ConversationAnalyzerError.noAudioData
        }
        
        let transcription = try await transcribeAudio(buffer: audioBuffer)
        
        processingStatus = "Analyzing patient speech..."
        
        let patientAnalysis = try await analyzePatientContent(transcription)
        
        processingStatus = "Extracting vital signs..."
        var vitalSigns: VitalSignsReading?
        do {
            vitalSigns = try await sceneDescriber.parseVitalSignsFromConversation(patientAnalysis.patientText)
        } catch {
            print("Vital signs extraction failed: \(error)")
        }
        
        processingStatus = "Analyzing patient mood..."
        
        let moodResult = try await analyzeMood(
            fullTranscript: transcription,
            patientText: patientAnalysis.patientText,
            nurseText: patientAnalysis.nurseText
        )
        
        let result = ConversationResult(
            fullTranscript: transcription,
            segments: patientAnalysis.allSegments,
            patientSegments: patientAnalysis.patientSegments,
            patientMood: moodResult.mood,
            moodConfidence: moodResult.confidence,
            moodReasoning: moodResult.reasoning,
            vitalSigns: vitalSigns
        )
        
        self.result = result
        processingStatus = ""
        
        return result
    }
    
    // MARK: - Private Methods
    
    private func requestPermissions() async -> Bool {
        let micStatus = await AVAudioApplication.requestRecordPermission()
        guard micStatus else { return false }
        
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    
    private func combineAudioBuffer() -> [AVAudioPCMBuffer]? {
        return audioBuffer.isEmpty ? nil : audioBuffer
    }
    
    private func transcribeAudio(buffer: [AVAudioPCMBuffer]) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW")),
              recognizer.isAvailable else {
            throw ConversationAnalyzerError.speechRecognizerUnavailable
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let audioURL = tempDir.appendingPathComponent("recording_\(UUID().uuidString).wav")
        
        guard let format = audioFormat else {
            throw ConversationAnalyzerError.audioEngineError
        }
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        
        guard let audioFile = try? AVAudioFile(forWriting: audioURL, settings: settings) else {
            throw ConversationAnalyzerError.audioFileError
        }
        
        for buf in buffer {
            try audioFile.write(from: buf)
        }
        
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }
        
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let result = result, result.isFinal else { return }
                
                let transcription = result.bestTranscription.formattedString
                continuation.resume(returning: transcription)
            }
        }
    }
    
    private struct PatientAnalysis {
        var allSegments: [DiarizedSegment]
        var patientSegments: [DiarizedSegment]
        var patientText: String
        var nurseText: String
    }
    
    private func analyzePatientContent(_ transcription: String) async throws -> PatientAnalysis {
        let prompt = """
        以下是護士與患者的對話紀錄。請分析對話內容，區分哪些是護士說的話，哪些是患者說的話。

        對話內容：
        \(transcription)

        請以 JSON 格式輸出，嚴格遵守以下格式：
        {
            "allSegments": [
                {"speakerId": 0, "label": "護士"或"患者", "text": "說的話"}
            ],
            "patientText": "患者說的所有話合併成的文字",
            "nurseText": "護士說的所有話合併成的文字"
        }

        判斷規則：
        1. 護士通常會解釋量測過程、問候患者、給指示
        2. 患者通常會回應症狀、表達感受、回答問題
        3. 如果無法判斷，預設為患者
        """
        
        let analysisText = try await callFoundationModel(prompt: prompt)
        
        return parsePatientAnalysis(analysisText, fullText: transcription)
    }
    
    private func parsePatientAnalysis(_ jsonText: String, fullText: String) -> PatientAnalysis {
        let cleanJson = jsonText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        struct AnalysisResponse: Codable {
            var allSegments: [Segment]
            var patientText: String
            var nurseText: String
            
            struct Segment: Codable {
                var speakerId: Int
                var label: String
                var text: String
            }
        }
        
        if let data = cleanJson.data(using: .utf8),
           let response = try? JSONDecoder().decode(AnalysisResponse.self, from: data) {
            
            let segments = response.allSegments.map { s in
                DiarizedSegment(
                    speakerId: s.speakerId,
                    label: s.label,
                    startTime: 0,
                    endTime: 0,
                    text: s.text
                )
            }
            
            let patientSegments = segments.filter { $0.label == "患者" }
            
            return PatientAnalysis(
                allSegments: segments,
                patientSegments: patientSegments,
                patientText: response.patientText,
                nurseText: response.nurseText
            )
        }
        
        return PatientAnalysis(
            allSegments: [DiarizedSegment(speakerId: 0, label: "患者", startTime: 0, endTime: 0, text: fullText)],
            patientSegments: [DiarizedSegment(speakerId: 0, label: "患者", startTime: 0, endTime: 0, text: fullText)],
            patientText: fullText,
            nurseText: ""
        )
    }
    
    private struct MoodAnalysisResult {
        var mood: String
        var confidence: Double
        var reasoning: String?
    }
    
    private func analyzeMood(fullTranscript: String, patientText: String, nurseText: String) async throws -> MoodAnalysisResult {
        let moodLabels = ["平穩", "開心", "焦慮", "疲倦", "不安", "積極", "混亂", "煩躁"]
        
        let prompt = """
        你是一個醫療情緒分析助手。請分析以下患者說的話，判斷患者的心情狀態。

        請從以下選項中選擇一個最準確的心情標籤：
        \(moodLabels.joined(separator: "、"))

        完整對話：
        \(fullTranscript)

        患者說的話：
        \(patientText)

        輸出格式（嚴格遵守，只輸出 JSON）：
        {"mood": "心情標籤", "confidence": 0.0-1.0, "reasoning": "簡短原因（最多20字）"}

        重要規則：
        1. 只根據「患者說的話」來判斷心情
        2. 如果對話中沒有患者說的話，mood 設為 "未知"，confidence 設為 0.0
        3. reasoning 是簡短的判斷原因
        """
        
        let resultText = try await callFoundationModel(prompt: prompt)
        
        return parseMoodResult(resultText)
    }
    
    private func parseMoodResult(_ text: String) -> MoodAnalysisResult {
        let moodLabels = ["平穩", "開心", "焦慮", "疲倦", "不安", "積極", "混亂", "煩躁"]
        
        let cleanText = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        struct MoodResponse: Codable {
            var mood: String
            var confidence: Double
            var reasoning: String?
        }
        
        if let data = cleanText.data(using: .utf8),
           let response = try? JSONDecoder().decode(MoodResponse.self, from: data) {
            return MoodAnalysisResult(
                mood: response.mood,
                confidence: response.confidence,
                reasoning: response.reasoning
            )
        }
        
        for label in moodLabels {
            if cleanText.contains(label) {
                return MoodAnalysisResult(mood: label, confidence: 0.5, reasoning: "Text match")
            }
        }
        
        return MoodAnalysisResult(mood: "未知", confidence: 0.0, reasoning: "Parse failed")
    }
    
    private func callFoundationModel(prompt: String) async throws -> String {
        return "{\"mood\": \"平穩\", \"confidence\": 0.5, \"reasoning\": \"Placeholder\"}"
    }
}

// MARK: - Error Types

enum ConversationAnalyzerError: LocalizedError {
    case permissionDenied
    case audioEngineError
    case audioFileError
    case speechRecognizerUnavailable
    case noAudioData
    case analysisFailed
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone or speech recognition permission denied"
        case .audioEngineError:
            return "Audio engine error"
        case .audioFileError:
            return "Failed to create audio file"
        case .speechRecognizerUnavailable:
            return "Speech recognizer unavailable"
        case .noAudioData:
            return "No audio data recorded"
        case .analysisFailed:
            return "Analysis failed"
        }
    }
}
