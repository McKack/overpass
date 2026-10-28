// Renders Support/AppIcon.svg into Support/AppIcon.icns. Run: swift scripts/make-icon.swift (from src/).
// WebKit does the rendering: NSImage's SVG renderer leaves notches where wide round-joined strokes
// turn tight corners, and Quick Look flattens onto white, which makes macOS box the icon in a tile.
import AppKit
import WebKit

let svg = URL(fileURLWithPath: "Support/AppIcon.svg").absoluteURL
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("overpass-icon")
let iconset = tmp.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: tmp)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    var done: ((NSImage) -> Void)?

    func render(_ svg: URL, _ done: @escaping (NSImage) -> Void) {
        self.done = done
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        // Inlined: a page loaded from a string may not read file URLs.
        var markup = try! String(contentsOf: svg, encoding: .utf8)
        if let start = markup.range(of: "<svg") { markup = String(markup[start.lowerBound...]) }
        let html = "<html><body style='margin:0;background:transparent'><div style='width:1024px;height:1024px'>\(markup)</div></body></html>"
        web.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 1024
        webView.takeSnapshot(with: config) { image, error in
            guard let image else { fatalError("Snapshot failed: \(String(describing: error))") }
            self.done?(image)
        }
    }
}

func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    try! p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

let renderer = Renderer()
renderer.render(svg) { image in
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = points * scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
        }
    }
    let status = run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"])
    print(status == 0 ? "Wrote Support/AppIcon.icns" : "iconutil failed")
    exit(status)
}
RunLoop.main.run()
