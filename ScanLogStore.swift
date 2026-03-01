import Foundation

// Tiny file-backed store for scan history.
final class ScanLogStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(filename: String = "plant_scan_logs.json") {
        // Save in app Documents so logs persist between launches.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent(filename)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    // Appends one entry and rewrites the JSON file atomically.
    func append(_ entry: PlantScanLog) {
        var all = loadAll()
        all.append(entry)
        do {
            let data = try encoder.encode(all)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to persist logs: \(error)")
        }
    }

    // Loads all logs; returns empty if file is missing/corrupt.
    func loadAll() -> [PlantScanLog] {
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([PlantScanLog].self, from: data)
        } catch {
            return []
        }
    }

    // Useful when you need to inspect the JSON on device/simulator.
    var pathDescription: String {
        fileURL.path
    }
}
