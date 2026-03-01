import Foundation

// Logical position in the 3x3 field grid.
struct GridPosition: Codable, Equatable, Hashable {
    var row: Int
    var column: Int

    // Advances row-by-row and wraps at the end.
    mutating func advance(maxRows: Int = 3, maxColumns: Int = 3) {
        column += 1
        if column > maxColumns {
            column = 1
            row += 1
            if row > maxRows {
                row = 1
            }
        }
    }

    var label: String {
        "Row \(row), Col \(column)"
    }
}

// Class labels expected from the model.
enum PlantLabel: String, Codable {
    case healthy = "Healthy"
    case diseased = "Diseased"
}

// Single inference result for one frame or smoothed frame set.
struct ClassificationResult: Codable {
    let label: PlantLabel
    let confidence: Double
    let timestamp: Date
}

// Persisted record for one scanned plant cell.
struct PlantScanLog: Codable {
    let id: UUID
    let position: GridPosition
    let result: PlantLabel
    let confidence: Double
    let timestamp: Date

    init(id: UUID = UUID(), position: GridPosition, result: PlantLabel, confidence: Double, timestamp: Date) {
        self.id = id
        self.position = position
        self.result = result
        self.confidence = confidence
        self.timestamp = timestamp
    }

    // Decode older log files that might not have an ID.
    enum CodingKeys: String, CodingKey {
        case id
        case position
        case result
        case confidence
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        position = try container.decode(GridPosition.self, forKey: .position)
        result = try container.decode(PlantLabel.self, forKey: .result)
        confidence = try container.decode(Double.self, forKey: .confidence)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }
}
