import Foundation
import AVFoundation
import Vision
import Photos
import UIKit

final class CameraTracker: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var status = "請拖曳框選整個物件；建議先關閉自動縮放確認追蹤"
    @Published var zoom: CGFloat = 1
    @Published var trackingRect: CGRect? // metadata coordinates, top-left origin
    @Published var rawVisionRect: CGRect? // same metadata coordinate space; unfiltered Vision result
    @Published var selectionRect: CGRect? // frozen user selection for mapping diagnosis
    @Published var recording = false
    @Published var autoZoom = false
    @Published var diagnostics = "等待框選"
    @Published var trackingQuality = "IDLE"

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
    private var zoomEnabled = false
    private var lastAcceptedBox: CGRect?
    private var lastAcceptedTime: CFTimeInterval = 0
    private var stableFrames = 0
    private var zoomSettlingUntil: CFTimeInterval = 0
    private var confidenceFailures = 0
    private var uncertainFrames = 0
    private let rejectAfterFrames = 18
    private let minimumVisionConfidence: Float = 0.45
    private let recoveryConfidence: Float = 0.65
    private var lastUncertainNotice: CFTimeInterval = 0
    private var approvedZoomFrames = 0
    private var smoothedArea: CGFloat?
    // Conservative initial limit; can be raised after real-device validation.
    private let safetyZoomLimit: CGFloat = 3.0
    // The selected target is verified against a frozen, brightness-normalized
    // image patch, so a high Vision confidence alone cannot approve tracking.
    private var referencePatch: [Float]?
    private var pendingSelection: CGRect?
    private var appearanceFailures = 0
    private var trackingValidated = false
    private var latestSampleTime: CFTimeInterval = 0
    private let minimumSimilarity: Float = 0.60
    private var diagnosticFrames = 0
    private var lastSimilarity: Float = -1
    private var lastVisionConfidence: Float = 0
    private var consecutiveGoodFrames = 0
    private var previousVisionBox: CGRect?
    // Experimental global re-detection of the original image template.
    private var isSearching = false
    private var searchBoxSize = CGSize.zero
    private var lastSearchAt: CFTimeInterval = 0
    private var candidateForRecovery: CGRect?
    private var recoveryHits = 0
    private var lostSince: CFTimeInterval = 0
    private let recoveryThreshold: Float = 0.84
    // v0.7: do not accept template search as identity evidence.
    // Global search can falsely relock onto similarly textured background.
    private let allowUnsafeTemplateReacquisition = false


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
            self.pendingSelection = visionBox
            self.referencePatch = nil
            self.isSearching = false
            self.candidateForRecovery = nil
            self.recoveryHits = 0
            self.searchBoxSize = visionBox.size
            self.trackingValidated = false
            self.appearanceFailures = 0
            self.baselineArea = max(visionBox.width * visionBox.height, 0.0001)
            self.lastZoomUpdate = CACurrentMediaTime()
            self.zoomSettlingUntil = CACurrentMediaTime() + 0.5
            self.stableFrames = 0
            self.confidenceFailures = 0
            self.approvedZoomFrames = 0
            self.smoothedArea = nil
            self.lastAcceptedBox = visionBox
            self.uncertainFrames = 0
            self.consecutiveGoodFrames = 0
            self.previousVisionBox = nil
            self.lastAcceptedTime = CACurrentMediaTime()
            DispatchQueue.main.async {
                self.trackingRect = metadataRect
                self.rawVisionRect = metadataRect
                self.selectionRect = metadataRect
                self.trackingQuality = "INITIALIZING"
                self.diagnostics = "等待第一幀影像"
                self.status = "v0.8 診斷：Vision 連續更新；自動變焦暫停"
            }
        }
    }

    func resetTracking() {
        videoQueue.async {
            self.request = nil
            self.pendingSelection = nil
            self.referencePatch = nil
            self.isSearching = false
            self.candidateForRecovery = nil
            self.recoveryHits = 0
            self.trackingValidated = false
            self.baselineArea = 0
            self.lastAcceptedBox = nil
            self.stableFrames = 0
            self.confidenceFailures = 0
            self.approvedZoomFrames = 0
            self.smoothedArea = nil
            self.uncertainFrames = 0
            self.consecutiveGoodFrames = 0
            self.previousVisionBox = nil
            DispatchQueue.main.async {
                self.trackingRect = nil
                self.rawVisionRect = nil
                self.selectionRect = nil
                self.trackingQuality = "IDLE"
                self.diagnostics = "等待框選"
                self.status = "請重新點選或框選物件"
            }
        }
    }

    func toggleAutoZoom() {
        // For diagnostic safety do not allow zoom while raw tracking validity
        // is under investigation; restoring zoom requires an explicit patch.
        autoZoom = false
        videoQueue.async { self.zoomEnabled = false }
        status = "v0.8 診斷版固定 1×；先確認追蹤框連續性"
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

    private func updateZoom(measuredArea: CGFloat, now: CFTimeInterval) {
        guard now >= zoomSettlingUntil,
              now - lastZoomUpdate >= 1.5,
              stableFrames >= 20,
              approvedZoomFrames >= 20,
              let device = camera, baselineArea > 0,
              measuredArea > 0.0001 else { return }

        // The Vision bounding box already includes optical/digital zoom. Use
        // sqrt of the area ratio but apply only a small proportional correction.
        let relativeSizeError = sqrt(baselineArea / measuredArea)
        guard relativeSizeError.isFinite,
              relativeSizeError > 0.0,
              abs(log(relativeSizeError)) >= 0.22 else { return }

        let current = device.videoZoomFactor
        let maxZoom = min(safetyZoomLimit, device.activeFormat.videoMaxZoomFactor,
                          device.maxAvailableVideoZoomFactor)
        let minZoom = max(CGFloat(1), device.minAvailableVideoZoomFactor)
        guard maxZoom >= minZoom else { return }

        // Bound a single correction to +/- 8% regardless of tracking-box noise.
        let correction = min(CGFloat(1.045), max(CGFloat(0.955), pow(relativeSizeError, 0.12)))
        let desired = min(maxZoom, max(minZoom, current * correction))
        guard abs(desired - current) >= 0.035 else { return }
        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: desired, withRate: 0.35)
            device.unlockForConfiguration()
            lastZoomUpdate = now
            zoomSettlingUntil = now + 2.0
            stableFrames = 0
            approvedZoomFrames = 0
        } catch {
            lastZoomUpdate = now
        }
    }

    // Sample a brightness-normalized 24x24 thumbnail directly from the
    // camera Y plane. AVCapture video frames are landscape-native; with a
    // portrait .right Vision orientation the image is rotated clockwise.
    // Vision rectangles have a bottom-left origin. This mapping is independent
    // of UIImage scale, preview aspect-fill and layer coordinate transforms.
    private static func lumaPatch(buffer: CVPixelBuffer, visionBox: CGRect) -> [Float]? {
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let rawW = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let rawH = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let n = 24
        // Avoid boundary-only samples where feature identity is weak.
        let inset: CGFloat = 0.12
        var samples = [Float]()
        samples.reserveCapacity(n*n)
        guard visionBox.width > 0.015, visionBox.height > 0.015 else { return nil }
        for j in 0..<n {
            for i in 0..<n {
                let xNorm = visionBox.minX + visionBox.width * (inset + (1 - 2 * inset) * (CGFloat(i) + 0.5) / CGFloat(n))
                let yNorm = visionBox.maxY - visionBox.height * (inset + (1 - 2 * inset) * (CGFloat(j) + 0.5) / CGFloat(n))
                // Vision .right: clockwise-rotated image's x,y (top origin)
                // map to raw landscape buffer (rawX = portraitTopY,
                // rawY = 1 - portraitX).
                let rawX = min(rawW - 1, max(0, Int((1 - yNorm) * CGFloat(rawW))))
                let rawY = min(rawH - 1, max(0, Int((1 - xNorm) * CGFloat(rawH))))
                samples.append(Float(luma[rawY * bytesPerRow + rawX]) / 255.0)
            }
        }
        return samples
    }

    private static func variance(_ a: [Float]) -> Float {
        guard !a.isEmpty else { return 0 }
        let mean = a.reduce(0, +) / Float(a.count)
        return a.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(a.count)
    }

    private static func normalizedCorrelation(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        let meanA = a.reduce(0, +) / Float(a.count)
        let meanB = b.reduce(0, +) / Float(b.count)
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in a.indices {
            let da = a[i] - meanA, db = b[i] - meanB
            dot += da * db
            normA += da * da
            normB += db * db
        }
        guard normA > 0.001, normB > 0.001 else { return -1 }
        return dot / sqrt(normA * normB)
    }

    // Preserve the reference appearance instead of discarding it on loss.
    // A new target is accepted only after two spatially consistent global hits.
    private func loseTarget(_ message: String) {
        if !isSearching {
            isSearching = true
            lostSince = CACurrentMediaTime()
            searchBoxSize = (lastAcceptedBox ?? request?.inputObservation.boundingBox ?? .zero).size
        }
        request = nil
        trackingValidated = false
        stableFrames = 0
        confidenceFailures = 0
        approvedZoomFrames = 0
        candidateForRecovery = nil
        recoveryHits = 0
        DispatchQueue.main.async {
            self.trackingRect = nil
            self.rawVisionRect = nil
            self.trackingQuality = "LOST"
            self.diagnostics = "LOST: \(message)"
            self.status = "LOST：\(message)。已停止變焦，請重新框選（自動重鎖暫停）"
        }
    }

    private func searchForTarget(in buffer: CVPixelBuffer, at now: CFTimeInterval) {
        guard allowUnsafeTemplateReacquisition, isSearching, let reference = referencePatch,
              searchBoxSize.width > 0.025, searchBoxSize.height > 0.025,
              now - lastSearchAt > 0.65 else { return }
        lastSearchAt = now
        // Search the whole image at several scales. This is a conservative,
        // CPU-only prototype; it is not a trained re-identification network.
        let scales: [CGFloat] = [0.75, 1.0, 1.25]
        var bestScore: Float = -1
        var bestBox: CGRect?
        for scale in scales {
            let width = min(0.50, searchBoxSize.width * scale)
            let height = min(0.50, searchBoxSize.height * scale)
            guard width >= 0.025, height >= 0.025 else { continue }
            let strideX = max(0.018, width * 0.35)
            let strideY = max(0.018, height * 0.35)
            var y: CGFloat = 0
            while y <= 1 - height {
                var x: CGFloat = 0
                while x <= 1 - width {
                    let box = CGRect(x: x, y: y, width: width, height: height)
                    if let patch = Self.lumaPatch(buffer: buffer, visionBox: box),
                       Self.variance(patch) >= 0.0007 {
                        let score = Self.normalizedCorrelation(reference, patch)
                        if score > bestScore { bestScore = score; bestBox = box }
                    }
                    x += strideX
                }
                y += strideY
            }
        }
        guard bestScore >= recoveryThreshold, let box = bestBox else {
            candidateForRecovery = nil
            recoveryHits = 0
            return
        }
        if let prior = candidateForRecovery,
           hypot(prior.midX - box.midX, prior.midY - box.midY) < 0.08 {
            recoveryHits += 1
        } else {
            recoveryHits = 1
        }
        candidateForRecovery = box
        guard recoveryHits >= 2 else { return }
        let obs = VNDetectedObjectObservation(boundingBox: box)
        let newRequest = VNTrackObjectRequest(detectedObjectObservation: obs)
        newRequest.trackingLevel = .accurate
        sequence = VNSequenceRequestHandler()
        request = newRequest
        isSearching = false
        trackingValidated = true
        lastAcceptedBox = box
        smoothedArea = box.width * box.height
        zoomSettlingUntil = now + 1.8
        stableFrames = 0
        approvedZoomFrames = 0
        appearanceFailures = 0
        confidenceFailures = 0
        candidateForRecovery = nil
        recoveryHits = 0
        let meta = CGRect(x: box.minX, y: 1 - box.maxY,
                          width: box.width, height: box.height)
        DispatchQueue.main.async {
            self.trackingRect = meta
            self.trackingQuality = "REACQUIRED?"
            self.status = "REACQUIRED 候選：請人工確認綠框是否正確"
        }
    }

}

