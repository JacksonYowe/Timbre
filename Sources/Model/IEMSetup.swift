import AppKit
import Foundation

/// Reads a frequency-response curve out of a picture of a graph (squig.link, a review site,
/// a box insert…), then builds EQ that makes those IEMs sound neutral.
enum GraphTracer {
    struct Bitmap {
        let width: Int, height: Int
        let pixels: [UInt8]   // RGBA
        func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = (y * width + x) * 4
            return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }
    }

    static func bitmap(_ image: NSImage) -> Bitmap? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 0, cg.height > 0 else { return nil }
        // Cap the working size: a screenshot never needs more, and a huge image would eat memory.
        let k = min(1, 4096 / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * k)), h = max(1, Int(Double(cg.height) * k))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Bitmap(width: w, height: h, pixels: px)
    }

    /// The most common strongly-coloured pixel in the plot — usually the curve.
    static func dominantColour(_ bmp: Bitmap, in r: CGRect) -> NSColor? {
        var counts: [Int: (n: Int, r: Double, g: Double, b: Double)] = [:]
        let x0 = max(0, Int(r.minX)), x1 = min(bmp.width - 1, Int(r.maxX))
        let y0 = max(0, Int(r.minY)), y1 = min(bmp.height - 1, Int(r.maxY))
        guard x1 > x0, y1 > y0 else { return nil }
        let step = max(1, (x1 - x0) * (y1 - y0) / 250_000)
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let (R, G, B) = bmp.rgb(x, y)
                let mx = max(R, G, B), mn = min(R, G, B)
                if mx - mn > 70, mx > 60 {   // saturated: not grid, text or background
                    let key = (Int(R) / 32) << 10 | (Int(G) / 32) << 5 | (Int(B) / 32)
                    var e = counts[key] ?? (0, 0, 0, 0)
                    e.n += 1; e.r += R; e.g += G; e.b += B
                    counts[key] = e
                }
                x += step
            }
            y += step
        }
        guard let best = counts.values.max(by: { $0.n < $1.n }), best.n > 20 else { return nil }
        let n = Double(best.n)
        return NSColor(srgbRed: best.r / n / 255, green: best.g / n / 255, blue: best.b / n / 255, alpha: 1)
    }

    /// Follows the line of `colour` across the plot, one image column at a time. Where several
    /// matching bits share a column (another curve of the same colour, labels), it keeps the one
    /// closest to where the line just was. Returns image-pixel points.
    static func trace(_ bmp: Bitmap, in r: CGRect, colour: NSColor, tolerance: Double = 70) -> [CGPoint] {
        guard let c = colour.usingColorSpace(.sRGB) else { return [] }
        let tr = Double(c.redComponent) * 255, tg = Double(c.greenComponent) * 255, tb = Double(c.blueComponent) * 255
        let x0 = max(0, Int(r.minX)), x1 = min(bmp.width - 1, Int(r.maxX))
        let y0 = max(0, Int(r.minY)), y1 = min(bmp.height - 1, Int(r.maxY))
        guard x1 > x0, y1 > y0 else { return [] }
        let tol2 = tolerance * tolerance

        var columns: [(x: Int, runs: [(mid: Double, len: Int)])] = []
        for x in x0...x1 {
            var runs: [(Double, Int)] = []
            var start = -1
            for y in y0...y1 {
                let (R, G, B) = bmp.rgb(x, y)
                let d = (R - tr) * (R - tr) + (G - tg) * (G - tg) + (B - tb) * (B - tb)
                if d < tol2 { if start < 0 { start = y } } else if start >= 0 {
                    runs.append((Double(start + y - 1) / 2, y - start)); start = -1
                }
            }
            if start >= 0 { runs.append((Double(start + y1) / 2, y1 - start + 1)) }
            if !runs.isEmpty { columns.append((x, runs)) }
        }
        guard !columns.isEmpty else { return [] }

        // Seed where the line is unambiguous (one thin match in the column) nearest the middle,
        // then walk outward both ways.
        let thin = Double(y1 - y0) * 0.15
        let midX = Double(x0 + x1) / 2
        let clean = columns.indices.filter { columns[$0].runs.count == 1 && Double(columns[$0].runs[0].len) < thin }
        let seedIndex = (clean.isEmpty ? Array(columns.indices) : clean).min { abs(Double(columns[$0].x) - midX) < abs(Double(columns[$1].x) - midX) } ?? 0
        var picked = [Double?](repeating: nil, count: columns.count)
        picked[seedIndex] = columns[seedIndex].runs.max { $0.len < $1.len }!.mid
        let maxJump = Double(y1 - y0) * 0.12
        for dir in [1, -1] {
            var prev = picked[seedIndex]!
            var i = seedIndex + dir
            while i >= 0, i < columns.count {
                let nearest = columns[i].runs.min { abs($0.mid - prev) < abs($1.mid - prev) }!
                let gap = abs(columns[i].x - columns[i - dir].x)
                if abs(nearest.mid - prev) <= maxJump * Double(max(1, gap)) {
                    picked[i] = nearest.mid
                    prev = nearest.mid
                }
                i += dir
            }
        }
        var pts: [CGPoint] = []
        for (i, col) in columns.enumerated() { if let y = picked[i] { pts.append(CGPoint(x: Double(col.x), y: y)) } }
        // Light median smoothing to remove anti-aliasing wobble.
        guard pts.count > 5 else { return pts }
        return pts.indices.map { i in
            let lo = max(0, i - 2), hi = min(pts.count - 1, i + 2)
            let ys = pts[lo...hi].map(\.y).sorted()
            return CGPoint(x: pts[i].x, y: ys[ys.count / 2])
        }
    }

    /// Pixel → (Hz, dB) using the plot box: log frequency across, linear dB up.
    static func response(_ pts: [CGPoint], box: CGRect, fLow: Double, fHigh: Double, dbTop: Double, dbBottom: Double) -> [(Double, Double)] {
        guard box.width > 0, box.height > 0, fLow > 0, fHigh > fLow else { return [] }
        return pts.compactMap { p in
            let tx = (Double(p.x) - Double(box.minX)) / Double(box.width)
            let ty = (Double(p.y) - Double(box.minY)) / Double(box.height)
            guard tx >= -0.01, tx <= 1.01 else { return nil }
            let f = fLow * pow(fHigh / fLow, tx)
            return (f, dbTop + (dbBottom - dbTop) * ty)
        }
    }
}

