# OCR 技術架構說明文件

## 概述

VisionAI 應用程式實現了一套雙軌 OCR 系統，用於讀取血壓計 LCD 七段顯示器的數值。系統自動擷取三個關鍵生命徵象：SYS（收縮壓）、DIA（舒張壓）和 PUL（脈搏）。

### 核心目標

- **主要目標**：自動讀取血壓計 LCD 數值
- **精確度要求**：在各種光照條件下精確讀取 2-3 位數字
- **可靠性**：備援機制確保在不同裝置效能下都能正常運作
- **效能最佳化**：針對行動裝置有限的記憶體和運算資源進行優化

---

## 系統架構

```
┌─────────────────────────────────────────────────────────────────────┐
│                         相機擷取                                    │
│              (UIImage 來自相機或相片庫)                                │
└─────────────────────────────────┬─────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    影像預處理                                        │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
│  │ 1. 調整大小     │  │ 2. 對比度增強   │  │ 3. JPEG         │     │
│  │    (最大 768px) │  │    (+20%)       │  │    壓縮         │     │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘     │
└─────────────────────────────────┬─────────────────────────────────────┘
                                  │
          ┌───────────────────────┴───────────────────────┐
          ▼                                               ▼
┌─────────────────────────────┐             ┌─────────────────────────────┐
│       VLM OCR 路徑          │             │    Vision OCR 路徑         │
│      (主要策略)              │             │    (備援)                  │
├─────────────────────────────┤             ├─────────────────────────────┤
│ • Qwen2-VL-2B 模型         │             │ • VNRecognizeTextRequest   │
│ • Chain-of-Thought Prompt  │             │ • 高精確度辨識              │
│ • JSON 輸出解析             │             │ • Regex 擷取               │
└──────────────┬──────────────┘             └──────────────┬──────────────┘
               │                                           │
               ▼                                           ▼
        ┌────────────────────────┐                ┌────────────────────────┐
        │     範圍驗證            │                │     範圍驗證           │
        │ SYS: 60-250            │                │ SYS: 60-250            │
        │ DIA: 30-150           │                │ DIA: 30-150            │
        │ PUL: 40-200           │                │ PUL: 40-200            │
        └───────────┬────────────┘                └───────────┬────────────┘
                    │                                           │
                    └───────────────────┬───────────────────────┘
                                        ▼
                        ┌─────────────────────────────────┐
                        │      BloodPressureReading       │
                        │      { SYS, DIA, PUL }         │
                        └─────────────────────────────────┘
```

---

## 元件分析

### 1. VLMManager (`VLMManager.swift`)

VLMManager 是負責視覺語言模型操作的核心協調元件。

#### 模型選取

| 模型 | 快取上限 | 目標裝置 | 狀態 |
|------|---------|---------|------|
| `qwen2VL2B` | 512 MB | iPhone 15 Pro Max | ✅ 支援 |
| `qwen25VL3B` | 256 MB | - | ❌ 不支援 |
| `qwen3VL4B` | 128 MB | - | ❌ 不支援 |
| `gemma3_4B` | 128 MB | - | ❌ 不支援 |

#### 主要職責

- **模型載入**：透過 `VLMModelFactory` 下載並初始化 VLM 模型
- **記憶體管理**：根據模型大小動態調整快取上限
- **推論執行**：協調完整的推論管線
- **資源清理**：正確卸載模型並清除快取

#### 記憶體管理策略

```swift
// 初始保守的快取上限
MLX.Memory.cacheLimit = 256 * 1024 * 1024 // 256 MB

// 根據模型大小調整
MLX.Memory.cacheLimit = selectedModel.recommendedCacheLimit

// 記憶體壓力時清除快取
Memory.clearCache()
```

系統透過 `DispatchSource.makeMemoryPressureSource` 監控記憶體壓力，當系統發出警告時自動清除快取。

#### 支援的模型

**Qwen2-VL-2B** 是目前唯一穩定運作的模型，採用 4-bit 量化：
- 參數數量：约 2B
- 量化方式：Q4_0 (4-bit)
- 快取需求：512 MB
- 適用場景：血壓計 LCD 數值辨識

