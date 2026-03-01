import SwiftUI

struct ContentView: View {
    // Single source of truth for dashboard state + actions.
    @StateObject private var vm = AppViewModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 10) {
                    // Live camera feed.
                    CameraPreviewView(session: vm.cameraService.session)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                        )

                    // 3x3 field map showing current and completed classifications.
                    GroupBox("Live Grid") {
                        VStack(spacing: 8) {
                            ForEach(1...3, id: \.self) { row in
                                HStack(spacing: 8) {
                                    ForEach(1...3, id: \.self) { column in
                                        let result = vm.classificationFor(row: row, column: column)
                                        GridCellView(
                                            row: row,
                                            column: column,
                                            result: result,
                                            isCurrent: vm.gridPosition.row == row && vm.gridPosition.column == column
                                        )
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Current plant status + BLE/scan diagnostics.
                    GroupBox("Plant Status") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Grid: \(vm.gridPosition.label)")
                            Text(vm.progressText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(vm.modeText)
                            .foregroundColor(.secondary)
                            Text("Result: \(vm.lastResultText)")
                            Text("Confidence: \(vm.lastConfidenceText)")
                            Text(vm.scanQualityText)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("BLE: \(vm.bluetoothStatusText)")
                                .font(.caption2)
                                .foregroundColor(vm.bluetooth.isConnected ? .green : .secondary)
                            Text("Arduino RX: \(vm.bluetooth.lastStatusMessage.isEmpty ? "-" : vm.bluetooth.lastStatusMessage)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Controls for auto loop, one-shot scan, and run reset.
                    GroupBox("Autonomous Scan") {
                        VStack(spacing: 10) {
                            if vm.isRunComplete {
                                Text("Field complete (9/9)")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }

                            Toggle("Auto Scan", isOn: Binding(
                                get: { vm.isAutoScanEnabled },
                                set: { vm.setAutoScan($0) }
                            ))
                            .disabled(vm.isRunComplete)

                            HStack {
                                Text("Interval")
                                Spacer()
                                Text(String(format: "%.1fs", vm.autoScanIntervalSeconds))
                            }
                            Slider(value: $vm.autoScanIntervalSeconds, in: 0.5...5.0, step: 0.5)

                            HStack {
                                Text("Disease Threshold")
                                Spacer()
                                Text(String(format: "%.0f%%", vm.thresholdPercent))
                            }
                            Slider(value: $vm.thresholdPercent, in: 50...99, step: 1)

                            Button(vm.isBusy ? "Scanning..." : "Scan Once") {
                                vm.runScan()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(vm.isBusy || vm.isRunComplete)

                            Button("New Run") {
                                vm.startNewRun()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // Most recent persisted scan entries.
                    GroupBox("Recent Logs") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(vm.logs.prefix(6)), id: \.id) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(entry.position.label): \(entry.result.rawValue) (\(Int(entry.confidence * 100))%)")
                                    Text(entry.timestamp.formatted(date: .numeric, time: .standard))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            if vm.logs.isEmpty {
                                Text("No scans yet")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .navigationTitle("TractoBot Dashboard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct GridCellView: View {
    let row: Int
    let column: Int
    let result: ClassificationResult?
    let isCurrent: Bool

    // Color code: green=healthy, red=diseased, gray=pending.
    private var bgColor: Color {
        guard let result else { return Color.gray.opacity(0.18) }
        return result.label == .diseased ? Color.red.opacity(0.75) : Color.green.opacity(0.65)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("R\(row)C\(column)")
                .font(.caption)
                .bold()
            Text(result?.label.rawValue ?? "Pending")
                .font(.caption2)
            if let result {
                Text("\(Int(result.confidence * 100))%")
                    .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 68)
        .padding(.vertical, 4)
        .background(bgColor)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isCurrent ? Color.blue : Color.clear, lineWidth: 2)
        )
    }
}
