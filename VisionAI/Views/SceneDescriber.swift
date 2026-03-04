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
    func describeBP(image: UIImage, vlmManager: VLMManager) async throws -> String {
        let prompt = """
        You are an expert OCR system specialized in reading 7-segment LCD displays on medical devices.
        Look closely at the screen of the blood pressure monitor in the image.

        CRITICAL INSTRUCTIONS:
        1. The numbers are written in a 7-segment digital font. Pay close attention to the shape of 3, 6, 8, and 9.
        2. DO NOT guess, infer, or round numbers.
        3. Extract the top large number as SYS.
        4. Extract the middle large number as DIA.
        5. Extract the bottom small number as PUL.
        
        Before outputting the final JSON, think step-by-step internally:
        - What are the individual digits visible in the top row?
        - What are the individual digits visible in the middle row?
        - What are the individual digits visible in the bottom row?
        
        Then, output ONLY a valid JSON object matching this schema. Do not include your internal thinking in the output, only the JSON.
        {
          "SYS": number,
          "DIA": number,
          "PUL": number
        }
        """
        
        let response = try await vlmManager.generate(image: image, prompt: prompt)
        
        print("🤖 VLM raw response: \(response)")
        
        // 嘗試清理模型可能產生的多餘 markdown 標籤或思考過程
        var cleanResponse = response
        if let jsonStart = cleanResponse.firstIndex(of: "{"),
           let jsonEnd = cleanResponse.lastIndex(of: "}") {
            cleanResponse = String(cleanResponse[jsonStart...jsonEnd])
        }
        
        return cleanResponse
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
    var large1: Int?      // 通常是 SYS（較大值）
    var large2: Int?      // 通常是 DIA
    var small: Int?       // 通常是 PUL
    var units: String?
    var description: String = ""
}