---

### 2. SceneDescriber (`SceneDescriber.swift`)

SceneDescriber 負責 OCR 處理和生命徵象擷取，採用多重備援機制。

#### 血壓 OCR 方法

`describeBP()` 方法實作了基於 VLM 的主要 OCR 策略：

```swift
func describeBP(image: UIImage, vlmManager: VLMManager, onStatusUpdate: (@Sendable (String) -> Void)? = nil) async throws -> BloodPressureReading
```

**Prompt 設計策略**：

```
顯示器排列（由上而下）：
- 日期/時間列：最頂端的最微小數字，包含 "-" 或 ":" 或 "/"。完全忽略此列。
- SYS：最大的數字，通常 60-250（永遠是 2-3 位數）。
- DIA：中等大小的數字，通常 30-150（永遠是 2-3 位數）。
- PUL：底部最小的數字，通常 40-200（永遠是 2-3 位數）。
```

此明確指示防止模型將日期/時間數字誤讀為血壓值——這是 LCD 顯示器辨識的關鍵失敗點。

#### 備援 OCR 方法

1. **Vision Framework OCR** (`analyzeBP()`)：
   - 使用 `VNRecognizeTextRequest`
   - 高精確度模式，啟用語言校正
   - 自訂詞彙表：`["SYS", "DIA", "PUL", "mmHg", "mmHg", "PUL/min", "AFIB", "MAM"]`

2. **Regex 擷取** (`parseBPFromText()`)：
   - 從文字中擷取所有數值模式
   - 根據生理範圍驗證每個數字
   - 回傳第一個有效匹配作為 `BloodPressureReading`

3. **對話擷取** (`parseVitalSignsFromConversation()`)：
   - 使用 FoundationModels 的 `SystemLanguageModel`
   - 從語音轉錄文字中擷取
   - 支援中文和英文輸入

---

## 影像預處理管線

預處理管線專為七段 LCD 顯示器辨識進行優化。

### 步驟 1：調整大小（最大邊緣 768px）

```swift
let maxDimension: CGFloat = 768.0
// 維持寬高比，同時限制最大邊緣
```

**設計理由**：平衡細節保留與記憶體效率。768px 閾值是經驗性確定的，提供足夠的解析度進行數字辨識，同時保持在行動裝置的限制內。

### 步驟 2：對比度增強

```swift
let filter = CIFilter(name: "CIColorControls")
filter?.setValue(1.2, forKey: kCIInputContrastKey)  // +20% 對比度
```

**設計理由**：增加 LCD 數字與背景之間的區分度。這對於在各種光照條件下區分照明片段與黑暗背景至關重要。

### 步驟 3：灰階轉換（可選）

目前已註釋，但可用：

```swift
// 轉為灰階以過濾顏色干擾
```

**設計理由**：移除可能干擾數字辨識的顏色資訊，特別是在 LCD 顯示器有彩色元素或環境光照造成色偏時很有用。

### 步驟 4：JPEG 壓縮

```swift
guard let imageData = resizedImage.jpegData(compressionQuality: 0.9) else { ... }
```

**設計理由**：JPEG 0.9 在檔案大小減少和視覺品質保留之間提供了出色的平衡。對於文字/數值內容，壓縮失真最小，同時顯著減少了 I/O 開銷。

---

## 推論設定

### 生成參數

```swift
let parameters = GenerateParameters(
    maxTokens: 100,      // JSON 輸出約需 30 tokens
    temperature: 0.0    // 確定性輸出
)
```

### 關鍵參數：Temperature

**為什麼設為 0.0？**

對於 OCR 和數值讀取任務，不可接受非確定性輸出：

1. **一致性**：相同圖片應產生相同輸出
2. **精確度**：隨機波動可能導致數字誤分類（例如 3↔8、7↔1）
3. **JSON 有效性**：Temperature > 0 可能導致格式不良的 JSON 輸出

### Chain-of-Thought (CoT) Prompting

Prompt 明確指示模型遵循逐步處理流程：

