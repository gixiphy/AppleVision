# Android 團隊技術思路提示 — VisionAI 血壓計 LCD 辨識 App

> **文件用途**：提供給 Android 團隊作為技術遷移參考，包含 iOS 端完整實作細節、Prompt 原文、預處理參數，以及 Google 官方技術棧選型建議。
>
> **產出日期**：2026-03-27

---

## 一、iOS 端做了什麼（一句話）

> **用相機拍一張血壓計 LCD 照片 → 縮圖至 640px → 丟給本地端 VLM 模型 → Prompt 要求輸出 JSON `{SYS, DIA, PUL}` → 解析顯示。**

全部流程 **離線運行**，無後端 API、無資料庫、無藍牙。

---

## 二、核心流程圖

```
┌──────────┐     ┌──────────────┐     ┌─────────────────┐
│ CameraX  │────▶│ 圖片預處理    │────▶│ AI 推論引擎      │
│ 拍照+預覽 │     │ 縮圖至 640px  │     │ (見下方方案選擇) │
└──────────┘     │ JPEG 0.9 壓縮 │     └────────┬────────┘
                 └──────────────┘              │
                                                ▼
                                   ┌─────────────────────┐
                                   │ 解析 JSON 字串       │
                                   │ {"SYS":120,"DIA":80,│
                                   │  "PUL":72}           │
                                   └────────┬────────────┘
                                            │
                                            ▼
                                   ┌─────────────────┐
                                   │ Compose UI 顯示  │
                                   │ SYS / DIA / PUL  │
                                   └─────────────────┘
```

---

## 三、iOS 原始碼關鍵實作摘要

### 3.1 資料模型（直接複製）

**iOS** (`SceneDescriber.swift:126-130`):

```swift
struct BloodPressureReading: Codable {
    var SYS: Int?
    var DIA: Int?
    var PUL: Int?
}
```

**Android 對應**：

```kotlin
@Serializable
data class BloodPressureReading(
    val SYS: Int? = null,
    val DIA: Int? = null,
    val PUL: Int? = null
)
```

### 3.2 Prompt（核心資產，直接移植）

以下 Prompt 是經過 iOS 端驗證有效的，**可原封不動使用**：

```text
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
```

> **注意**：此 Prompt 是針對 Qwen2-VL-2B 調校的，若換成 Gemini Nano，可能需要微調（但結構和思路可保留）。目前版本已優化 LCD 顯示器佈局辨識，明確排除頂部日期/時間列，避免誤判為 SYS 數值。

### 3.3 圖片預處理（關鍵參數）

iOS 端做了以下預處理 (`VLMManager.swift:206-244`)：

| 步驟 | 參數 | 說明 |
|---|---|---|
| 縮圖 | 最大邊 **640px** | 兼顧清晰度與推論速度 |
| 壓縮 | JPEG quality **0.9** | 減少記憶體佔用，對文字幾乎無失真 |
| 灰階轉換 | **已停用** | 實測效果不佳，VLM 能自行處理顏色 |

**Android 對應**：

```kotlin
// Bitmap 縮圖
val maxDimension = 640f
val ratio = min(maxDimension / bitmap.width, maxDimension / bitmap.height)
if (ratio < 1f) {
    val newWidth = (bitmap.width * ratio).toInt()
    val newHeight = (bitmap.height * ratio).toInt()
    bitmap = Bitmap.createScaledBitmap(bitmap, newWidth, newHeight, true)
}

// JPEG 壓縮
val baos = ByteArrayOutputStream()
bitmap.compress(Bitmap.CompressFormat.JPEG, 90, baos)
```

### 3.4 AI 推論參數

iOS 端設定 (`VLMManager.swift:274-277`):

| 參數 | 值 | 說明 |
|---|---|---|
| `maxTokens` | **100** | JSON 輸出約 30 tokens，100 足夠 |
| `temperature` | **0.0** | 確保 OCR 結果完全確定性，無隨機性 |

### 3.5 JSON 解析容錯

VLM 可能輸出額外文字，iOS 端做了一層 JSON 提取容錯 (`SceneDescriber.swift:89-93`)：

```swift
// 從回應中提取 JSON 片段
if let jsonStart = response.firstIndex(of: "{"),
   let jsonEnd = response.lastIndex(of: "}") {
    cleanResponse = String(response[jsonStart...jsonEnd])
}
```

