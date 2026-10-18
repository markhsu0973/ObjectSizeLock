import SwiftUI
import CoreML
import Foundation

// v1.1 isolates the performance test from the live camera and video recorder.
// Random arrays are for latency measurement ONLY; they do not validate tracking accuracy.
struct OSTrackBenchmarkView: View {
    @State private var status = "尚未執行"
    @State private var details = "測試固定 192/384 輸入；不使用攝影機，不控制 Zoom。"
    @State private var running = false
    @State private var iterations = 5

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("OSTrack ViT-B/384 · Core ML")
                        .font(.headline)
                    Text("這是 Core ML 載入及延遲測試，並非即時物件追蹤。")
                        .foregroundStyle(.secondary)
                    Stepper("測試次數：\(iterations)", value: $iterations, in: 1...20)
                        .disabled(running)
                    Button(running ? "測試中…" : "開始效能測試") { runBenchmark() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running)
                    Text(status).font(.headline)
                    Text(details).font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Core ML Benchmark")
            .navigationBarTitleDisplayMode(.inline)

        }
    }

    private func runBenchmark() {
        running = true
        status = "載入模型…"
        details = "正在背景佇列執行，首次模型編譯／載入可能較慢。"
        let count = iterations
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try OSTrackCoreMLBench.run(count: count)
                DispatchQueue.main.async {
                    status = "完成 · \(String(format: "%.1f", result.fps)) FPS"
                    details = result.report
                    running = false
                }
            } catch {
                DispatchQueue.main.async {
                    status = "測試失敗"
                    details = error.localizedDescription
                    running = false
                }
            }
        }
    }
}

private enum OSTrackCoreMLBench {
    struct Result {
        let fps: Double
        let report: String
    }

    static func run(count: Int) throws -> Result {
        guard let url = Bundle.main.url(forResource: "ostrack_vitb384", withExtension: "mlmodelc") else {
            throw NSError(domain: "OSTrackBenchmark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "App 找不到 ostrack_vitb384.mlmodelc。請確認 GitHub Actions 已下載並編譯 .mlpackage。"])
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let loadStart = CFAbsoluteTimeGetCurrent()
        let model = try MLModel(contentsOf: url, configuration: config)
        let loadTime = CFAbsoluteTimeGetCurrent() - loadStart

        let template = try MLMultiArray(shape: [1, 3, 192, 192], dataType: .float32)
        let search = try MLMultiArray(shape: [1, 3, 384, 384], dataType: .float32)
        // Neutral synthetic tensors: this only measures inference speed and output layout.
        for i in 0..<template.count { template[i] = 0 }
        for i in 0..<search.count { search[i] = 0 }
        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            "template": MLFeatureValue(multiArray: template),
            "search": MLFeatureValue(multiArray: search)
        ])
        let options = MLPredictionOptions()
        // One warm-up call is excluded from reported latency.
        _ = try model.prediction(from: inputs, options: options)
        var samples = [Double]()
        var outputShapes = [String]()
        for _ in 0..<count {
            let start = CFAbsoluteTimeGetCurrent()
            let prediction = try model.prediction(from: inputs, options: options)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            if outputShapes.isEmpty {
                for name in ["clip_0", "clip_1", "offset_map"] {
                    guard let a = prediction.featureValue(for: name)?.multiArrayValue else {
                        throw NSError(domain: "OSTrackBenchmark", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "缺少預期輸出：\(name)；實際輸出：\(prediction.featureNames.sorted())"])
                    }
                    outputShapes.append("\(name): \(a.shape)")
                }
            }
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let fps = 1000.0 / mean
        let report = "Model load: \(String(format: "%.2f", loadTime)) s\n" +
          "Compute: ALL (Core ML chooses device)\n" +
          "Warm-up: 1 (excluded)\n" +
          "Runs: \(count)\n" +
          "Mean: \(String(format: "%.1f", mean)) ms\n" +
          "Median: \(String(format: "%.1f", median)) ms\n" +
          "Min: \(String(format: "%.1f", sorted.first!)) ms\n" +
          "Max: \(String(format: "%.1f", sorted.last!)) ms\n" +
          "Estimated inference FPS: \(String(format: "%.2f", fps))\n" +
          outputShapes.joined(separator: "\n") +
          "\nDoes NOT include camera preprocessing, tracking postprocessing, or recording."
        return Result(fps: fps, report: report)
    }
}
