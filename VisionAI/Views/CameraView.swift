//
//  CameraView.swift
//  Vision AI
//
//  Created by Integrate AI on 1/13/26.
//

import SwiftUI
import AVFoundation

struct CameraView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = UIScreen.main.bounds
        view.layer.addSublayer(preview)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