**Android 對應**：

```kotlin
val jsonStart = response.indexOf('{')
val jsonEnd = response.lastIndexOf('}')
if (jsonStart >= 0 && jsonEnd > jsonStart) {
    val jsonStr = response.substring(jsonStart..jsonEnd)
    return Json.decodeFromString<BloodPressureReading>(jsonStr)
}
```

---

## 四、Google 官方 AI 推論方案選擇

### 方案 A：ML Kit GenAI Prompt API + Gemini Nano（推薦優先嘗試）

- **官方文件**：https://developers.google.com/ml-kit/genai/prompt/android
- **官方範例**：https://github.com/googlesamples/mlkit/tree/master/android/genai
- 已支援**圖片 + 文字多模態輸入**
- 不需自帶模型（系統內建 Gemini Nano，由 AICore 管理）
- 零下載成本，零模型管理負擔
- **限制**：需 Android 14+，僅部分裝置支援（Pixel 6+、部分三星旗艦等）
- **狀態**：Beta

```kotlin
// 虛擬碼示意
val promptApi = GenAiPromptManager.create(context)
val bitmap = capturePhoto()  // CameraX 拍照
val resizedBitmap = resize(bitmap, maxDimension = 640)

val response = promptApi.generate(
    text = BLOOD_PRESSURE_PROMPT,
    image = resizedBitmap
)
val reading = parseJson(response)
```

### 方案 B：ML Kit Text Recognition v2（降級 / 通用方案）

- **官方文件**：https://developers.google.com/ml-kit/vision/text-recognition/v2/android
- 傳統 OCR，**所有 Android 裝置可用**
- 需自行寫規則判斷 SYS / DIA / PUL 位置對應
- 可搭配方案 A：ML Kit 官方建議「先 OCR 提取文字，再用 Prompt API 處理」

### 方案 C：LiteRT-LM（未來升級路徑）

- **GitHub**：https://github.com/google-ai-edge/LiteRT-LM
- Google 官方開源 on-device LLM 框架，取代已 deprecated 的 MediaPipe LLM Inference API
- 已支援 Kotlin API (Stable)、GPU / NPU 加速、多模態 Vision 輸入
- 目前已有模型：Gemma3-1B、Qwen2.5-1.5B（純文字），**尚無 VLM 模型可用**
- 等官方發布 VLM `.litertlm` 模型後可作為升級方案

---

## 五、建議實作架構

```kotlin
// 抽象介面 — 方便切換 AI 方案
interface BloodPressureReader {
    suspend fun read(bitmap: Bitmap): BloodPressureReading
    fun isAvailable(): Boolean
}

// 方案 A 實作
class GeminiNanoReader(context: Context) : BloodPressureReader {
    override fun isAvailable(): Boolean {
        // 檢查 AICore 服務是否可用
    }
    override suspend fun read(bitmap: Bitmap): BloodPressureReading {
        // ML Kit GenAI Prompt API 多模態呼叫
    }
}

// 方案 B 實作（降級）
class OcrReader(context: Context) : BloodPressureReader {
    override fun isAvailable(): Boolean = true // 所有裝置可用
    override suspend fun read(bitmap: Bitmap): BloodPressureReading {
        // ML Kit Text Recognition v2 + 規則解析
    }
}

// 工廠方法 — 運行時自動選擇最佳方案
fun createReader(context: Context): BloodPressureReader {
    val geminiReader = GeminiNanoReader(context)
    return if (geminiReader.isAvailable()) geminiReader else OcrReader(context)
}
```

---

## 六、建議專案結構

```
VisionAI-Android/
├── app/src/main/kotlin/com/integrateai/visionai/
│   ├── VisionAIApp.kt                    ← Application 入口
│   ├── MainActivity.kt                   ← 主 Activity
│   ├── ui/
│   │   ├── screen/
│   │   │   └── MainScreen.kt             ← Compose 主畫面
│   │   ├── component/
│   │   │   └── CameraPreview.kt          ← CameraX 預覽
│   │   └── theme/
│   ├── camera/
│   │   └── CameraManager.kt              ← CameraX 控制
│   ├── ai/
│   │   ├── BloodPressureReader.kt         ← 抽象介面
│   │   ├── GeminiNanoReader.kt            ← ML Kit Prompt API 實作
│   │   ├── OcrReader.kt                   ← ML Kit OCR 降級實作
│   │   └── BloodPressureReading.kt        ← 資料模型
│   └── util/
│       ├── DeviceCapability.kt            ← 裝置能力檢測
│       └── ImagePreprocessor.kt           ← 圖片預處理（縮圖、壓縮）
└── build.gradle.kts
```

