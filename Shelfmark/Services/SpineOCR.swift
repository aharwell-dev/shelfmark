import Vision
import CoreGraphics

/// On-device text recognition used as a "hint layer" for the vision model.
/// Spine lettering usually runs vertically, so the image is read three ways:
/// upright, rotated clockwise, and rotated counter-clockwise.
enum SpineOCR {
    struct Fragment: Hashable {
        let text: String
        /// Approximate horizontal center in the upright image, 0–1.
        let x: Double
    }

    static func recognize(in image: CGImage) async -> [Fragment] {
        await withTaskGroup(of: [Fragment].self) { group in
            for orientation in [CGImagePropertyOrientation.up, .right, .left] {
                group.addTask { recognize(image, orientation: orientation) }
            }
            var all: [Fragment] = []
            for await part in group { all.append(contentsOf: part) }
            // De-duplicate by text, keep left-to-right order.
            var seen = Set<String>()
            return all.sorted { $0.x < $1.x }.filter { seen.insert($0.text.lowercased()).inserted }
        }
    }

    private static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation) -> [Fragment] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.01
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        do { try handler.perform([request]) } catch { return [] }
        let observations = request.results ?? []
        return observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first, candidate.confidence > 0.35 else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { return nil }
            // Bounding boxes are in the oriented image's normalized space (origin bottom-left).
            // Map the box center back to an x position in the upright image.
            let c = CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY)
            let x: Double
            switch orientation {
            case .right: x = 1 - c.y     // rotated 90° CW for reading
            case .left:  x = c.y         // rotated 90° CCW for reading
            default:     x = c.x
            }
            return Fragment(text: text, x: x)
        }
    }
}
