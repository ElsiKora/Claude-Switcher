// Renders docs/assets/logo.png: swiftc -O scripts/render-logo.swift -o /tmp/render-logo && /tmp/render-logo docs/assets/logo.png
import AppKit
import SwiftUI

// Claude Switcher logo in the ElsiKora layout: dark tile with the glyph,
// the name in a purple-to-magenta gradient, a gradient rule below, on a
// transparent background so it sits on GitHub's light and dark themes.
let purple = Color(red: 0.45, green: 0.07, blue: 0.83)
let magenta = Color(red: 0.82, green: 0.11, blue: 0.78)
let gradient = LinearGradient(colors: [purple, magenta], startPoint: .bottomLeading, endPoint: .topTrailing)

struct Glyph: View {
    var body: some View {
        ZStack {
            Circle().trim(from: 0.0, to: 0.80)
                .stroke(gradient, style: StrokeStyle(lineWidth: 34, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 236, height: 236)
            Circle().trim(from: 0.0, to: 0.58)
                .stroke(gradient, style: StrokeStyle(lineWidth: 34, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 140, height: 140)
            Circle().fill(gradient).frame(width: 40, height: 40)
        }
    }
}

struct Logo: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            HStack(spacing: 90) {
                RoundedRectangle(cornerRadius: 56, style: .continuous)
                    .fill(Color(white: 0.12))
                    .frame(width: 540, height: 540)
                    .overlay(Glyph())
                VStack(alignment: .leading, spacing: -24) {
                    Text("CLAUDE")
                    Text("SWITCHER")
                }
                .font(.system(size: 190, weight: .heavy))
                .foregroundStyle(LinearGradient(colors: [magenta, purple], startPoint: .top, endPoint: .bottom))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 80)
            HStack(spacing: 0) {
                Rectangle().fill(purple)
                Rectangle().fill(magenta)
            }
            .frame(height: 14)
            .padding(.horizontal, 24)
            .padding(.bottom, 52)
        }
        .frame(width: 1920, height: 1080)
    }
}

@MainActor func render() {
    let r = ImageRenderer(content: Logo())
    r.scale = 1
    guard let cg = r.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
MainActor.assumeIsolated { render() }
