// Renders the frosted banner for an update post to build/banner-<version>.png. Run: swift scripts/make-banner.swift [version] (from src/).
// The version defaults to Support/Info.plist's. The logo and name stay in the middle 700 of the 1600 wide strip, so a
// site that crops the strip to a social preview's shape (about 1.91:1) keeps them.
import AppKit
import WebKit

let width = 1600, height = 400
let info = NSDictionary(contentsOfFile: "Support/Info.plist")
let shown = CommandLine.arguments.dropFirst().first ?? info?["CFBundleShortVersionString"] as? String ?? "?"
var logo = try String(contentsOfFile: "Sources/OverPass/Logos/overpass.svg", encoding: .utf8)
if let start = logo.range(of: "<svg") { logo = String(logo[start.lowerBound...]) }

let html = """
<html><head><style>
  * { margin: 0; box-sizing: border-box; }
  html, body { width: \(width)px; height: \(height)px; overflow: hidden; background: #26262a; }
  .glow { position: absolute; border-radius: 50%; filter: blur(90px); }
  .glass { position: absolute; inset: 0; background: linear-gradient(180deg, rgba(255,255,255,.075), rgba(255,255,255,.015) 45%, rgba(0,0,0,.14));
           box-shadow: inset 0 1px 0 rgba(255,255,255,.14), inset 0 -1px 0 rgba(0,0,0,.3); }
  .grain { position: absolute; inset: 0; opacity: .1; mix-blend-mode: overlay; }
  .brand { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; gap: 28px; color: #f5f5f7;
           font-family: ui-rounded, -apple-system; }
  .brand svg { width: 124px; height: 124px; display: block; }
  .name { font-size: 96px; font-weight: 700; letter-spacing: -.5px; display: flex; align-items: baseline; gap: 18px; }
  .version { font-size: 34px; font-weight: 500; letter-spacing: 0; color: rgba(245,245,247,.42); }
</style></head><body>
  <div class="glow" style="left:90px;top:-150px;width:560px;height:430px;background:#e9843a;opacity:.13"></div>
  <div class="glow" style="right:110px;top:90px;width:620px;height:460px;background:#3f7fd6;opacity:.2"></div>
  <div class="glass"></div>
  <svg class="grain" width="\(width)" height="\(height)"><filter id="n"><feTurbulence type="fractalNoise" baseFrequency="1.1" numOctaves="2"/></filter>
    <rect width="100%" height="100%" filter="url(#n)"/></svg>
  <div class="brand">\(logo)<div class="name">OverPass<span class="version">v\(shown)</span></div></div>
</body></html>
"""

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: width)
        webView.takeSnapshot(with: config) { image, error in
            guard let image else { fatalError("Snapshot failed: \(String(describing: error))") }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            let out = "build/banner-\(shown).png"
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
            print(out)
            exit(0)
        }
    }
}

let renderer = Renderer()
renderer.web.navigationDelegate = renderer
renderer.web.loadHTMLString(html, baseURL: nil)
RunLoop.main.run()
