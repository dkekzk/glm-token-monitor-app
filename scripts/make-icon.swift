#!/usr/bin/env swift
// Generate AppIcon.icns from a SwiftUI view.
// Usage: swift scripts/make-icon.swift

import AppKit
import SwiftUI

// MARK: - Icon design

struct IconView: View {
    var body: some View {
        ZStack {
            // Rounded-square "squircle" background with GLM gradient
            RoundedRectangle(cornerRadius: 180, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.40, blue: 0.96),
                            Color(red: 0.06, green: 0.76, blue: 0.72),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Top-left highlight
            RoundedRectangle(cornerRadius: 180, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 8)

            // Gauge needle glyph — rendered with paths for independence from SF Symbol availability
            ZStack {
                // Dial arc
                ArcShape(startAngle: .degrees(150), endAngle: .degrees(30))
                    .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 56, lineCap: .round))
                    .frame(width: 620, height: 620)

                // Tick marks
                ForEach(0 ..< 7) { i in
                    Rectangle()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 16, height: 44)
                        .offset(y: -300)
                        .rotationEffect(.degrees(Double(i) * 40 - 120))
                }
                .frame(width: 620, height: 620)

                // Needle pointing to ~70%
                Needle()
                    .fill(Color.white)
                    .frame(width: 620, height: 620)
                    .rotationEffect(.degrees(42)) // 0 deg = up; +42 deg = right-of-center
                    .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 12)

                // Center cap
                Circle()
                    .fill(Color.white)
                    .frame(width: 96, height: 96)
                    .overlay(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.12, green: 0.40, blue: 0.96),
                                        Color(red: 0.06, green: 0.76, blue: 0.72),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 38, height: 38)
                    )
            }
            .offset(y: 40)
        }
        .frame(width: 1024, height: 1024)
    }
}

struct ArcShape: Shape {
    var startAngle: Angle
    var endAngle: Angle
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2 - 40,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return p
    }
}

struct Needle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cx = rect.midX
        let cy = rect.midY
        let tipY = cy - (rect.height / 2 - 110)
        let baseY = cy + 40
        p.move(to: CGPoint(x: cx - 14, y: baseY))
        p.addLine(to: CGPoint(x: cx + 14, y: baseY))
        p.addLine(to: CGPoint(x: cx + 4, y: tipY + 20))
        p.addLine(to: CGPoint(x: cx, y: tipY))
        p.addLine(to: CGPoint(x: cx - 4, y: tipY + 20))
        p.closeSubpath()
        return p
    }
}

// MARK: - Rasterization

@MainActor
func renderIcon(size: CGFloat) -> NSImage? {
    let renderer = ImageRenderer(content: IconView().frame(width: size, height: size))
    renderer.scale = 1.0
    guard let cg = renderer.cgImage else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
}

func savePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "iconmaker", code: 1)
    }
    try data.write(to: url)
}

// MARK: - Main

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// macOS .iconset required sizes
let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// Render the master 1024 once
guard let master = await renderIcon(size: 1024) else {
    fatalError("Failed to render master image")
}

for (name, size) in sizes {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    master.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    img.unlockFocus()
    let url = iconset.appendingPathComponent(name)
    try savePNG(img, to: url)
    print("Wrote \(name)")
}

// Convert iconset → icns
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print("Created AppIcon.icns")
