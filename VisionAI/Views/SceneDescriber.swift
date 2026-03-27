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

        The display layout from top to bottom is:
        1. DATE/TIME row (SMALLEST digits at the very top) — e.g. "1-05", "21:05", "12/31". This row often contains a dash "-", colon ":", or slash "/". IGNORE THIS ROW COMPLETELY.
        2. SYS row (LARGEST digits) — systolic blood pressure, typically 60–250.
        3. DIA row (medium digits) — diastolic blood pressure, typically 30–150.
        4. PUL row (smaller digits, near bottom) — pulse/heart rate, typically 40–200, often with "/min" or a heart icon.

        CRITICAL: The top-most small numbers are ALWAYS date/time, NOT blood pressure. Do NOT read them as SYS. SYS is the LARGE number below the date/time row.

        Think step-by-step:
        1. First, locate and SKIP the date/time row at the very top (smallest text, may have "-" or ":").
        2. Identify the three BP reading areas below it: SYS (largest), DIA (medium), PUL (smallest).
        3. For each digit, carefully check which of the 7 segments are lit.
        4. Be extra careful with similar shapes: 3/8/9/6/5, 7/1/4, 0/8/6/9.
        5. Ignore all icons, battery, AFIB, MAM, error symbols, cuffs, etc.

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
