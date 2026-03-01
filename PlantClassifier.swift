import Foundation
import Vision
import CoreML
import UIKit

final class PlantClassifier {
    // Vision-wrapped CoreML model used for live classification.
    private let model: VNCoreMLModel?
    let isUsingDummyModel: Bool

    init() {
        // Looks for compiled model in app bundle.
        // Xcode builds .mlmodel/.mlpackage into .mlmodelc automatically.
        guard let modelURL = Bundle.main.url(forResource: "PlantDiseaseClassifier", withExtension: "mlmodelc"),
              let bundleModel = try? MLModel(contentsOf: modelURL),
              let vnModel = try? VNCoreMLModel(for: bundleModel) else {
            model = nil
            isUsingDummyModel = true
            return
        }

        model = vnModel
        isUsingDummyModel = false
    }

    // Callback-based classifier API used by the async wrapper below.
    func classify(image: UIImage, completion: @escaping (Result<ClassificationResult, Error>) -> Void) {
        guard let cgImage = image.cgImage else {
            completion(.failure(NSError(domain: "PlantClassifier", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid image"])))
            return
        }

        // Fallback for development if the model is missing.
        guard let model else {
            completion(.success(dummyClassification(for: image)))
            return
        }

        let request = VNCoreMLRequest(model: model) { request, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let observations = request.results as? [VNClassificationObservation],
                  let top = observations.first else {
                completion(.failure(NSError(domain: "PlantClassifier", code: 3, userInfo: [NSLocalizedDescriptionKey: "No classification result"])))
                return
            }

            let identifier = top.identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let label: PlantLabel = identifier.contains("diseas") ? .diseased : .healthy

            let result = ClassificationResult(label: label, confidence: Double(top.confidence), timestamp: Date())
            completion(.success(result))
        }
        // Matches most image classifiers trained at fixed center-cropped size.
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                completion(.failure(error))
            }
        }
    }

    // Async-friendly API used by AppViewModel.
    func classify(image: UIImage) async throws -> ClassificationResult {
        try await withCheckedThrowingContinuation { continuation in
            classify(image: image) { result in
                continuation.resume(with: result)
            }
        }
    }

    // Deterministic fake result so the app remains testable without model.
    private func dummyClassification(for image: UIImage) -> ClassificationResult {
        let seed = Int(image.size.width + image.size.height)
        let label: PlantLabel = (seed % 5 == 0) ? .diseased : .healthy
        let confidence: Double = label == .diseased ? 0.84 : 0.72
        return ClassificationResult(label: label, confidence: confidence, timestamp: Date())
    }
}
