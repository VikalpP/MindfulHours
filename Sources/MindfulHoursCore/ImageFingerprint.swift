import CoreGraphics

/// 64-bit difference hash: visually similar screenshots produce hashes a few bits apart.
public struct ImageFingerprint: Hashable, Sendable {
    public let bits: UInt64

    public init(bits: UInt64) {
        self.bits = bits
    }

    public init?(image: CGImage) {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var bits: UInt64 = 0
        for row in 0..<height {
            for column in 0..<(width - 1) {
                bits <<= 1
                if pixels[row * width + column] > pixels[row * width + column + 1] { bits |= 1 }
            }
        }
        self.bits = bits
    }

    public func distance(to other: ImageFingerprint) -> Int {
        (bits ^ other.bits).nonzeroBitCount
    }
}
