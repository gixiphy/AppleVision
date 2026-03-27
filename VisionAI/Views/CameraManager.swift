@preconcurrency import AVFoundation
import UIKit

@Observable
@MainActor
final class CameraManager {
    
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    
    /// 強持有 delegate，避免 ARC 在回調前釋放
    private var activeDelegate: PhotoCaptureDelegate?
    
    init() {
        configure()
    }
    
    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }
        
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        
        session.commitConfiguration()
    }
    
    /// 在背景執行緒啟動 session，避免阻塞主執行緒
    func startSession() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            if !session.isRunning {
                session.startRunning()
            }
        }
    }
    
    /// 在背景執行緒停止 session
    func stopSession() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }
    
    func capturePhoto() async -> UIImage? {
        // 確保 session 正在運行
        guard session.isRunning else {
            print("⚠️ CameraManager: session is not running, cannot capture photo.")
            return nil
        }
        
        return await withCheckedContinuation { [weak self] continuation in
            let settings = AVCapturePhotoSettings()
            let delegate = PhotoCaptureDelegate { [weak self] image in
                continuation.resume(returning: image)
                // 回調完成後釋放 delegate
                Task { @MainActor [weak self] in
                    self?.activeDelegate = nil
                }
            }
            // 強持有 delegate，確保在回調前不被釋放
            self?.activeDelegate = delegate
            self?.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: @Sendable (UIImage?) -> Void
    
    init(completion: @escaping @Sendable (UIImage?) -> Void) {
        self.completion = completion
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            print("⚠️ PhotoCapture error: \(error.localizedDescription)")
            completion(nil)
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            print("⚠️ PhotoCapture: failed to convert photo data to UIImage")
            completion(nil)
            return
        }
        completion(image)
    }
}
