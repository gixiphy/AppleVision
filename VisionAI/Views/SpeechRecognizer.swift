//
//  SpeechRecognizer.swift
//  Vision AI
//
//  Created by Integrate AI on 3/27/26.
//

import Foundation
import Speech
import AVFoundation

@Observable
@MainActor
final class SpeechRecognizer {
    var transcribedText = ""
    var isListening = false
    var errorMessage: String?
    
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    
    init() {
        speechRecognizer = SFSpeechRecognizer()  // 自動偵測語言
        audioEngine = AVAudioEngine()
    }
    
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    
    func startListening() async throws {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Speech recognizer not available"
            return
        }
        
        let authorized = await requestAuthorization()
        guard authorized else {
            errorMessage = "Speech recognition permission denied"
            return
        }
        
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        
        guard let audioEngine = audioEngine else {
            errorMessage = "Audio engine not available"
            return
        }
        
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        
        if #available(iOS 16, *) {
            request.addsPunctuation = true
        }
        
        recognitionRequest = request
        transcribedText = ""
        isListening = true
        errorMessage = nil
        
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                self.transcribedText = result.bestTranscription.formattedString
            }
            
            if error != nil || result?.isFinal == true {
                self.isListening = false
            }
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
    }
    
    func stopListening() {
        recognitionRequest?.endAudio()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        
        if let task = recognitionTask {
            task.finish()
        }
        
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
        
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    func extractNumbers() -> [Int] {
        let pattern = #"-?\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        
        let range = NSRange(transcribedText.startIndex..., in: transcribedText)
        let matches = regex.matches(in: transcribedText, options: [], range: range)
        
        return matches.compactMap { match in
            guard let range = Range(match.range, in: transcribedText) else { return nil }
            return Int(transcribedText[range])
        }
    }
}