```
逐步執行：
1. 找到並跳過最頂端的日期/時間列（帶有 "-" 或 ":" 的小數字）。
2. 讀取下方的大數字作為 SYS（2-3 位數）。
3. 讀取中等大小的數字作為 DIA（2-3 位數）。
4. 讀取底部的小數字作為 PUL（2-3 位數）。
5. 小心相似的數字：3/8/9、7/1/4、0/6/8。
```

此方法利用模型的推理能力，同時對輸出強制執行結構約束。

---

## 資料流程

### 主要路徑：VLM OCR

```
1. 使用者擷取圖片（相機/相片）
       │
       ▼
2. VLMManager.generate()
       │
       ▼
3. 影像預處理
    (調整大小 → 對比度 → 壓縮)
       │
       ▼
4. 準備 UserInput（包含 prompt + 圖片）
       │
       ▼
5. MLXLMCommon.generate()
       │
       ▼
6. 流式回應處理
       │
       ▼
7. 從回應中擷取 JSON
       │
       ▼
8. 範圍驗證
       │
       ▼
9. 回傳 BloodPressureReading
```

### 備援路徑：Vision OCR

```
1. 使用者擷取圖片
       │
       ▼
2. 執行 VNRecognizeTextRequest
       │
       ▼
3. 擷取文字候選項
       │
       ▼
4. Regex 模式匹配
       │
       ▼
5. 範圍驗證
       │
       ▼
6. 回傳 BloodPressureReading（或 nil）
```

---

## 生命徵象範圍驗證

所有擷取的值都會經過嚴格的範圍驗證，以防止 AI 幻覺：

| 生命徵象 | 範圍 | 單位 |
|----------|------|------|
| SYS | 60-250 | mmHg |
| DIA | 30-150 | mmHg |
| PUL | 40-200 | bpm |
| 血糖 | 40-500 | mg/dL |
| 血氧 | 70-100 | % |
| 體溫 | 35.0-42.0 | °C |

超出這些生理範圍的值將被丟棄並視為無效。

---

## 錯誤處理策略

### 錯誤階層

```
┌────────────────────────────────────────────────┐
│              模型未載入                         │
│         (模型容器未初始化)                       │
└────────────────────────────────────────────────┘
                      │
                      ▼
┌────────────────────────────────────────────────┐
│              影像轉換失敗                       │
│         (無法將 UIImage 轉換為 CGImage)          │
└────────────────────────────────────────────────┘
                      │
                      ▼
┌────────────────────────────────────────────────┐
│              JSON 解析失敗                     │
│         (回應不是有效的 JSON)                   │
└────────────────────────────────────────────────┘
                      │
                      ▼
┌────────────────────────────────────────────────┐
│              範圍驗證失敗                       │
│         (所有擷取的值都超出範圍)                 │
└────────────────────────────────────────────────┘
```

### 復原機制

1. **JSON 解析失敗** → 嘗試 Regex 擷取
2. **Regex 無匹配** → 回傳 nil，提示使用者重新拍攝
3. **記憶體壓力** → 卸載模型，回退到 Vision OCR
4. **所有 OCR 方法失敗** → 提示手動輸入

---

## 效能最佳化

### 記憶體最佳化

- **動態快取上限**：根據模型大小調整 MLX 快取
- **暫存檔清理**：延遲刪除暫存圖片檔案
- **推論快取清除**：生成後清除中間張量
- **記憶體壓力響應**：系統警告時自動清除快取

### 延遲最佳化

- **影像調整大小**：限制在 768px 以減少張量準備時間
- **JPEG 壓縮**：相較於 PNG 減少 I/O 時間
- **流式回應**：隨到達處理 tokens
- **最小 Max Tokens**：JSON 輸出 100 tokens（實際約需 30 tokens）

### 模型載入最佳化

- **漸進式載入**：向使用者顯示下載進度
- **智慧切換**：相同模型選取時跳過重新載入
- **完整卸載**：確保載入新模型前有可用記憶體

---

## 檔案結構

