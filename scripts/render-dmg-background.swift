// Renders the DMG window background at 1x and 2x:
// swiftc -O scripts/render-dmg-background.swift -o /tmp/render-dmg && /tmp/render-dmg docs/dmg
// Icons sit at (170, 200) and (490, 200) in a 660 x 400 window; scripts/dmg-settings.py places them.
import AppKit
import SwiftUI

let purple = Color(red: 0.45, green: 0.07, blue: 0.83)
let magenta = Color(red: 0.82, green: 0.11, blue: 0.78)
let gradient = LinearGradient(colors: [purple, magenta], startPoint: .leading, endPoint: .trailing)

struct Arrow: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - 4, y: r.midY))
        p.move(to: CGPoint(x: r.maxX - 22, y: r.midY - 16))
        p.addLine(to: CGPoint(x: r.maxX - 4, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX - 22, y: r.midY + 16))
        return p
    }
}

struct Background: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.99), Color(white: 0.95)], startPoint: .top, endPoint: .bottom)
            Text("CLAUDE SWITCHER")
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(gradient)
                .padding(.top, 34)
            Arrow()
                .stroke(gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                .frame(width: 150, height: 40)
                .position(x: 330, y: 200)
            Text("Drag Claude Switcher into Applications")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(white: 0.42))
                .position(x: 330, y: 318)
            HStack(spacing: 0) {
                Rectangle().fill(purple)
                Rectangle().fill(magenta)
            }
            .frame(height: 5)
            .padding(.horizontal, 24)
            .position(x: 330, y: 372)
        }
        .frame(width: 660, height: 400)
    }
}

@MainActor func write(scale: CGFloat, to url: URL) {
    let r = ImageRenderer(content: Background())
    r.scale = scale
    guard let cg = r.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: 660, height: 400)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
MainActor.assumeIsolated {
    write(scale: 1, to: dir.appending(path: "background.png"))
    write(scale: 2, to: dir.appending(path: "background@2x.png"))
}
