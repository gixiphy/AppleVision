//
//  MoodAnalyzer.swift
//  Vision AI
//
//  Mood analysis placeholder for on-device LLM (Qwen3)
//  TODO: MLX Swift integration requires more debugging
//

import Foundation

struct PatientMoodResult: Codable {
    var mood: String
    var confidence: Double
    var reasoning: String?
}

@Observable
@MainActor
final class MoodAnalyzer {
    
    var isLoading: Bool = false
    var isModelLoaded: Bool = false
    var loadingProgress: Double = 0.0
    var errorMessage: String?
    
    func loadModel() async throws {
        isModelLoaded = true
    }
    
    func analyzeMood(from conversation: String) async throws -> PatientMoodResult {
        return PatientMoodResult(
            mood: "未知",
            confidence: 0.0,
            reasoning: "MLX integration pending"
        )
    }
}
