import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import UIKit
import os.log

private let logger = Logger(subsystem: "com.integrateai.VisionAI", category: "VLMManager")

enum SupportedModel: String, CaseIterable, Identifiable {
    case qwen2VL2B = "Qwen2-VL-2B"      //  iPhone 15 Pro Max 分析結果 可用
    case qwen25VL3B = "Qwen2.5-VL-3B"   //  iPhone 15 Pro Max 分析結果 不行
    case qwen3VL4B = "Qwen3-VL-4B"      //  iPhone 15 Pro Max 不行使用
    case gemma3_4B = "Gemma3-4B"        //  iPhone 15 Pro Max 不行使用
    
    var id: String { self.rawValue }
    
    var configuration: ModelConfiguration {
        switch self {
        case .qwen2VL2B:
            return VLMRegistry.qwen2VL2BInstruct4Bit
        case .qwen25VL3B:
            return VLMRegistry.qwen2_5VL3BInstruct4Bit
        case .qwen3VL4B:
            return VLMRegistry.qwen3VL4BInstruct4Bit
        case .gemma3_4B:
            return VLMRegistry.gemma3_4B_qat_4bit
        }
    }
    
    /// 根據模型大小回傳建議的 MLX 快取上限（bytes）
    /// 較大模型需要保留更多可用記憶體給權重，因此快取要縮小
    var recommendedCacheLimit: Int {
        switch self {
        case .qwen2VL2B:
            return 512 * 1024 * 1024   // 512 MB — 小模型，可多快取
        case .qwen25VL3B:
            return 256 * 1024 * 1024   // 256 MB
        case .qwen3VL4B:
            return 128 * 1024 * 1024   // 128 MB 
        case .gemma3_4B:
            return 128 * 1024 * 1024   // 128 MB — 最大模型，快取最小化
        }
    }
}

@Observable
@MainActor
final class VLMManager {
    
    var isModelLoaded = false
    var loadingProgress: Double = 0.0
    var selectedModel: SupportedModel = .qwen2VL2B
    var isSwitching = false
    
    private var modelContainer: ModelContainer?
    /// 記錄目前已載入的模型，用於切換時比對
    private var loadedModel: SupportedModel?
    /// 記憶體壓力監控
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    
    init() {
        // 使用保守的初始快取上限，載入模型時會根據模型大小動態調整
        MLX.Memory.cacheLimit = 256 * 1024 * 1024
        
        setupMemoryPressureMonitoring()
        logMemoryUsage(label: "App 啟動")
    }
    
    // MARK: - 記憶體監控
    
