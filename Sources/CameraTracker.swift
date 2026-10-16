import Foundation
import AVFoundation
import Vision
import Photos
import UIKit

final class CameraTracker: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var status = "請點選或拖曳框選要追蹤的物件"
    @Published var zoom: CGFloat = 1
    @Published var trackingRect: CGRect? // metadata coordinates, top-left origin
    @Published var recording = false
    @Published var autoZoom = true

    private let sessionQueue = DispatchQueue(label: "size.lock.session")
    private let videoQueue = DispatchQueue(label: "size.lock.tracking", qos: .userInitiated)
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var camera: AVCaptureDevice?
    private var configured = false
    // All values below are owned by videoQueue.
    private var request: VNTrackObjectRequest?
    private var sequence = VNSequenceRequestHandler()
    private var baselineArea: CGFloat = 0
    private var lastZoomUpdate: CFTimeInterval = 0
    private var lastDisplayUpdate: CFTimeInterval = 0
    private var zoomEnabled = true

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.status = "請到設定允許相機權限" }
                return
            }
            self.sessionQueue.async {
                if !self.configured { self.configure() }
                if self.configured && !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning && !self.movieOutput.isRecording { self.session.stopRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let videoInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(videoInput) else {
            DispatchQueue.main.async { self.status = "找不到可用的後置相機" }
            return
        }
        session.addInput(videoInput)
        camera = device

        // Sound is optional: video recording must still work without microphone permission.
        if let microphone = AVCaptureDevice.default(for: .audio),
           let microphoneInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(microphoneInput) {
            session.addInput(microphoneInput)
        }
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoDataOutput), session.canAddOutput(movieOutput) else {
            DispatchQueue.main.async { self.status = "無法啟用影像輸出" }
            return
        }
        session.addOutput(videoDataOutput)
        session.addOutput(movieOutput)
        for output in [videoDataOutput as AVCaptureOutput, movieOutput as AVCaptureOutput] {
            if let conn = output.connection(with: .video), conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
        }
        configured = true
    }

    func selectTarget(metadataRect: CGRect) {
        videoQueue.async {
            // Vision uses lower-left origin; metadata coordinates use upper-left origin.
            let visionBox = CGRect(x: metadataRect.minX,
                                   y: 1 - metadataRect.maxY,
                                   width: metadataRect.width,
                                   height: metadataRect.height)
            let observation = VNDetectedObjectObservation(boundingBox: visionBox)
            let tracker = VNTrackObjectRequest(detectedObjectObservation: observation)
            tracker.trackingLevel = .accurate
            self.request = tracker
            self.sequence = VNSequenceRequestHandler()
            self.baselineArea = max(visionBox.width * visionBox.height, 0.0001)
            self.lastZoomUpdate = 0
            DispatchQueue.main.async {
                self.trackingRect = metadataRect
                self.status = "正在追蹤（原始大小已鎖定）"
            }
        }
    }

    func resetTracking() {
        videoQueue.async {
            self.request = nil
            self.baselineArea = 0
            DispatchQueue.main.async {
                self.trackingRect = nil
                self.status = "請重新點選或框選物件"
            }
        }
    }

    func toggleAutoZoom() {
        let enabled = !autoZoom
        autoZoom = enabled
        videoQueue.async { self.zoomEnabled = enabled }
    }

    func toggleRecording() {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            } else {
                guard self.configured && self.session.isRunning else {
                    DispatchQueue.main.async { self.status = "相機尚未就緒" }
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                if let connection = self.movieOutput.connection(with: .video), connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    private func updateZoom(measuredArea: CGFloat) {
        let now = CACurrentMediaTime()
        guard now - lastZoomUpdate >= 0.25,
              let device = camera, baselineArea > 0,
              measuredArea > 0.00001 else { return }
        lastZoomUpdate = now
        let scaleRatio = sqrt(baselineArea / measuredArea)
        if abs(log(scaleRatio)) < 0.075 { return } // 7.5% log dead band
        let current = device.videoZoomFactor
        // Partial proportional correction prevents zoom oscillations.
        let newZoom = current * pow(scaleRatio, 0.32)
        let maxZoom = min(CGFloat(8), device.activeFormat.videoMaxZoomFactor,
                          device.maxAvailableVideoZoomFactor)
        let next = min(maxZoom, max(device.minAvailableVideoZoomFactor, newZoom))
        guard abs(next - current) > 0.04 else { return }
        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: next, withRate: 0.65)
            device.unlockForConfiguration()
        } catch { /* A competing camera configuration can temporarily prevent zoom changes. */ }
    }
}

extension CameraTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let request, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        do {
            // Back camera, portrait preview. Check orientation on specific devices.
            try sequence.perform([request], on: buffer, orientation: .right)
            guard let observation = request.results?.first as? VNDetectedObjectObservation,
                  observation.confidence >= 0.35 else {
                self.request = nil
                DispatchQueue.main.async {
                    self.trackingRect = nil
                    self.status = "目標遺失，請重新框選"
                }
                return
            }
            request.inputObservation = observation
            let box = observation.boundingBox
            let metadataBox = CGRect(x: box.minX, y: 1 - box.maxY,
                                     width: box.width, height: box.height)
            let now = CACurrentMediaTime()
            if now - lastDisplayUpdate >= 0.1 {
                lastDisplayUpdate = now
                let currentZoom = camera?.videoZoomFactor ?? 1
                DispatchQueue.main.async {
                    self.trackingRect = metadataBox
                    self.zoom = currentZoom
                }
            }
            // Access main-thread UI setting without changing the vision queue's tracking state.
            if zoomEnabled { updateZoom(measuredArea: box.width * box.height) }
        } catch {
            self.request = nil
            DispatchQueue.main.async { self.status = "追蹤失敗，請重新框選" }
        }
    }
}

extension CameraTracker: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.recording = true }
    }
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.recording = false }
        guard error == nil else {
            DispatchQueue.main.async { self.status = "錄影失敗：\(error!.localizedDescription)" }
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { permission in
            guard permission == .authorized || permission == .limited else {
                DispatchQueue.main.async { self.status = "影片位於暫存區；請允許儲存到照片" }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
            }, completionHandler: { success, saveError in
                DispatchQueue.main.async {
                    self.status = success ? "影片已儲存到照片" : "儲存失敗：\(saveError?.localizedDescription ?? "未知錯誤")"
                }
                if success { try? FileManager.default.removeItem(at: outputFileURL) }
            })
        }
    }
}
