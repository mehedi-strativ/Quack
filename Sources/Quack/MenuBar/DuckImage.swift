import AppKit

/// Renders the duck silhouette to a template `NSImage` using AppKit directly.
/// (`ImageRenderer` doesn't reliably rasterize a SwiftUI `Canvas`, which left
/// the menu-bar item blank.)
enum DuckImage {
    // viewBox 127 × 100 from the source SVG.
    private static let viewBox = CGSize(width: 127, height: 100)

    static func template(height: CGFloat = 17) -> NSImage {
        let scale = height / viewBox.height
        let w = viewBox.width * scale, h = viewBox.height * scale

        // SVG is Y-down; AppKit drawing is Y-up — flip Y into the image.
        let path = bezierPath(from: duckPathData) { p in
            CGPoint(x: p.x * scale, y: h - p.y * scale)
        }

        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        NSColor.black.setFill()
        path.fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static let numberRegex = try! NSRegularExpression(
        pattern: #"-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?"#
    )

    private static func numbers(_ s: String) -> [CGFloat] {
        let ns = s as NSString
        return numberRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .compactMap { Double(ns.substring(with: $0.range)).map { CGFloat($0) } }
    }

    /// Parses M/L/C/Z (absolute) — all the duck path uses — into an NSBezierPath,
    /// transforming each point through `t`.
    private static func bezierPath(from d: String, _ t: (CGPoint) -> CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        var command: Character = " "
        var segment = ""

        func flush() {
            guard command != " " else { return }
            let n = numbers(segment)
            switch command {
            case "M":
                var i = 0
                while i + 1 < n.count {
                    let p = t(CGPoint(x: n[i], y: n[i + 1]))
                    if i == 0 { path.move(to: p) } else { path.line(to: p) }
                    i += 2
                }
            case "L":
                var i = 0
                while i + 1 < n.count { path.line(to: t(CGPoint(x: n[i], y: n[i + 1]))); i += 2 }
            case "C":
                var i = 0
                while i + 5 < n.count {
                    path.curve(to: t(CGPoint(x: n[i + 4], y: n[i + 5])),
                               controlPoint1: t(CGPoint(x: n[i], y: n[i + 1])),
                               controlPoint2: t(CGPoint(x: n[i + 2], y: n[i + 3])))
                    i += 6
                }
            case "Z", "z":
                path.close()
            default:
                break
            }
            segment = ""
        }

        for ch in d {
            if ch.isLetter { flush(); command = ch } else { segment.append(ch) }
        }
        flush()
        return path
    }
}

private let duckPathData = """
M80.6174 0.0190988C79.309 -0.010365 77.9847 -0.00569725 76.6462 0.032814C76.1105 0.0842056 75.5738 0.132964 75.0368 0.181744C72.0157 0.456179 68.9871 0.731287 66.1025 1.47979C44.1266 7.18211 27.791 25.0299 27.5179 48.2948C27.5012 49.7143 27.549 51.1526 27.5967 52.5865C27.6421 53.9522 27.6873 55.3141 27.6767 56.6518C27.6058 56.6892 27.5355 56.7268 27.4659 56.7645C25.9128 57.6066 24.6733 58.542 23.4243 59.4846C22.4208 60.2419 21.4111 61.0039 20.2276 61.7259C18.9981 62.3426 17.7614 63.0022 16.5246 63.6619C15.1219 64.41 13.7187 65.1585 12.3267 65.8438C11.3675 66.3161 10.4197 66.6629 9.47805 67.0074C8.13475 67.4988 6.80414 67.9857 5.47125 68.8258C-3.53396 74.5022 -0.716522 82.901 8.77825 85.3493C16.3276 87.2959 24.0967 87.6021 31.853 87.9077C35.8742 88.0662 39.8923 88.2245 43.8742 88.6113C44.5173 88.6714 45.5804 89.0952 46.8027 89.7469C48.3164 90.5538 50.0742 91.7101 51.5809 92.9574C59.0285 97.3621 67.7176 99.89 76.9972 99.89C104.611 99.89 126.997 77.5043 126.997 49.89C126.997 23.4932 106.542 1.874 80.6174 0.0190988Z
"""
