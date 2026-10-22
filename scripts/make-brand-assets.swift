// Renders the app icon and README/social branding. Run from the repo root: swift scripts/make-brand-assets.swift
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

struct SocialPreview: View {
    var body: some View {
        HStack(spacing: 44) {
            AppIcon()
                .scaleEffect(0.38)
                .frame(width: 390, height: 390)
            VStack(alignment: .leading, spacing: 18) {
                Text("MindfulHours")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                Text("Know where your hours go.")
                    .font(.system(size: 46, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                Text("A privacy-first activity journal for macOS")
                    .font(.system(size: 32, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 60)
        .frame(width: 1280, height: 640)
        .background(
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.14, blue: 0.42), Color(red: 0.08, green: 0.07, blue: 0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    }
}

@MainActor func render<V: View>(_ view: V) -> CGImage {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let image = renderer.cgImage else { fatalError("Render failed for \(V.self)") }
    return image
}

func png(_ image: CGImage, width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let (icon, socialPreview) = MainActor.assumeIsolated { (render(AppIcon()), render(SocialPreview())) }

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(icon, width: points, height: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(icon, width: points * 2, height: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

try FileManager.default.createDirectory(atPath: "docs/assets", withIntermediateDirectories: true)
try png(icon, width: 512, height: 512).write(to: URL(fileURLWithPath: "docs/assets/icon.png"))
try png(socialPreview, width: 1280, height: 640).write(to: URL(fileURLWithPath: "docs/assets/social-preview.png"))
print("Wrote Resources/AppIcon.icns, docs/assets/icon.png, docs/assets/social-preview.png")
