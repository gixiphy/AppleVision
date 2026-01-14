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
        print("Scene description requested with observations: \(summary)")
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
            .prefix(5)
            .map { $0.identifier } ?? []
    }
}