    /// 監聽系統記憶體壓力通知，在收到警告時主動清除 MLX 快取
    private func setupMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler {
            let event = source.data
            if event.contains(.critical) {
                logger.warning("⚠️ 系統記憶體壓力：critical — 立即清除所有快取")
            } else if event.contains(.warning) {
                logger.warning("⚠️ 系統記憶體壓力：warning — 清除快取")
            }
            Memory.clearCache()
        }
        source.resume()
        self.memoryPressureSource = source
    }
    
    /// 印出目前記憶體使用量（供除錯用）
    private func logMemoryUsage(label: String) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let usedMB = Double(info.resident_size) / 1024 / 1024
            let mlxCacheMB = Double(MLX.Memory.cacheLimit) / 1024 / 1024
            logger.info("📊 [\(label)] 記憶體使用：\(String(format: "%.1f", usedMB)) MB, MLX cache limit：\(String(format: "%.0f", mlxCacheMB)) MB")
        }
    }
    
    /// 完全釋放模型資源
    func unloadModel() async {
        self.modelContainer = nil
        self.loadedModel = nil
        self.isModelLoaded = false
        
        // 清除所有 MLX Metal buffer 快取
        Memory.clearCache()
        
        // 將快取上限暫時壓到最低，讓系統有最大空間回收
        MLX.Memory.cacheLimit = 0
        
        logMemoryUsage(label: "模型卸載後")
        
        // 等待記憶體回收（加長等待時間確保大模型釋放完整）
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    
    /// 切換模型並重新載入
    func switchModel(to model: SupportedModel) async throws {
        guard !isSwitching else { return }
        
        // 檢查是否真的需要切換：比對新模型與目前已載入的模型是否一致
        if isModelLoaded, loadedModel == model {
            self.selectedModel = model
            return
        }
        
        isSwitching = true
        defer { isSwitching = false }
        
        print("🔄 切換模型：\(selectedModel.rawValue) → \(model.rawValue)")
        
        self.loadingProgress = 0.0
        
        // 先完全釋放舊模型
        await unloadModel()
        
        self.selectedModel = model
        
        try await loadModel()
    }
    
    /// 下載並載入模型到記憶體中
    func loadModel() async throws {
        guard !isModelLoaded else { return }
        
        let configuration = selectedModel.configuration
        logger.info("開始載入模型：\(configuration.name)...")
        logMemoryUsage(label: "模型載入前")
        
        // 載入前先清除快取，確保最大可用記憶體
        Memory.clearCache()
        
        // 根據模型大小設定適當的快取上限
        MLX.Memory.cacheLimit = selectedModel.recommendedCacheLimit
        let cacheLimitMB = selectedModel.recommendedCacheLimit / 1024 / 1024
        let modelName = selectedModel.rawValue
        logger.info("MLX cache limit 已設為 \(cacheLimitMB) MB（模型：\(modelName)）")
        
        // 透過 Hub 下載並初始化模型。這步驟在第一次執行時會需要下載大檔案
        let container = try await VLMModelFactory.shared.loadContainer(
            configuration: configuration
        ) { progress in
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
        self.loadedModel = selectedModel
        self.isModelLoaded = true
        
        let loadedName = selectedModel.rawValue
        logMemoryUsage(label: "模型載入完成（\(loadedName)）")
        logger.info("✅ 模型載入完成：\(loadedName)")
    }
    
    /// 傳入圖片與提示詞進行多模態推論
    func generate(image: UIImage, prompt: String, onStatusUpdate: (@Sendable (String) -> Void)? = nil) async throws -> String {
        guard let container = modelContainer else {
            throw NSError(domain: "VLMManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "模型尚未載入"])
        }
        
        onStatusUpdate?("📐 Resizing image...")
        
        // 1. 影像預處理：調整大小、增加對比度，以利 OCR。
        // 將最大尺寸提升至 768px，提升 LCD 數字辨識度
        let maxDimension: CGFloat = 768.0
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
        
        // 增加對比度以強化 LCD 數字與背景的區分度
        if let ciImage = CIImage(image: resizedImage) {
            let filter = CIFilter(name: "CIColorControls")
            filter?.setValue(ciImage, forKey: kCIInputImageKey)
            filter?.setValue(1.2, forKey: kCIInputContrastKey)  // 對比度 +20%
            if let outputImage = filter?.outputImage {
                let context = CIContext()
                if let cgImage = context.createCGImage(outputImage, from: outputImage.extent) {
                    resizedImage = UIImage(cgImage: cgImage)
                }
            }
        }
        
        onStatusUpdate?("🖼️ Converting to grayscale...")
        
        // 轉為灰階以增強對比 (過濾掉背景顏色干擾)
//        if let currentCGImage = resizedImage.cgImage {
//            let colorSpace = CGColorSpaceCreateDeviceGray()
//            let width = currentCGImage.width
//            let height = currentCGImage.height
//            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
//                context.interpolationQuality = .high
//                context.draw(currentCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))
//                if let grayCGImage = context.makeImage() {
//                    resizedImage = UIImage(cgImage: grayCGImage)
//                    print("📸 Image converted to grayscale for better OCR")
//                }
//            }
//        }
        
//        onStatusUpdate?("💾 Preparing image data...")
        
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
                
        onStatusUpdate?("🧠 Running AI inference...")
        
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
                    onStatusUpdate?("⚡ Speed: \(String(format: "%.1f", info.tokensPerSecond)) tokens/s")
                default:
                    break
                }
            }
            return text
        }
        
        onStatusUpdate?("✅ Analysis complete!")
        
        // 推論完成後清除臨時快取，釋放推論過程中的中間張量記憶體
        Memory.clearCache()
        logMemoryUsage(label: "推論完成後")
        
        return result
    }
}
