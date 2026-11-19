import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum ImageUtils {
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Returns an upright CGImage (applies EXIF orientation) scaled so the long edge ≤ maxEdge.
    static func normalized(_ image: UIImage, maxEdge: CGFloat = 4000) -> CGImage? {
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.cgImage
    }

    static func scaled(_ cg: CGImage, maxEdge: CGFloat) -> CGImage {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxEdge / max(w, h))
        guard scale < 1 else { return cg }
        let target = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: target))
        }
        return img.cgImage ?? cg
    }

    static func jpegData(_ cg: CGImage, quality: CGFloat = 0.82) -> Data? {
        UIImage(cgImage: cg).jpegData(compressionQuality: quality)
    }

    /// Crops a normalized (top-left origin) rect out of an image.
    static func crop(_ cg: CGImage, normalized r: CGRect) -> CGImage? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let px = CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h)
            .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard px.width >= 1, px.height >= 1 else { return nil }
        return cg.cropping(to: px)
    }

    /// Average color of a normalized region, as a hex string. Samples the central part of
    /// the region to avoid shelf edges and neighbouring spines.
    static func averageColorHex(_ cg: CGImage, normalized r: CGRect) -> String? {
        let inset = r.insetBy(dx: r.width * 0.2, dy: r.height * 0.15)
        guard let crop = crop(cg, normalized: inset) else { return nil }
        let input = CIImage(cgImage: crop)
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &px, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return String(format: "#%02X%02X%02X", px[0], px[1], px[2])
    }

    /// Splits a wide image into overlapping tiles no wider than `maxAspect` × height,
    /// so that spines stay legible after the vision model downsamples each tile.
    /// Returns tiles with their normalized x-range in the source image.
    static func horizontalTiles(_ cg: CGImage, maxAspect: CGFloat = 1.6, overlap: CGFloat = 0.12)
        -> [(image: CGImage, x0: CGFloat, x1: CGFloat)] {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let tileW = min(w, h * maxAspect)
        guard tileW < w * 0.98 else { return [(cg, 0, 1)] }
        let step = tileW * (1 - overlap)
        var tiles: [(image: CGImage, x0: CGFloat, x1: CGFloat)] = []
        var x: CGFloat = 0
        while true {
            let start = min(x, w - tileW)
            if let t = cg.cropping(to: CGRect(x: start, y: 0, width: tileW, height: h).integral) {
                tiles.append((t, start / w, (start + tileW) / w))
            }
            if start + tileW >= w - 1 { break }
            x += step
        }
        return tiles
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
