import AVFoundation
import SwiftUI
import UIKit
import Combine

final class CameraService: NSObject, ObservableObject {
    // Camera capture plumbing.
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let frameBufferLimit = 8

    // Live frame state observed by UI/view model.
    @Published private(set) var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var latestFrame: UIImage?
    @Published private(set) var latestFrameTimestamp: Date?
    @Published private(set) var isFrameUpdatesPaused = false
    private var frameBuffer: [UIImage] = []

    // Requests camera permission, then configures session when allowed.
    func requestAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                }
                if granted {
                    self?.configureSession()
                }
            }
        default:
            DispatchQueue.main.async {
                self.authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    // Starts camera capture on background queue.
    func start() {
        sessionQueue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    // Stops camera capture on background queue.
    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    // Freeze live UI frame updates while scan is running.
    @MainActor
    func pauseFrameUpdates() {
        isFrameUpdatesPaused = true
    }

    // Resume live UI frame updates after scan completes.
    @MainActor
    func resumeFrameUpdates() {
        isFrameUpdatesPaused = false
    }

    // Returns newest buffered frames for smoothing.
    @MainActor
    func recentFrames(limit: Int) -> [UIImage] {
        guard limit > 0 else { return [] }
        return Array(frameBuffer.suffix(limit))
    }

    // One-time camera session setup (back camera + frame output).
    private func configureSession() {
        sessionQueue.async {
            guard self.session.inputs.isEmpty else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            // Force back camera for field scanning.
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
                self.session.commitConfiguration()
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    return
                }
                self.session.addInput(input)
            } catch {
                self.session.commitConfiguration()
                return
            }

            self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.frame.queue"))
            self.output.alwaysDiscardsLateVideoFrames = true

            guard self.session.canAddOutput(self.output) else {
                self.session.commitConfiguration()
                return
            }
            self.session.addOutput(self.output)

            if let connection = self.output.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }

            self.session.commitConfiguration()
            self.start()
        }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    // Converts video frames to UIImage and updates the rolling frame buffer.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        let image = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
        DispatchQueue.main.async {
            guard !self.isFrameUpdatesPaused else { return }
            self.latestFrame = image
            self.latestFrameTimestamp = Date()
            self.frameBuffer.append(image)
            if self.frameBuffer.count > self.frameBufferLimit {
                self.frameBuffer.removeFirst(self.frameBuffer.count - self.frameBufferLimit)
            }
        }
    }
}

// SwiftUI bridge for AVFoundation preview layer.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session
    }
}

// Backing UIView that hosts AVCaptureVideoPreviewLayer.
final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
