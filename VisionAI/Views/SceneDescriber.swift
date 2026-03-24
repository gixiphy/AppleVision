//
//  SceneDescriber.swift
//  Vision AI
//
//  Created by Integrate AI on 1/13/26.
//


import Foundation
import Vision
import UIKit
import FoundationModels

@MainActor
final class SceneDescriber {

    private let model = SystemLanguageModel.default

    func describe(image: UIImage) async throws -> String {
        let observations = try await analyze(image: image)
        let summary = observations.joined(separator: ", ")
        print("Scene description requested with observations:\n\(summary)\n")
        let prompt = """
        You are an on-device vision assistant.

        Describe only what is directly visible in the image.
        Use plain, literal language.
        Do not use metaphors, symbolism, or imaginative descriptions.
        Do not speculate or interpret meaning.

        Only describe non-sensitive, physical objects and environmental features.
        Do not describe people, faces, screens, text, or personal information.

        Visible objects and features: \(summary)

        Write 2–3 simple sentences using factual, concrete terms only about the visbile objects and features.
        """

        let session = LanguageModelSession(model: model)
        let response = try await session.respond(to: prompt)
        return response.content
    }

    private func analyze(image: UIImage) async throws -> [String] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)

        try handler.perform([request])

        return request.results?
            .map { $0.identifier } ?? []
    }
    
    // MARK: - 血壓計專用（已優化）
    func describeBP(image: UIImage, vlmManager: VLMManager, onStatusUpdate: (@Sendable (String) -> Void)? = nil) async throws -> BloodPressureReading {
        onStatusUpdate?("📐 Resizing image...")
        
        let prompt = """
        You are an expert at reading 7-segment LCD/LED displays from blood pressure monitors.

        The image shows a typical digital blood pressure meter display.
        Focus ONLY on the three main 7-segment numeric readings:
        - Upper/SYS (systolic, usually larger or top number)
        - Lower/DIA (diastolic)
        - Bottom/PUL or Pulse/Heart rate (usually smallest or with /min or bpm symbol)

        Think step-by-step:
        1. Identify the three separate numeric areas.
        2. For each digit, carefully check which of the 7 segments are lit.
        3. Be extra careful with similar shapes:
           - 3 vs 8 vs 9 vs 6 vs 5
           - 7 vs 1 vs 4
           - 0 vs 8 vs 6 vs 9
        4. Ignore any other text, icons, battery, date, AFIB, MAM, error symbols, cuffs, etc.
        5. If a digit is unclear or partial, use the most likely shape.

        Output ONLY valid JSON, nothing else:
        {"SYS": integer or null, "DIA": integer or null, "PUL": integer or null}
        Use null if cannot confidently read a value.
        """
        
        onStatusUpdate?("🤖 Running AI inference...")
        let response = try await vlmManager.generate(image: image, prompt: prompt, onStatusUpdate: onStatusUpdate)
        
        print("🤖 VLM raw response: \(response)")
        
        var cleanResponse = response
        if let jsonStart = cleanResponse.firstIndex(of: "{"),
           let jsonEnd = cleanResponse.lastIndex(of: "}") {
            cleanResponse = String(cleanResponse[jsonStart...jsonEnd])
        }
        
        guard let data = cleanResponse.data(using: .utf8) else {
            throw NSError(domain: "SceneDescriber", code: 1, userInfo: [NSLocalizedDescriptionKey: "無法解析 JSON"])
        }
        
        let decoder = JSONDecoder()
        let reading = try decoder.decode(BloodPressureReading.self, from: data)
        
        return reading
    }
    
    // MARK: - 純 OCR（保留你原本最穩定的設定）
    private func analyzeBP(image: UIImage) async throws -> [String] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.02
        request.customWords = ["SYS", "DIA", "PUL", "mmHg", "SYS mmHg", "DIA mmHg", "PUL/min", "AFIB", "MAM"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        return observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }
    }
}

// MARK: - 結構化回應（直接對應到你的 VitalSigns）
struct BloodPressureReading: Codable {
    var SYS: Int?      // 通常是 SYS（較大值）
    var DIA: Int?      // 通常是 DIA
    var PUL: Int?      // 通常是 PUL
}
