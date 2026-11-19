import AVFoundation
import Vision
import UIKit

/// Turns a slow horizontal pan along a shelf into a single panoramic image.
///
/// Frames are sampled from the video, aligned with Vision's translational image registration,
/// and composited onto one wide canvas. Best results come from holding the phone level and
/// walking or sliding steadily along the shelf at a constant distance.
enum VideoStitcher {
    enum StitchError: LocalizedError {
        case noFrames
        var errorDescription: String? { "Couldn't read frames from that video." }
    }

    static func panorama(from url: URL, frameInterval: Double = 0.4, frameHeight: CGFloat = 1400) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        var frames: [CGImage] = []
        var t = 0.0
        while t < max(duration, 0.01) {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                let img = result.image
                frames.append(ImageUtils.scaled(img, maxEdge: max(frameHeight, CGFloat(img.width) * frameHeight / CGFloat(img.height))))
            }
            t += frameInterval
        }
        guard let first = frames.first else { throw StitchError.noFrames }
        if frames.count == 1 { return first }

        // Measure raw shifts between consecutive frames.
        var raw: [(frame: CGImage, shift: CGPoint)] = []
        var prev = first
        for frame in frames.dropFirst() {
            guard let shift = translation(from: prev, to: frame) else { continue }
            // Skip frames that barely moved; they add nothing but blur.
            if abs(shift.x) < CGFloat(frame.width) * 0.04 { continue }
            raw.append((frame, shift))
            prev = frame
        }
        guard !raw.isEmpty else { return first }

        // Vision's sign convention for the alignment transform is easy to get backwards, so decide
        // it empirically: whichever sign makes the first overlapping pair line up better wins.
        let sign: CGFloat = {
            let a = Gray(first), b = Gray(raw[0].frame), s = raw[0].shift
            return a.error(against: b, dx: s.x, dy: s.y) <= a.error(against: b, dx: -s.x, dy: -s.y) ? 1 : -1
        }()

        var offsets: [CGPoint] = [.zero]
        var kept: [CGImage] = [first]
        for (frame, shift) in raw {
            let last = offsets.last!
            offsets.append(CGPoint(x: last.x + sign * shift.x, y: last.y + sign * shift.y))
            kept.append(frame)
        }
        // Offsets encode real positions, so a right-to-left pan still produces a left-to-right panorama.

        let minX = offsets.map(\.x).min()!, maxX = offsets.map(\.x).max()!
        let minY = offsets.map(\.y).min()!, maxY = offsets.map(\.y).max()!
        let fw = CGFloat(first.width), fh = CGFloat(first.height)
        var canvas = CGSize(width: maxX - minX + fw, height: maxY - minY + fh)
        // Keep the panorama within a sane pixel budget.
        let maxWidth: CGFloat = 12000
        let scale = min(1, maxWidth / canvas.width)
        canvas = CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            for (frame, offset) in zip(kept, offsets) {
                // Vision offsets use a bottom-left origin; UIKit drawing uses top-left.
                let x = (offset.x - minX) * scale
                let y = (maxY - offset.y) * scale
                UIImage(cgImage: frame).draw(in: CGRect(x: x, y: y, width: fw * scale, height: fh * scale))
            }
        }
        guard let cg = image.cgImage else { throw StitchError.noFrames }
        return cg
    }

    /// Shift of `next` relative to `reference` reported by Vision, in pixels (bottom-left origin).
    private static func translation(from reference: CGImage, to next: CGImage) -> CGPoint? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: next)
        let handler = VNImageRequestHandler(cgImage: reference)
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
        return CGPoint(x: obs.alignmentTransform.tx, y: obs.alignmentTransform.ty)
    }

    /// Small grayscale copy of a frame, used to check alignment direction.
    private struct Gray {
        let w = 96
        let h: Int
        let scale: CGFloat
        var px: [UInt8]

        init(_ cg: CGImage) {
            scale = CGFloat(96) / CGFloat(cg.width)
            h = max(1, Int(CGFloat(cg.height) * scale))
            var buffer = [UInt8](repeating: 0, count: 96 * h)
            let height = h
            buffer.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: 96, height: height, bitsPerComponent: 8,
                                    bytesPerRow: 96, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
                ctx?.interpolationQuality = .medium
                ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: 96, height: height))
            }
            px = buffer
        }

        /// Mean absolute difference over the overlap when `other` is placed at (dx, dy) full-res pixels
        /// (bottom-left origin) relative to self.
        func error(against other: Gray, dx: CGFloat, dy: CGFloat) -> Double {
            let ox = Int((dx * scale).rounded()), oy = Int((dy * scale).rounded())
            var total = 0, count = 0
            // Bitmap memory rows run top-down, so the row index is y measured from the top.
            for y in 0..<h {
                let sy = y - oy   // positive dy (up) moves to a smaller row index
                guard sy >= 0, sy < h else { continue }
                for x in 0..<w {
                    let sx = x + ox
                    guard sx >= 0, sx < w else { continue }
                    total += abs(Int(px[sy * w + sx]) - Int(other.px[y * w + x]))
                    count += 1
                }
            }
            return count > w * h / 8 ? Double(total) / Double(count) : .greatestFiniteMagnitude
        }
    }
}