---

## 七、iOS / Android 對照速查表

| 功能 | iOS 類別 / 方法 | Android 對應 |
|---|---|---|
| App 入口 | `Vision_AIApp.swift` `@main` | `MainActivity.kt` + `setContent {}` |
| 主畫面 | `ContentView.swift` (170 行) | `MainScreen.kt` Jetpack Compose |
| 相機預覽 | `CameraView` (`UIViewRepresentable`) | CameraX `PreviewView` + `AndroidView` |
| 相機管理 | `CameraManager` (`AVCaptureSession`) | `CameraManager` (CameraX `ProcessCameraProvider`) |
| 拍照 | `capturePhoto() async -> UIImage?` | `ImageCapture.takePicture() suspend -> Bitmap?` |
| AI 推論 | `VLMManager.generate(image:prompt:)` | `BloodPressureReader.read(bitmap)` |
| Prompt 構建 + JSON 解析 | `SceneDescriber.describeBP()` | 整合到 `BloodPressureReader` 實作內 |
| 狀態管理 | `@Observable` + `@State` | `ViewModel` + `StateFlow` / `mutableStateOf` |
| 非同步 | `async/await` (Swift Concurrency) | Kotlin Coroutines `suspend` / `Flow` |
| 記憶體壓力處理 | `DispatchSource.makeMemoryPressureSource` | `ComponentCallbacks2.onTrimMemory()` |
| 模型切換 UI | `Picker` + `onChange` | 方案 A 不需要（Gemini Nano 統一版本） |

---

## 八、關鍵提醒

1. **Prompt 是最核心的資產** — 直接復用 iOS 驗證過的 Prompt 文字，減少重複調校時間
2. **Temperature 必須設為 0** — 這是 OCR / 數值讀取場景，需要確定性輸出，不能有隨機性
3. **圖片縮圖到 640px 是平衡點** — 太小看不清七段顯示器數字，太大推論太慢
4. **JSON 解析要做容錯** — VLM 可能輸出多餘文字，用 `{...}` 截取第一個完整 JSON 物件
5. **灰階轉換不需要做** — iOS 實測後已停用，VLM 對彩色圖片處理得更好
6. **優先驗證 Gemini Nano 對 LCD 七段顯示器的辨識精度** — 這是最大風險點，如果精度不足就使用 OCR 降級方案
7. **抽象介面設計是關鍵** — 用 `BloodPressureReader` 介面隔離 AI 引擎，方便未來隨時切換方案（Gemini Nano → LiteRT-LM → 其他）

---

## 九、工作量估算

| 項目 | 預估工時 | 說明 |
|---|---|---|
| 專案建置 + Compose UI | 1-2 天 | UI 非常簡單，僅一個畫面 |
| CameraX 整合 | 1 天 | 拍照 + 預覽 |
| ML Kit Prompt API 整合 | 2-3 天 | Gemini Nano 多模態呼叫 + Prompt 調校 |
| ML Kit OCR 降級方案 | 1-2 天 | Text Recognition v2 + 規則解析 |
| 裝置能力檢測 + 方案切換 | 0.5 天 | 檢測 AICore 可用性 |
| 精度驗證與 Prompt 調優 | 2-3 天 | 確認 Gemini Nano 辨識血壓計的精度 |
| **總計** | **約 8-12 天** | 單人全職開發 |

---

## 十、主要風險

| 風險 | 影響 | 緩解措施 |
|---|---|---|
| Gemini Nano 辨識 LCD 精度不足 | 核心功能失效 | 降級到 OCR 方案；或等 LiteRT-LM 支援 VLM |
| 裝置覆蓋率低 | 使用者受限 | OCR 降級方案確保所有裝置基本功能 |
| ML Kit GenAI Prompt API 仍為 Beta | API 可能變動 | 抽象介面層隔離依賴，降低耦合 |
| Prompt 在不同模型表現差異 | 輸出不一致 | 針對 Gemini Nano 做專屬 Prompt 調校 |