/// What "flat" should mean for an IEM.
enum IEMTarget: String, CaseIterable, Identifiable {
    case neutral, ruler
    var id: String { rawValue }
    var label: String {
        switch self {
        case .neutral: "Neutral (recommended)"
        case .ruler: "Ruler-flat line"
        }
    }
    var explanation: String {
        switch self {
        case .neutral: "Sounds flat to your ears. In-ear graphs never look flat when they sound flat — your ear canal changes everything — so this uses the standard in-ear neutral target (AutoEQ's)."
        case .ruler: "Makes the graph a straight line. Usually sounds thin and shouty on IEMs — only pick this if your graph is already compensated (says “compensated” or “vs target”)."
        }
    }

    /// AutoEQ's in-ear target, sampled.
    private static let neutralPoints: [(Double, Double)] = [
        (20, 7.27), (23, 7.25), (27, 7.23), (31, 7.20), (36, 7.15), (41, 7.06), (48, 6.89), (55, 6.64), (63, 6.22), (73, 5.63),
        (85, 4.79), (97, 3.84), (113, 2.75), (130, 1.79), (149, 1.00), (173, 0.35), (199, -0.05), (231, -0.33), (266, -0.50),
        (309, -0.55), (355, -0.50), (412, -0.43), (473, -0.33), (550, -0.18), (632, -0.01), (733, 0.22), (843, 0.46), (979, 0.83),
        (1125, 1.32), (1293, 2.09), (1501, 3.08), (1726, 4.26), (2004, 5.91), (2303, 7.31), (2674, 8.37), (3074, 8.71),
        (3568, 8.52), (4102, 8.01), (4762, 7.40), (5474, 6.89), (6355, 6.26), (7305, 5.08), (8397, 3.26), (9748, 0.49),
        (11205, -2.25), (13009, -5.15), (14954, -7.55), (17361, -11.80), (19956, -19.40),
    ]

