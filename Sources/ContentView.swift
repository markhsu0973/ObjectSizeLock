import SwiftUI
import AVFoundation
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraTracker()
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(camera: camera).ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Text(camera.status).lineLimit(2)
                    Spacer()
                    Text(String(format: "%.1f×", camera.zoom)).monospacedDigit()
                }
                .padding(12)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                Spacer()
                HStack(spacing: 12) {
                    Button("重新選取") { camera.resetTracking() }
                    Button(camera.autoZoom ? "自動縮放：開" : "自動縮放：關") {
                        camera.toggleAutoZoom()
                    }
                    Button(camera.recording ? "停止錄影" : "開始錄影") {
                        camera.toggleRecording()
                    }
                    .tint(camera.recording ? .red : .green)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(12)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                Text("點一下選取物件，或拖曳框選更準確。選取瞬間的大小會成為目標大小。")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.top, 18)
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

final class TrackingPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private let targetLayer = CAShapeLayer()
    private var target: CGRect?
    var onSelection: ((CGRect) -> Void)?
    private var dragStart: CGPoint?
    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        targetLayer.strokeColor = UIColor.systemGreen.cgColor
        targetLayer.fillColor = UIColor.clear.cgColor
        targetLayer.lineWidth = 2.5
        layer.addSublayer(targetLayer)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        targetLayer.frame = bounds
        redrawTarget()
    }
    func show(_ normalizedRect: CGRect?) {
        target = normalizedRect
        redrawTarget()
    }
    private func redrawTarget() {
        guard let target else { targetLayer.path = nil; return }
        let rect = previewLayer.layerRectConverted(fromMetadataOutputRect: target)
        targetLayer.path = UIBezierPath(rect: rect).cgPath
    }
    private func pick(_ rect: CGRect) {
        let clipped = rect.intersection(bounds)
        guard clipped.width >= 6, clipped.height >= 6 else { return }
        let meta = previewLayer.metadataOutputRectConverted(fromLayerRect: clipped)
        let bounded = meta.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard bounded.width > 0.01, bounded.height > 0.01 else { return }
        onSelection?(bounded)
    }
    @objc private func didTap(_ gesture: UITapGestureRecognizer) {
        let p = gesture.location(in: self)
        let side = min(bounds.width, bounds.height) * 0.22
        pick(CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
    }
    @objc private func didPan(_ gesture: UIPanGestureRecognizer) {
        let current = gesture.location(in: self)
        switch gesture.state {
        case .began: dragStart = current
        case .ended:
            guard let start = dragStart else { return }
            dragStart = nil
            pick(CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                        width: abs(current.x - start.x), height: abs(current.y - start.y)))
        default: break
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraTracker
    func makeUIView(context: Context) -> TrackingPreviewView {
        let view = TrackingPreviewView()
        view.previewLayer.session = camera.session
        view.onSelection = { [weak camera] rect in camera?.selectTarget(metadataRect: rect) }
        return view
    }
    func updateUIView(_ view: TrackingPreviewView, context: Context) {
        view.show(camera.trackingRect)
        if let connection = view.previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}
