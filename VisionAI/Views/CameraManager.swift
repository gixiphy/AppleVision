import AVFoundation
import UIKit
import Combine

final class CameraManager: NSObject, ObservableObject {

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()

    private var photoDelegate: PhotoDelegate?

    override init() {
        super.init()
        configure()
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                 for: .video,
                                                 position: .back),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        session.commitConfiguration()
    }

    func capturePhoto() async -> UIImage? {
        await withCheckedContinuation { continuation in
            let settings = AVCapturePhotoSettings()

            // Retain delegate
            photoDelegate = PhotoDelegate { [weak self] image in
                continuation.resume(returning: image)
                self?.photoDelegate = nil // release after use
            }

            output.capturePhoto(with: settings, delegate: photoDelegate!)
        }
    }
}


final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {

    private let completion: (UIImage?) -> Void

    init(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {

        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(nil)
            return
        }

        completion(image)
    }
}