extension CameraTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        // Wait for the first actual camera frame before capturing the selected
        // target's appearance. The selection rect is in Vision coordinates.
        if let selected = pendingSelection {
            if let patch = Self.lumaPatch(buffer: buffer, visionBox: selected) {
                let variance = Self.variance(patch)
                // Uniform surfaces cannot be matched reliably.
                if variance < 0.0007 {
                    loseTarget("選取區域缺少紋理，請框選有細節的物件")
                } else {
                    referencePatch = patch
                    pendingSelection = nil
                    trackingValidated = true
                    DispatchQueue.main.async {
                        self.trackingQuality = "TRACKING"
                        self.diagnostics = String(format: "模板方差 %.4f", variance)
                    }
                }
            }
            return
        }
        if isSearching {
            // Retain target data but do not present a background template hit
            // as a recovered object identity. Requires a true Re-ID model.
            searchForTarget(in: buffer, at: now)
            return
        }
        guard let request, let referencePatch, trackingValidated else { return }
        // Limit image comparisons and Vision requests to ~12 Hz. Camera
        // capture/recording itself stays at the normal configured frame rate.
        guard now - latestSampleTime >= 0.08 else { return }
        latestSampleTime = now
        do {
            // Back camera, portrait preview. Check orientation on specific devices.
            try sequence.perform([request], on: buffer, orientation: .right)
            guard let observation = request.results?.first as? VNDetectedObjectObservation else {
                confidenceFailures += 1
                stableFrames = 0
                approvedZoomFrames = 0
                if confidenceFailures >= rejectAfterFrames { loseTarget("Vision 未回傳追蹤結果") }
                return
            }
            // Always advance Vision's state on the next frame, even when a
            // quality gate rejects the output for display/zoom. Otherwise the
            // same old input observation is repeatedly tracked and false LOST
            // decisions accumulate while the real target keeps moving.
            request.inputObservation = observation
            lastVisionConfidence = observation.confidence
            if observation.confidence < minimumVisionConfidence {
                confidenceFailures += 1
                consecutiveGoodFrames = 0
                stableFrames = 0
                approvedZoomFrames = 0
                if confidenceFailures == 1 || confidenceFailures % 5 == 0 {
                    let misses = confidenceFailures
                    DispatchQueue.main.async {
                        self.trackingQuality = "UNCERTAIN"
                        self.diagnostics = String(format: "Vision %.2f | 低信心 %d/%d", observation.confidence, misses, self.rejectAfterFrames)
                    }
                }
                if confidenceFailures >= rejectAfterFrames { loseTarget("Vision 信心值持續不足") }
                return
            }
            confidenceFailures = 0
            let box = observation.boundingBox
            let rawMetadata = CGRect(x: box.minX, y: 1 - box.maxY,
                                     width: box.width, height: box.height)
            // Raw box always visible (magenta), even if quality gates reject it.
            DispatchQueue.main.async { self.rawVisionRect = rawMetadata }
            let area = box.width * box.height
            guard box.width > 0.025, box.height > 0.025,
                  box.minX >= 0, box.minY >= 0,
                  box.maxX <= 1, box.maxY <= 1,
                  area.isFinite else {
                loseTarget("追蹤框異常，已停止變焦，請重新框選")
                return
            }
            if let previous = lastAcceptedBox {
                let oldArea = previous.width * previous.height
                let areaRatio = area / max(oldArea, 0.0001)
                let centerJump = hypot(box.midX - previous.midX, box.midY - previous.midY)
                // Reject sudden drift onto the background or a different object.
                // Judge movement relative to the *previous Vision result*,
                // rather than the last accepted frame that may be seconds old.
                // The latter makes normal continuous movement appear to be an
                // increasingly large jump during an UNCERTAIN interval.
                let recent = previousVisionBox ?? previous
                let frameJump = hypot(box.midX - recent.midX, box.midY - recent.midY)
                let frameAreaRatio = area / max(recent.width * recent.height, 0.0001)
                if frameAreaRatio < 0.50 || frameAreaRatio > 2.0 || frameJump > 0.20 {
                    uncertainFrames += 1
                    approvedZoomFrames = 0
                    stableFrames = 0
                    // Do not update the reference with an implausible box.
                    // Reinitialize the local tracker from the last reliable box
                    // instead of feeding the rejected observation back into it.
                    if uncertainFrames == 1 || uncertainFrames % 4 == 0 {
                        let misses = uncertainFrames
                        DispatchQueue.main.async {
                            self.trackingQuality = "UNCERTAIN"
                            self.diagnostics = String(format: "Vision %.2f | 幀位移 %.3f | 幀面積比 %.2f | 異常 %d", observation.confidence, frameJump, frameAreaRatio, misses)
                            self.status = "追蹤框不穩定：停止變焦並觀察"
                        }
                    }
                    previousVisionBox = box
                    if uncertainFrames >= rejectAfterFrames { loseTarget("Vision 框持續突變") }
                    return
                }
            }
            uncertainFrames = 0
            previousVisionBox = box
            consecutiveGoodFrames = observation.confidence >= recoveryConfidence ? consecutiveGoodFrames + 1 : 0
            // Diagnostic v0.8: appearance is measured, NOT used as a hard
            // rejection criterion. Fixed grayscale templates are too sensitive
            // to motion, imperfect boxes and scale variation.
            let candidate = Self.lumaPatch(buffer: buffer, visionBox: box)
            let similarity: Float = candidate.map {
                Self.normalizedCorrelation(referencePatch, $0)
            } ?? -1
            lastSimilarity = similarity
            lastVisionConfidence = observation.confidence
            appearanceFailures = similarity < minimumSimilarity ? appearanceFailures + 1 : 0
            // A low appearance score disables zoom, but Vision tracking keeps
            // running so we can distinguish tracker drift from false rejection.
            if similarity < minimumSimilarity {
                approvedZoomFrames = 0
            }
            // Smooth size measurement and require consistent observations before zooming.
            let previousArea = smoothedArea ?? area
            let residual = abs(log(max(area, 0.0001) / max(previousArea, 0.0001)))
            smoothedArea = previousArea * 0.82 + area * 0.18
            if residual < 0.075 && similarity >= minimumSimilarity { approvedZoomFrames += 1 } else { approvedZoomFrames = 0 }
            lastAcceptedBox = box
            lastAcceptedTime = now
            if now >= zoomSettlingUntil { stableFrames += 1 }
            else { stableFrames = 0 }

            let metadataBox = CGRect(x: box.minX, y: 1 - box.maxY,
                                     width: box.width, height: box.height)
            if now - lastDisplayUpdate >= 0.1 {
                lastDisplayUpdate = now
                let currentZoom = camera?.videoZoomFactor ?? 1
                let failures = appearanceFailures
                DispatchQueue.main.async {
                    self.trackingRect = metadataBox
                    self.zoom = currentZoom
                    self.trackingQuality = self.consecutiveGoodFrames >= 3 ? "TRACKING" : "UNCERTAIN"
                    self.diagnostics = String(format: "Vision %.2f | 相似 %.2f | Box (%.2f,%.2f,%.2f,%.2f) | 不符 %d", observation.confidence, similarity, box.minX, box.minY, box.width, box.height, failures)
                }
            }
            // Diagnostic build: freeze automated zoom until bounding-box
            // orientation/continuity is verified on the target device.
            // The UI toggle stays usable but cannot command lens movement.

        } catch {
            loseTarget("追蹤失敗，已停止變焦，請重新框選")
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
