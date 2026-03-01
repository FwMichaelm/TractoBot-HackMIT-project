import Foundation
import SwiftUI
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    // UI state shown on the dashboard.
    @Published var gridPosition = GridPosition(row: 1, column: 1)
    @Published var thresholdPercent: Double = 80.0 // Adjust disease trigger threshold here.
    @Published var isAutoScanEnabled = false
    @Published var autoScanIntervalSeconds: Double = 2.0

    // Read-only status fields the UI listens to.
    @Published private(set) var lastResultText = "No scan yet"
    @Published private(set) var lastConfidenceText = "-"
    @Published private(set) var modeText = "Read-only dashboard mode"
    @Published private(set) var isBusy = false
    @Published private(set) var isRunComplete = false
    @Published private(set) var scannedPlantCount = 0
    @Published private(set) var isAwaitingMarkAck = false
    @Published private(set) var logs: [PlantScanLog] = []
    @Published private(set) var lastScanSampleCount = 0
    @Published private(set) var lastScanFrameAgeMs = 0
    @Published private(set) var gridResults: [GridPosition: ClassificationResult] = [:]

    // Core services used by the app.
    let cameraService = CameraService()
    let bluetooth = BluetoothManager()

    // Internal helpers and bookkeeping.
    private let logStore = ScanLogStore()
    private let classifier: PlantClassifier
    private let smoothingFrameCount = 5
    private let minimumFrameCount = 3
    private var autoScanTask: Task<Void, Never>?
    private var scannedPositions: Set<GridPosition> = []
    private var subscriptions = Set<AnyCancellable>()

    init() {
        // Load model + existing logs at startup.
        classifier = PlantClassifier()
        if classifier.isUsingDummyModel {
            lastResultText = "Dummy model active"
        }

        logs = logStore.loadAll()
        // Listen for Arduino status messages (MARKED/READY).
        bluetooth.$lastStatusMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleBluetoothStatus(status)
            }
            .store(in: &subscriptions)

        // Kick off camera permissions/session setup.
        cameraService.requestAndConfigure()
    }

    // Main toggle for autonomous scanning.
    func setAutoScan(_ enabled: Bool) {
        if enabled && isRunComplete {
            isAutoScanEnabled = false
            return
        }
        isAutoScanEnabled = enabled
        if enabled {
            startAutoScanLoop()
        } else {
            stopAutoScanLoop()
        }
    }

    // Runs one scan cycle using buffered camera frames.
    func runScan() {
        guard !isBusy else { return }
        guard !isAwaitingMarkAck else {
            lastResultText = "Waiting for marker ack"
            return
        }
        guard !isRunComplete else {
            lastResultText = "Run complete"
            return
        }
        guard cameraService.latestFrame != nil else {
            lastResultText = "No camera frame"
            return
        }

        isBusy = true
        cameraService.pauseFrameUpdates()
        let frozenFrames = cameraService.recentFrames(limit: smoothingFrameCount)
        let now = Date()
        let latestFrameTimestamp = cameraService.latestFrameTimestamp

        Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.cameraService.resumeFrameUpdates()
                    self.isBusy = false
                }
            }

            let framesToUse: [UIImage]
            if frozenFrames.count >= minimumFrameCount {
                framesToUse = frozenFrames
            } else if let single = await MainActor.run(body: { self.cameraService.latestFrame }) {
                framesToUse = [single]
            } else {
                await MainActor.run { self.lastResultText = "No camera frame" }
                return
            }

            await MainActor.run {
                self.lastScanSampleCount = framesToUse.count
                if let ts = latestFrameTimestamp {
                    self.lastScanFrameAgeMs = max(0, Int(now.timeIntervalSince(ts) * 1000))
                } else {
                    self.lastScanFrameAgeMs = 0
                }
            }

            do {
                let smoothed = try await self.classifySmoothed(frames: framesToUse, classifier: classifier)
                await MainActor.run {
                    self.handleClassification(smoothed)
                }
            } catch {
                await MainActor.run {
                    self.lastResultText = "Inference error: \(error.localizedDescription)"
                }
            }
        }
    }

    // Moves to the next grid spot in row-major order.
    func nextPlant() {
        gridPosition.advance(maxRows: 3, maxColumns: 3)
    }

    // Handles post-inference actions: log, send BLE command, and advance state.
    private func handleClassification(_ classification: ClassificationResult) {
        guard !scannedPositions.contains(gridPosition) else { return }

        lastResultText = classification.label.rawValue
        lastConfidenceText = String(format: "%.1f%%", classification.confidence * 100)
        gridResults[gridPosition] = classification
        scannedPositions.insert(gridPosition)
        scannedPlantCount = scannedPositions.count

        let shouldMark = classification.label == .diseased && (classification.confidence * 100) >= thresholdPercent
        if shouldMark {
            bluetooth.sendCommand("MARK")
            isAwaitingMarkAck = true
            modeText = "Marking diseased plant"
        } else {
            bluetooth.sendCommand("CLEAR")
        }

        let labelToken = classification.label.rawValue.uppercased()
        let resultLine = String(
            format: "RESULT,%d,%d,%@,%.1f",
            gridPosition.row,
            gridPosition.column,
            labelToken,
            classification.confidence * 100
        )
        bluetooth.sendCommand(resultLine)

        let log = PlantScanLog(
            position: gridPosition,
            result: classification.label,
            confidence: classification.confidence,
            timestamp: classification.timestamp
        )
        logs.insert(log, at: 0)
        logStore.append(log)

        if scannedPlantCount >= 9 {
            isRunComplete = true
            modeText = "Field complete"
            setAutoScan(false)
        } else if !shouldMark {
            nextPlant()
            modeText = "Read-only dashboard mode"
        }
    }

    // Smooths predictions across a handful of recent frames.
    private func classifySmoothed(frames: [UIImage], classifier: PlantClassifier) async throws -> ClassificationResult {
        var results: [ClassificationResult] = []
        results.reserveCapacity(frames.count)

        for frame in frames {
            let result = try await classifier.classify(image: frame)
            results.append(result)
        }

        guard !results.isEmpty else {
            throw NSError(domain: "AppViewModel", code: 10, userInfo: [NSLocalizedDescriptionKey: "No inference results"])
        }

        let healthyResults = results.filter { $0.label == .healthy }
        let diseasedResults = results.filter { $0.label == .diseased }
        let selectedLabel: PlantLabel

        if healthyResults.count == diseasedResults.count {
            let healthyAvg = healthyResults.isEmpty ? 0.0 : healthyResults.map(\.confidence).reduce(0, +) / Double(healthyResults.count)
            let diseasedAvg = diseasedResults.isEmpty ? 0.0 : diseasedResults.map(\.confidence).reduce(0, +) / Double(diseasedResults.count)
            selectedLabel = diseasedAvg > healthyAvg ? .diseased : .healthy
        } else {
            selectedLabel = diseasedResults.count > healthyResults.count ? .diseased : .healthy
        }

        let selected = results.filter { $0.label == selectedLabel }
        let avgConfidence = selected.map(\.confidence).reduce(0, +) / Double(selected.count)

        return ClassificationResult(label: selectedLabel, confidence: avgConfidence, timestamp: Date())
    }

    // UI-friendly quality summary for the last scan.
    var scanQualityText: String {
        guard lastScanSampleCount > 0 else { return "Scan Quality: -" }
        return "Scan Quality: \(lastScanSampleCount) samples, frame age \(lastScanFrameAgeMs) ms"
    }

    // BLE connection state shown in UI.
    var bluetoothStatusText: String {
        if bluetooth.isConnected {
            return "BLE connected"
        }
        return bluetooth.isBluetoothReady ? "BLE scanning" : "Bluetooth unavailable"
    }

    // Lookup helper for grid cell rendering.
    func classificationFor(row: Int, column: Int) -> ClassificationResult? {
        gridResults[GridPosition(row: row, column: column)]
    }

    // Progress label shown in dashboard.
    var progressText: String {
        "Progress: \(scannedPlantCount)/9"
    }

    // Resets run-specific state for a fresh 3x3 pass.
    func startNewRun() {
        setAutoScan(false)
        gridPosition = GridPosition(row: 1, column: 1)
        gridResults.removeAll()
        scannedPositions.removeAll()
        scannedPlantCount = 0
        isRunComplete = false
        isAwaitingMarkAck = false
        modeText = "Read-only dashboard mode"
        lastResultText = "No scan yet"
        lastConfidenceText = "-"
        lastScanSampleCount = 0
        lastScanFrameAgeMs = 0
    }

    // Background loop that triggers scans on the chosen interval.
    private func startAutoScanLoop() {
        autoScanTask?.cancel()
        autoScanTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await MainActor.run {
                    if self.isAutoScanEnabled && !self.isBusy && !self.isAwaitingMarkAck {
                        self.runScan()
                    }
                }

                let interval = await MainActor.run { self.autoScanIntervalSeconds }
                let safeInterval = max(0.5, interval)
                try? await Task.sleep(nanoseconds: UInt64(safeInterval * 1_000_000_000))
            }
        }
    }

    // Stops the autonomous loop cleanly.
    private func stopAutoScanLoop() {
        autoScanTask?.cancel()
        autoScanTask = nil
    }

    // Unblocks movement once Arduino confirms marking is done.
    private func handleBluetoothStatus(_ status: String) {
        guard isAwaitingMarkAck else { return }
        let upper = status.uppercased()
        if upper == "MARKED" || upper == "READY" {
            isAwaitingMarkAck = false
            if !isRunComplete {
                nextPlant()
                modeText = "Read-only dashboard mode"
            }
        }
    }
}