```
VisionAI/
├── Models/
│   └── VLMManager.swift          # VLM 協調、模型載入、推論
├── Views/
│   └── SceneDescriber.swift      # OCR 執行、解析、驗證
│   └── CameraView.swift          # 圖片擷取介面
├── App/
│   └── Vision_AIApp.swift        # 應用程式入口
└── Supporting/
    └── Info.plist                # 權限、配置
```

---

## API 參考

### VLMManager

```swift
@Observable
@MainActor
final class VLMManager {
    var isModelLoaded: Bool           // 模型是否已載入
    var loadingProgress: Double      // 載入進度 (0.0-1.0)
    var selectedModel: SupportedModel // 目前選取的模型
    var isSwitching: Bool             // 是否正在切換模型
    
    func loadModel() async throws     // 載入模型
    func unloadModel() async          // 卸載模型
    func switchModel(to: SupportedModel) async throws // 切換模型
    func generate(image: UIImage, prompt: String, onStatusUpdate: (@Sendable (String) -> Void)?) async throws -> String // 執行推論
}
```

### SupportedModel

```swift
enum SupportedModel: String, CaseIterable, Identifiable {
    case qwen2VL2B = "Qwen2-VL-2B"
    case qwen25VL3B = "Qwen2.5-VL-3B"
    case qwen3VL4B = "Qwen3-VL-4B"
    case gemma3_4B = "Gemma3-4B"
    
    var configuration: ModelConfiguration  // 模型配置
    var recommendedCacheLimit: Int          // 建議快取上限（bytes）
}
```

### SceneDescriber

```swift
@MainActor
final class SceneDescriber {
    // 主要血壓 OCR 方法
    func describeBP(image: UIImage, vlmManager: VLMManager, onStatusUpdate: (@Sendable (String) -> Void)?) async throws -> BloodPressureReading
    
    // 備援方法：從文字解析血壓值
    func parseBPFromText(_ text: String) -> BloodPressureReading?
    
    // 對話分析：從語音轉錄提取生命徵象
    func parseVitalSignsFromConversation(_ text: String) async throws -> VitalSignsReading
    
    // Regex Fallback
    func parseVitalSignsFallback(_ text: String) -> VitalSignsReading?
}
```

### 資料模型

```swift
struct BloodPressureReading: Codable {
    var SYS: Int?    // 收縮壓：60-250 mmHg
    var DIA: Int?   // 舒張壓：30-150 mmHg
    var PUL: Int?   // 脈搏：40-200 bpm
}

@Generable
struct VitalSignsReading: Codable {
    var SYS: Int?          // 收縮壓
    var DIA: Int?         // 舒張壓
    var PUL: Int?         // 脈搏
    var bloodSugar: Int?  // 血糖
    var temperature: Double? // 體溫
    var spO2: Int?        // 血氧
}
```

---

## 技術實現細節

### MLX 框架整合

VLMManager 使用 MLX 框架進行本地端推論：

1. **模型容器** (`ModelContainer`)：封裝模型權重和配置
2. **處理器** (`Processor`)：將圖片和文字轉換為張量
3. **生成器** (`MLXLMCommon.generate`)：執行自迴歸生成

```swift
let lmInput = try await context.processor.prepare(input: userInput)
let stream = try MLXLMCommon.generate(
    input: lmInput,
    parameters: parameters,
    context: context
)
```

### 臨時檔案管理

為避免記憶體溢滿，圖片資料寫入暫存檔：

```swift
let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
try imageData.write(to: tempURL)
defer { try? FileManager.default.removeItem(at: tempURL) }
```

### 狀態回調機制

推論過程中的狀態透過回調函式傳遞給 UI：

```swift
onStatusUpdate?("📐 Resizing image...")
onStatusUpdate?("🤖 Running AI inference...")
onStatusUpdate?("✅ Analysis complete!")
```

---

## 版本歷史

| 版本 | 日期 | 變更 |
|------|------|------|
| 1.0 | 2026-01-13 | 初始架構文件 |
| 1.1 | 2026-01-25 | 新增 VLM 整合與 CoT prompting |
| 1.2 | 2026-03-31 | 強化記憶體管理、雙軌 OCR |

---