    func value(at f: Double) -> Double {
        self == .ruler ? 0 : GraphicFit.interpolate(Self.neutralPoints, at: f)
    }
}

enum IEMCorrection {
    /// 31-band EQ that turns `measured` into `target`. Gentle above 8 kHz (graphs and fit vary
    /// most there) and limited to +9/−12 dB so nothing gets harsh or distorted.
    static func bands(measured: [(Double, Double)], target: IEMTarget) -> [EQBand] {
        let sorted = measured.sorted { $0.0 < $1.0 }
        let m = EQPreset.isoCentres.map { smoothed(sorted, at: $0) }
        let t = EQPreset.isoCentres.map { target.value(at: $0) }
        let mids = EQPreset.isoCentres.indices.filter { EQPreset.isoCentres[$0] >= 300 && EQPreset.isoCentres[$0] <= 3000 }
        let offset = mids.map { t[$0] - m[$0] }.reduce(0, +) / Double(mids.count)
        let wanted = EQPreset.isoCentres.indices.map { i -> Double in
            let f = EQPreset.isoCentres[i]
            let taper = f > 8000 ? max(0, 1 - log2(f / 8000) / 1.3) : 1
            return min(9, max(-12, (t[i] - m[i] - offset) * taper))
        }
        var bands = EQPreset.flat31()
        let gains = GraphicFit.fit(target: wanted)
        for i in bands.indices { bands[i].gain = gains[i] }
        return bands
    }

    /// Response averaged over a window that widens with frequency: 1/6 octave in the bass and
    /// mids, up to a full octave above 8 kHz. Treble peaks and dips move with fit and insertion
    /// depth, so chasing them makes things worse (AutoEQ smooths the same way).
    static func smoothed(_ pts: [(Double, Double)], at f: Double) -> Double {
        let width: Double = f < 2000 ? 1.0 / 6 : (f > 8000 ? 1.0 : 1.0 / 6 + (5.0 / 6) * log2(f / 2000) / 2)
        let lo = log2(f) - width / 2
        let n = 15
        var sum = 0.0
        for i in 0..<n { sum += GraphicFit.interpolate(pts, at: pow(2, lo + width * Double(i) / Double(n - 1))) }
        return sum / Double(n)
    }

    /// The presets auto-switch uses, rebuilt on top of an IEM's correction.
    static let genrePresets: [(id: String, name: String)] = [
        ("builtin:rock", "Rock"), ("builtin:electronic", "Electronic"), ("builtin:hiphop", "Hip-Hop"), ("builtin:pop", "Pop"),
        ("builtin:acoustic", "Acoustic"), ("builtin:classical", "Classical & Jazz"), ("builtin:movie", "Movies & Games"),
        ("builtin:voice", "Podcast & Speech"),
    ]

    /// Correction + a genre's sound, folded into one true 31-band preset.
    static func combine(_ correction: [EQBand], with genre: EQPreset?) -> [EQBand] {
        guard let genre else { return correction }
        let total = EQResponse.curve(bands: correction + genre.bands, frequencies: EQPreset.isoCentres)
        var bands = EQPreset.flat31()
        let gains = GraphicFit.fit(target: total)
        for i in bands.indices { bands[i].gain = gains[i] }
        return bands
    }
}
