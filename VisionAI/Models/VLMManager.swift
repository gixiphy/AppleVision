import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import UIKit
import Combine

/// 負責管理 MLX 視覺語言模型 (VLM) 的生命週期與推論
@MainActor
final class VLMManager: ObservableObject {
    
    @Published var isModelLoaded = false
    @Published var loadingProgress: Double = 0.0
    
    private var modelContainer: ModelContainer?
    
    // 定義我們要使用的模型：Qwen2.5-VL 3B (最新的 OCR 強力模型)
    private let modelConfiguration = VLMRegistry.qwen2_5VL3BInstruct4Bit
    
    init() {
        // 提高快取上限，加速連續推論時的記憶體分配速度 (256MB)
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
    }
    
    /// 下載並載入模型到記憶體中
    func loadModel() async throws {
        guard !isModelLoaded else { return }
        
        print("開始載入 模型：\(modelConfiguration.name)...")
        
        // 透過 Hub 下載並初始化模型。這步驟在第一次執行時會需要下載約 1.5GB 的檔案
        let container = try await VLMModelFactory.shared.loadContainer(
            configuration: modelConfiguration
        ) { progress in
            print("載入中 模型：\(progress)")
            // 處理 URLSession 潛在的 Edge Cases (例如 totalUnitCount 為未知狀態 -1，或下載量超標)
            let total = progress.totalUnitCount
            var fraction = 0.0
            
            if total > 0 {
                fraction = min(max(progress.fractionCompleted, 0.0), 1.0)
            }
            
            let capturedFraction = fraction
            
            Task { @MainActor in
                // 如果 total <= 0，可以暫時鎖在一個安全的值或是 0
                self.loadingProgress = capturedFraction
            }
        }
        
        self.modelContainer = container
        self.isModelLoaded = true
        print("✅ 模型載入完成！")
    }
    
    /// 傳入圖片與提示詞進行多模態推論
    func generate(image: UIImage, prompt: String) async throws -> String {
        guard let container = modelContainer else {
            throw NSError(domain: "VLMManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "模型尚未載入"])
        }
        
        // 1. 影像預處理：調整大小、轉灰階並增加對比度，以利 OCR。
        // 將最大尺寸降至 1024px，兼顧文字清晰度與推論速度
        let maxDimension: CGFloat = 1024.0
        let size = image.size
        var resizedImage = image
        
        // Resize
        if size.width > maxDimension || size.height > maxDimension {
            let ratio = min(maxDimension / size.width, maxDimension / size.height)
            let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
            
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            if let scaledImage = UIGraphicsGetImageFromCurrentImageContext() {
                resizedImage = scaledImage
            }
            UIGraphicsEndImageContext()
        }
        
        // 轉為灰階以增強對比 (過濾掉背景顏色干擾)
        if let currentCGImage = resizedImage.cgImage {
            let colorSpace = CGColorSpaceCreateDeviceGray()
            let width = currentCGImage.width
            let height = currentCGImage.height
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                context.interpolationQuality = .high
                context.draw(currentCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                if let grayCGImage = context.makeImage() {
                    resizedImage = UIImage(cgImage: grayCGImage)
                    print("📸 Image converted to grayscale for better OCR")
                }
            }
        }
        
        // 改用 JPEG 0.9 壓縮，減少磁碟 I/O 耗時，且對於灰階文字幾乎無失真
        guard let imageData = resizedImage.jpegData(compressionQuality: 0.9) else {
            throw NSError(domain: "VLMManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "無法轉換圖片格式"])
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try imageData.write(to: tempURL)
        
        // 確保結束後刪除暫存檔
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        // 2. 建立推論輸入
        let chat = [
            Chat.Message(
                role: .user,
                content: prompt,
                images: [.url(tempURL)]
            )
        ]
        
        // 移除圖片尺寸限制，讓模型能看到原始高解析度圖片，這對於精確 OCR 非常關鍵
        let userInput = UserInput(
            chat: chat
        )
                
        print("🧠 開始 VLM 推論...")
        
        // 3. 執行推論
        let result = try await container.perform { context in
            // 將圖片與文字轉換為張量 (Tensor)
            let lmInput = try await context.processor.prepare(input: userInput)
            
            // 設定生成參數 (降低 maxTokens 到 100，因為 JSON 只有約 30 tokens)
            let parameters = GenerateParameters(
                maxTokens: 100,
                temperature: 0.0 // 設為 0.0 確保 OCR 與數值讀取的穩定性（不具隨機性）
            )
            
            // 開始串流生成
            let stream = try MLXLMCommon.generate(
                input: lmInput,
                parameters: parameters,
                context: context
            )
            
            var text = ""
            for await item in stream {
                switch item {
                case .chunk(let chunkText):
                    text += chunkText
                case .info(let info):
                    print("✅ 推論完成。速度: \(String(format: "%.2f", info.tokensPerSecond)) tokens/sec")
                default:
                    break
                }
            }
            return text
        }
        
        return result
    }
}
