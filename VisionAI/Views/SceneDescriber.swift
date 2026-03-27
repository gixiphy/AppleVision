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
        You are an expert at reading 7-segment LCD displays on blood pressure monitors.

        Display layout (top to bottom):
        - Date/Time row: SMALLEST digits at very top, contains "-" or ":" or "/". IGNORE this row completely.
        - SYS: LARGEST digits, typically 60-250 (ALWAYS 2-3 digits).
        - DIA: medium-sized digits, typically 30-150 (ALWAYS 2-3 digits).
        - PUL: smallest digits at bottom, typically 40-200 (ALWAYS 2-3 digits).

        CRITICAL: The top-most tiny numbers are ALWAYS date/time. NEVER read them as blood pressure readings.

        IMPORTANT: Blood pressure values are ALWAYS 2-3 digits. If you see only 1 digit, you are reading the WRONG area - the display shows 2-3 digits. Check the LARGER digits below the date/time row.

        Step by step:
        1. Locate and SKIP the date/time row at the very top (small numbers with "-" or ":").
        2. Read the LARGE digits below as SYS (2-3 digits).
        3. Read the medium digits as DIA (2-3 digits).
        4. Read the small digits at bottom as PUL (2-3 digits).
        5. Be careful with similar digits: 3/8/9, 7/1/4, 0/6/8.

        Output ONLY valid JSON (no additional text):
        {"SYS": integer, "DIA": integer, "PUL": integer}

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
        var reading = try decoder.decode(BloodPressureReading.self, from: data)
        
        // 結果驗證：範圍檢查（與 voice mode 一致）
        reading.SYS = validateRange(reading.SYS, min: 60, max: 250)
        reading.DIA = validateRange(reading.DIA, min: 30, max: 150)
        reading.PUL = validateRange(reading.PUL, min: 40, max: 200)
        
        // 如果所有值都不合理，拋出錯誤
        if reading.SYS == nil && reading.DIA == nil && reading.PUL == nil {
            throw NSError(domain: "SceneDescriber", code: 2, userInfo: [NSLocalizedDescriptionKey: "無法讀取有效的血壓數值"])
        }
        
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
    func parseBPFromText(_ text: String) -> BloodPressureReading? {
        let pattern = #"-?\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        
        let numbers = matches.compactMap { match -> Int? in
            guard let range = Range(match.range, in: text) else { return nil }
            return Int(text[range])
        }
        
        guard numbers.count >= 3 else { return nil }
        
        let sys = numbers[0]
        let dia = numbers[1]
        let pul = numbers[2]
        
        guard (60...250).contains(sys) else { return nil }
        guard (30...150).contains(dia) else { return nil }
        guard (40...200).contains(pul) else { return nil }
        
        return BloodPressureReading(SYS: sys, DIA: dia, PUL: pul)
    }
    
    // MARK: - 語音對話 Vital Signs 提取（FoundationModels）
    func parseVitalSignsFromConversation(_ text: String) async throws -> VitalSignsReading {
        let session = LanguageModelSession(model: model)
        
        let prompt = """
        You are a medical data extraction assistant. Your PRIMARY goal is ACCURACY.
        
        CRITICAL RULES:
        1. ONLY extract values that are EXPLICITLY stated in the conversation
        2. If you cannot find a value with HIGH CONFIDENCE, return null for that field
        3. NEVER guess or infer values that were not spoken
        4. A missed reading is better than a hallucinated reading
        
        The conversation may be in Chinese or English. Look for these EXACT value types:
        - SYS / 收縮壓 / systolic: integer 60-250 mmHg
        - DIA / 舒張壓 / diastolic: integer 30-150 mmHg
        - PUL / 脈搏 / pulse / 心跳: integer 40-200 bpm
        - 血糖 / blood sugar / glucose: integer 40-500 mg/dL
        - 體溫 / temperature: decimal 35.0-42.0 Celsius
        - 血氧 / SpO2: integer 70-100 percent
        
        If a number appears in the conversation but is NOT clearly a medical reading 
        (e.g., date, time, age, room number, phone number), IGNORE it.
        
        Example of CORRECT behavior:
        - Input: "阿婆，今天血壓120/80，很正常" → Output: SYS:120, DIA:80, others:null
        - Input: "阿婆精神不錯" → Output: all null (no readings mentioned)
        
        Conversation to analyze:
        \(text)
        """
        
        let response = try await session.respond(to: prompt, generating: VitalSignsReading.self)
        var result = response.content
        
        // 後處理：驗證數值範圍，丟棄不合理的数据（防幻覺）
        result.SYS = validateRange(result.SYS, min: 60, max: 250)
        result.DIA = validateRange(result.DIA, min: 30, max: 150)
        result.PUL = validateRange(result.PUL, min: 40, max: 200)
        result.bloodSugar = validateRange(result.bloodSugar, min: 40, max: 500)
        result.spO2 = validateRange(result.spO2, min: 70, max: 100)
        if let temp = result.temperature {
            if !(35.0...42.0).contains(temp) {
                result.temperature = nil
            }
        }
        
        return result
    }
    
    private func validateRange(_ value: Int?, min: Int, max: Int) -> Int? {
        guard let v = value else { return nil }
        return (min...max).contains(v) ? v : nil
    }
    
    // MARK: - Regex Fallback（當 FoundationModels 不可用時）
    func parseVitalSignsFallback(_ text: String) -> VitalSignsReading? {
        let pattern = #"-?\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        
        let numbers = matches.compactMap { match -> Int? in
            guard let range = Range(match.range, in: text) else { return nil }
            return Int(text[range])
        }
        
        guard !numbers.isEmpty else { return nil }
        
        var result = VitalSignsReading(
            SYS: nil, DIA: nil, PUL: nil,
            bloodSugar: nil, temperature: nil, spO2: nil
        )
        
        // 智能分配數字到正確的類別（防止幻覺）
        for num in numbers {
            // 依序檢查每個類別的合理範圍
            if result.SYS == nil && (60...250).contains(num) {
                result.SYS = num
            } else if result.DIA == nil && (30...150).contains(num) {
                result.DIA = num
            } else if result.PUL == nil && (40...200).contains(num) {
                result.PUL = num
            } else if result.bloodSugar == nil && (40...500).contains(num) {
                result.bloodSugar = num
            } else if result.spO2 == nil && (70...100).contains(num) {
                result.spO2 = num
            } else if result.temperature == nil && (350...420).contains(num) {
                // 體溫可能是 36.5 (365 in raw) 或 36 (360)
                result.temperature = Double(num) / 10.0
            }
        }
        
        return result
    }
}

// MARK: - 結構化回應（直接對應到你的 VitalSigns）
struct BloodPressureReading: Codable {
    var SYS: Int?      // 通常是 SYS（較大值）
    var DIA: Int?      // 通常是 DIA
    var PUL: Int?      // 通常是 PUL
}
@Generable
struct VitalSignsReading: Codable {
    @Guide(description: "Systolic blood pressure in mmHg, typically 60-250")
    var SYS: Int?
    
    @Guide(description: "Diastolic blood pressure in mmHg, typically 30-150")
    var DIA: Int?
    
    @Guide(description: "Pulse rate in bpm, typically 40-200")
    var PUL: Int?
    
    @Guide(description: "Blood glucose in mg/dL, typically 40-500")
    var bloodSugar: Int?
    
    @Guide(description: "Body temperature in Celsius, typically 35.0-42.0")
    var temperature: Double?
    
    @Guide(description: "Blood oxygen saturation SpO2 percentage, typically 70-100")
    var spO2: Int?
}

