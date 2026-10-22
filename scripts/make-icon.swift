// Renders Resources/AppIcon.icns. Usage: swift scripts/make-icon.swift [output.icns] [preview.png]
import AppKit
import SwiftUI

struct AppIcon: View {
    private let canvas: CGFloat = 1024
    private let squircleSize: CGFloat = 824
    private let dialRadius: CGFloat = 238
    private let lineWidth: CGFloat = 70
    private let elapsedFraction = 0.72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.49, green: 0.47, blue: 0.98), Color(red: 0.27, green: 0.24, blue: 0.80)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(RadialGradient(
                            colors: [.white.opacity(0.28), .clear],
                            center: UnitPoint(x: 0.3, y: 0.08), startRadius: 0, endRadius: 620
                        ))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 3)
                )
                .frame(width: squircleSize, height: squircleSize)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

            dial
        }
        .frame(width: canvas, height: canvas)
    }

    private var dial: some View {
        let endAngle = Angle.degrees(-90 + 360 * elapsedFraction)
        return ZStack {
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: elapsedFraction)
                .stroke(
                    AngularGradient(
                        colors: [.white.opacity(0.55), .white],
                        center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * elapsedFraction)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(Color(red: 1.0, green: 0.84, blue: 0.55))
                .frame(width: lineWidth * 0.52, height: lineWidth * 0.52)
                .shadow(color: Color(red: 1.0, green: 0.8, blue: 0.5).opacity(0.9), radius: 14)
                .offset(x: dialRadius * cos(endAngle.radians), y: dialRadius * sin(endAngle.radians))
        }
        .frame(width: dialRadius * 2, height: dialRadius * 2)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
    }
}

let arguments = CommandLine.arguments
let outputICNS = arguments.count > 1 ? arguments[1] : "Resources/AppIcon.icns"
let previewPNG = arguments.count > 2 ? arguments[2] : nil

let master: CGImage = MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: AppIcon())
    renderer.scale = 1
    guard let image = renderer.cgImage else { fatalError("Icon render failed") }
    return image
}

func png(_ image: CGImage, size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: image, size: NSSize(width: 1024, height: 1024)).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(master, size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(master, size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if let previewPNG {
    try png(master, size: 1024).write(to: URL(fileURLWithPath: previewPNG))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputICNS]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(outputICNS)")
