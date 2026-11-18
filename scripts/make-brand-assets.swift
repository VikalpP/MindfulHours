// Builds the app icon set and README/social branding from Resources/AppIcon.png. Run from the repo root: swift scripts/make-brand-assets.swift
import AppKit
import SwiftUI

let iconMasterPath = "Resources/AppIcon.png"
guard let iconMaster = NSImage(contentsOfFile: iconMasterPath),
      let icon = iconMaster.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Missing \(iconMasterPath): the 1024×1024 app icon master")
}

struct SocialPreview: View {
    let icon: NSImage

    var body: some View {
        HStack(spacing: 44) {
            Image(nsImage: icon)
                .resizable()
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

let socialPreview = MainActor.assumeIsolated { render(SocialPreview(icon: iconMaster)) }

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
