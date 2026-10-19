import Accelerate
import AppKit
import Foundation

/// `Timbre --selftest` — checks the parts that can be verified without speakers:
/// file parsing, the 31-band fit, real filter gain vs. predicted, and glitch-free hot-swapping.
enum SelfTest {
    private static var failures = 0

    static func run() -> Bool {
        failures = 0
        parsing()
        graphicFit()
        filterAccuracy()
        hotSwap()
        builtIns()
        genres()
        graphTracing()
        gearSwitching()
        reviewRegressions()
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        return failures == 0
    }

    private static func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS  " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    private static func parsing() {
        let apo = """
        Preamp: -6.4 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.2 dB Q 0.70
        Filter 2: ON PK Fc 157 Hz Gain -2.4 dB Q 0.53
        Filter 3: ON PK Fc 1270 Hz Gain 1.9 dB Q 2.09
        Filter 4: OFF PK Fc 3000 Hz Gain 9 dB Q 1
        Filter 5: ON HSC Fc 10000 Hz Gain -3.1 dB Q 0.70
        Filter 6: ON PK Fc 2000 Hz Gain 3 dB BW Oct 1.0
        Filter 7: ON HP Fc 20 Hz
        """
        do {
            let p = try EQFile.parse(apo, name: "t")
            check(abs(p.preamp + 6.4) < 1e-9, "APO preamp parsed")
            check(p.bands.count == 7 && p.bands.filter(\.enabled).count == 6 && !p.bands[3].enabled,
                  "APO: OFF filter kept but switched off (got \(p.bands.count), \(p.bands.filter(\.enabled).count) on)")
            check(p.bands[0].type == .lowShelf && p.bands[0].frequency == 105 && p.bands[0].gain == 6.2, "APO low shelf")
            check(abs(p.bands[5].q - 1.414) < 0.01, "APO BW Oct → Q (\(p.bands[5].q))")
            check(p.bands[6].type == .highPass && abs(p.bands[6].q - 0.7071) < 0.001, "APO HP default Q")
            // Round trip
            let again = try EQFile.parse(EQFile.text(for: p), name: "t")
            check(again.bands.count == p.bands.count && zip(again.bands, p.bands).allSatisfy { abs($0.gain - $1.gain) < 0.06 && abs($0.frequency - $1.frequency) < 0.6 },
                  "APO write → read round trip")
        } catch { check(false, "APO parse threw \(error)") }

        let graphic = "GraphicEQ: 20 6; 100 6; 200 0; 1000 0; 5000 -3; 20000 -3"
        do {
            let p = try EQFile.parse(graphic, name: "g")
            check(p.isGraphic31, "GraphicEQ becomes 31 bands")
            let r = EQResponse.curve(bands: p.bands, frequencies: [40, 1000, 10000])
            check(abs(r[0] - 6) < 0.6 && abs(r[1]) < 0.6 && abs(r[2] + 3) < 0.6, "GraphicEQ response matches target (\(r.map { String(format: "%.2f", $0) }))")
        } catch { check(false, "GraphicEQ parse threw \(error)") }

        let csv = "Frequency,Gain\n100, 3\n1000, 0\n10000,-2\n"
        check((try? EQFile.parse(csv, name: "c"))?.isGraphic31 == true, "CSV frequency/gain list")
        check((try? EQFile.parse("hello world", name: "x")) == nil, "Rejects non-EQ text")
    }

    private static func graphicFit() {
        // Every other band +6 / -6: neighbours fight each other — the fit must still land on target.
        let target = (0..<31).map { $0 % 2 == 0 ? 6.0 : -6.0 }
        let gains = GraphicFit.fit(target: target)
        var bands = EQPreset.flat31()
        for i in bands.indices { bands[i].gain = gains[i] }
        let r = EQResponse.curve(bands: bands, frequencies: EQPreset.isoCentres)
        let worst = zip(r, target).map { abs($0 - $1) }.max() ?? 99
        check(worst < 0.5, String(format: "31-band fit, alternating ±6 dB: worst error %.2f dB", worst))
    }

    /// Run real sines through the vDSP chain and compare with the maths.
    private static func filterAccuracy() {
        let sr = 48_000.0
        let bands = [EQBand(type: .peak, frequency: 1000, gain: 9, q: 2), EQBand(type: .lowShelf, frequency: 100, gain: -6, q: 0.7)]
        var worst = 0.0
        for f in [50.0, 300, 1000, 4000] {
            let chain = FilterChain(bands: bands, preampDB: 0, sampleRate: sr)
            let n = 4096
            let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
            var outRMS: Float = 0
            for block in 0..<12 {
                for i in 0..<n { let v = Float(0.25 * sin(2 * .pi * f * Double(block * n + i) / sr)); l[i] = v; r[i] = v }
                chain.process(l, r, n)
                if block == 11 { vDSP_rmsqv(l, 1, &outRMS, vDSP_Length(n)) }
            }
            l.deallocate(); r.deallocate()
            let measured = 20 * log10(Double(outRMS) / (0.25 / sqrt(2)))
            let predicted = EQResponse.curve(bands: bands, frequencies: [f], sampleRate: sr)[0]
            worst = max(worst, abs(measured - predicted))
        }
        check(worst < 0.15, String(format: "vDSP chain matches predicted response (worst %.3f dB)", worst))
    }

    /// Swap presets 200 times mid-stream; output must stay finite and free of jumps.
    private static func hotSwap() {
        let dsp = DSPCore()
        let sr = 48_000.0
        dsp.prepare(sampleRate: sr)
        dsp.setCrossfade(milliseconds: 30)
        let n = 256
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { l.deallocate(); r.deallocate() }
        var prev: Float = 0
        var maxJump: Float = 0
        var finite = true
        var phase = 0
        let presets = BuiltInPresets.all
        for block in 0..<2000 {
            if block % 10 == 0 {
                let p = presets[(block / 10) % presets.count]
                dsp.install(FilterChain(bands: p.bands + ToneLayer().bands, preampDB: -6, sampleRate: sr))
            }
            for i in 0..<n {
                let v = Float(0.3 * sin(2 * .pi * 220 * Double(phase) / sr)); phase += 1
                l[i] = v; r[i] = v
            }
            dsp.process(l, r, n)
            for i in 0..<n {
                if !l[i].isFinite { finite = false }
                if block > 20 { maxJump = max(maxJump, abs(l[i] - prev)) }
                prev = l[i]
            }
            if block % 50 == 0 { dsp.collectGarbage() }
        }
        // A 220 Hz sine at ≤0.3·(boost) moves at most ~0.02 per sample; a click would be ≫ that.
        check(finite, "Hot-swap: output stays finite")
        check(maxJump < 0.05, String(format: "Hot-swap: no clicks across 200 swaps (max step %.4f)", maxJump))

        // Bypass (A/B compare) ramps instead of jumping.
        dsp.setBypassed(true)
        maxJump = 0
        for _ in 0..<40 {
            for i in 0..<n { let v = Float(0.3 * sin(2 * .pi * 220 * Double(phase) / sr)); phase += 1; l[i] = v; r[i] = v }
            dsp.process(l, r, n)
            for i in 0..<n { maxJump = max(maxJump, abs(l[i] - prev)); prev = l[i] }
        }
        check(maxJump < 0.05, String(format: "A/B bypass ramps smoothly (max step %.4f)", maxJump))
    }

    private static func builtIns() {
        for p in BuiltInPresets.all {
            let peak = EQResponse.peakGain(bands: p.bands)
            if peak > 9 || !p.isGraphic31 { check(false, "Built-in \(p.name) sane (peak \(peak))") }
        }
        check(true, "Built-in presets are 31-band and within ±9 dB")
    }

    /// Draws a review-site style graph (grid, labels, grey target line, legend swatch), then
    /// checks the tracer reads the coloured curve back accurately.
    static func renderGraph(_ curve: [(Double, Double)], size: CGSize = CGSize(width: 1200, height: 700),
                            box: CGRect = CGRect(x: 90, y: 60, width: 1060, height: 560), dbTop: Double = 20, dbBottom: Double = -20,
                            colour: NSColor = NSColor(srgbRed: 0.85, green: 0.2, blue: 0.25, alpha: 1)) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocusFlipped(true)
        NSColor.white.setFill(); NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        func x(_ f: Double) -> CGFloat { box.minX + CGFloat(log(f / 20) / log(1000)) * box.width }
        func y(_ d: Double) -> CGFloat { box.minY + CGFloat((dbTop - d) / (dbTop - dbBottom)) * box.height }
        NSColor(white: 0.85, alpha: 1).setStroke()
        for f in [20.0, 30, 40, 50, 60, 70, 80, 90, 100, 200, 300, 400, 500, 1000, 2000, 3000, 5000, 10000, 20000] {
            let p = NSBezierPath(); p.move(to: CGPoint(x: x(f), y: box.minY)); p.line(to: CGPoint(x: x(f), y: box.maxY)); p.lineWidth = 1; p.stroke()
        }
        var d = dbBottom
        while d <= dbTop {
            let p = NSBezierPath(); p.move(to: CGPoint(x: box.minX, y: y(d))); p.line(to: CGPoint(x: box.maxX, y: y(d))); p.stroke()
            ("\(Int(d))" as NSString).draw(at: CGPoint(x: box.minX - 40, y: y(d) - 8), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            d += 5
        }
        func plot(_ pts: [(Double, Double)], _ c: NSColor, _ w: CGFloat, dash: Bool = false) {
            let p = NSBezierPath()
            for (i, pt) in pts.enumerated() { i == 0 ? p.move(to: CGPoint(x: x(pt.0), y: y(pt.1))) : p.line(to: CGPoint(x: x(pt.0), y: y(pt.1))) }
            p.lineWidth = w; if dash { p.setLineDash([8, 6], count: 2, phase: 0) }
            c.setStroke(); p.stroke()
        }
        let freqs = EQResponse.logFrequencies(count: 300)
        plot(freqs.map { ($0, IEMTarget.neutral.value(at: $0) - 3) }, NSColor(white: 0.55, alpha: 1), 2, dash: true)
        plot(curve, colour, 3)
        // Legend with a swatch of the same colour, inside the plot (a classic tracer trap).
        colour.setFill(); NSBezierPath(rect: CGRect(x: box.maxX - 220, y: box.minY + 20, width: 30, height: 4)).fill()
        ("My IEM" as NSString).draw(at: CGPoint(x: box.maxX - 180, y: box.minY + 12), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
        img.unlockFocus()
        return img
    }

    private static func graphTracing() {
        // A realistic IEM shape: target with a bass shelf and a dip/peak pair in the treble.
        let truth = EQResponse.logFrequencies(count: 400).map { f in
            (f, IEMTarget.neutral.value(at: f) + 3 / (1 + pow(f / 150, 2)) - 4 * exp(-pow(log2(f / 4000) / 0.5, 2)) + 3 * exp(-pow(log2(f / 8000) / 0.3, 2)))
        }
        check(traceError(truth) < 0.8, String(format: "Graph photo → curve: traced within %.2f dB", traceError(truth)))
    }

    static func traceError(_ truth: [(Double, Double)], save: String? = nil) -> Double {
        let box = CGRect(x: 90, y: 60, width: 1060, height: 560)
        let img = renderGraph(truth, box: box)
        if let save, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: save))
        }
        guard let bmp = GraphTracer.bitmap(img) else { return 99 }
        // Bitmap may be @2x — scale the box to match.
        let k = CGFloat(bmp.width) / img.size.width
        let pxBox = CGRect(x: box.minX * k, y: box.minY * k, width: box.width * k, height: box.height * k)
        guard let colour = GraphTracer.dominantColour(bmp, in: pxBox) else { return 99 }
        let pts = GraphTracer.trace(bmp, in: pxBox.insetBy(dx: 2, dy: 2), colour: colour)
        let got = GraphTracer.response(pts, box: pxBox, fLow: 20, fHigh: 20000, dbTop: 20, dbBottom: -20).sorted { $0.0 < $1.0 }
        guard got.count > 50 else { return 99 }
        let fs = EQResponse.logFrequencies(count: 100, low: 25, high: 16000)
        return fs.map { abs(GraphicFit.interpolate(got, at: $0) - GraphicFit.interpolate(truth, at: $0)) }.max() ?? 99
    }

    private static func gearSwitching() {
        check(Gear.of("file:Rock · Example IEM.txt") == "Example IEM" && Gear.of("builtin:rock") == nil, "Gear read from preset names")
        check(Gear.guess(for: "Example IEM BT", among: ["Example IEM", "Other IEM"]) == "Example IEM" &&
              Gear.guess(for: "Someone’s Earbuds", among: ["Example IEM"]) == nil, "Gear guessed from device name")
        let lib = PresetLibrary()
        let gears = Gear.all(in: lib)
        guard let g = gears.first else { return }
        let rock = Gear.translate("builtin:rock", to: g, library: lib)
        check(rock == "file:Rock · \(g).txt", "Switch gear: Rock → Rock · \(g)")
        check(Gear.translate(rock, to: nil, library: lib) == "builtin:rock" &&
              Gear.translate("file:Flat · \(g).txt", to: nil, library: lib) == "builtin:flat", "Switch gear back to built-ins")
        check(Gear.translate("builtin:rock", to: "Nonexistent IEM", library: lib) == "builtin:rock" &&
              Gear.translate("builtin:bass", to: g, library: lib) == "builtin:bass", "Leaves presets without a tuned version alone")
    }

    /// Issues found in the security/bug review — each must stay fixed.
    private static func reviewRegressions() {
        // Hostile EQ files: NaN/inf/huge values must never reach the filters.
        let evil = "Preamp: 400 dB\nFilter 1: ON PK Fc 1000 Hz Gain nan dB Q 1\nFilter 2: ON PK Fc 2000 Hz Gain 3 dB Q nan\n" +
            "Filter 3: ON PK Fc inf Hz Gain 3 dB Q 1\nFilter 4: ON PK Fc 500 Hz Gain 999999 dB Q 1\nFilter 5: ON PK Fc 100 Hz Gain 1e400 dB Q 1"
        if let p = try? EQFile.parse(evil, name: "evil") {
            let finite = p.bands.allSatisfy { $0.gain.isFinite && $0.q.isFinite && $0.frequency.isFinite } && p.preamp.isFinite
            check(finite && p.preamp <= 12 && p.bands.allSatisfy { abs($0.gain) <= 24 }, "Hostile EQ file: values made finite and clamped (\(p.bands.count) bands, preamp \(p.preamp))")
            check((try? JSONEncoder().encode(p)) != nil, "Hostile EQ file: settings can still be saved")
        } else { check(true, "Hostile EQ file rejected") }
        let nanChain = FilterChain(bands: [EQBand(type: .peak, frequency: .nan, gain: .infinity, q: .nan)], preampDB: .nan, sampleRate: 48_000)
        let n = 512
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { l.deallocate(); r.deallocate() }
        for i in 0..<n { l[i] = 0.2; r[i] = 0.2 }
        nanChain.process(l, r, n)
        check(l[n - 1] == 0.2, "NaN band / preamp falls back to doing nothing (not silence)")
        check((try? EQFile.parse("GraphicEQ: 20 -1,5; 1000 0,5; 20000 2,0", name: "eu")).map { EQResponse.curve(bands: $0.bands, frequencies: [1000])[0] } .map { abs($0 - 0.5) < 0.3 } ?? false,
              "GraphicEQ with decimal commas")

        // Round 2: twelve +24 dB bands on one frequency must be refused, and the app never boosts past +12 dB.
        let stacked = (1...12).map { "Filter \($0): ON PK Fc 1000 Hz Gain 24 dB Q 1.0" }.joined(separator: "\n")
        check((try? EQFile.parse(stacked, name: "stack")) == nil, "Stacked-boost file refused")
        // Round 3: energy above 20 kHz / folded below Nyquist on slow devices must count.
        let ultra = (1...64).map { "Filter \($0): ON PK Fc 22000 Hz Gain 24 dB Q 60" }.joined(separator: "\n")
        check((try? EQFile.parse(ultra, name: "ultra")) == nil, "Stacked ultrasonic boost refused")
        check((try? EQFile.parse("GraphicEQ: 20 0; 10000 0; 12500 24; 20000 24", name: "fold")) == nil,
              "High boost that folds down at 24 kHz refused")
        for sr in [24_000.0, 48_000] {
            let bands = [EQBand(type: .peak, frequency: 12500, gain: 24, q: 4.3), EQBand(type: .peak, frequency: 16000, gain: 24, q: 4.3),
                         EQBand(type: .peak, frequency: 20000, gain: 24, q: 4.3)]
            let pre = -EQResponse.peakGain(bands: bands, sampleRate: sr)
            let out = FilterChain(bands: bands, preampDB: pre, sampleRate: sr)
            var worst: Float = 0
            for f in [9000.0, 11_000, 11_700, 15_000, 20_000] where f < sr / 2 {
                for i in 0..<n { let v = Float(0.25 * sin(2 * .pi * f * Double(i) / sr)); l[i] = v; r[i] = v }
                for _ in 0..<8 { out.process(l, r, n); for i in 0..<n { l[i] = Float(0.25 * sin(2 * .pi * f * Double(i) / sr)); r[i] = l[i] } }
                out.process(l, r, n)
                var pk: Float = 0; vDSP_maxmgv(l, 1, &pk, vDSP_Length(n)); worst = max(worst, pk)
            }
            check(worst < 0.25 * 1.15, String(format: "Headroom holds at %.0f kHz (peak %.3f for 0.25 in)", sr / 1000, worst))
        }
        // Round 4: an ordinary treble lift (31-band, +8 dB from 8 kHz up) must save and reload.
        var bright = EQPreset(id: "", name: "bright", bands: EQPreset.flat31())
        for i in bright.bands.indices where bright.bands[i].frequency >= 8000 { bright.bands[i].gain = 8 }
        check((try? EQFile.parse(EQFile.text(for: bright), name: "bright")) != nil, "Treble-lift preset saves and reloads")
        check((try? EQFile.parse("GraphicEQ: 20 0; 5000 0; 8000 8; 20000 8", name: "g")) != nil, "Treble-lift GraphicEQ accepted")
        let lib = PresetLibrary()
        check(lib.fileErrors.isEmpty, "All your preset files load (\(lib.files.count) files\(lib.fileErrors.isEmpty ? "" : ", errors: \(lib.fileErrors.keys.sorted())"))")
        // Round 6: switched-off filters must not hide a GraphicEQ curve in the same file.
        let mixed = try? EQFile.parse("Preamp: -6 dB\nFilter 1: OFF PK Fc 100 Hz Gain 0 dB Q 1\nGraphicEQ: 20 6; 100 6; 1000 0; 20000 -3", name: "m")
        check(mixed?.isGraphic31 == true && abs(EQResponse.curve(bands: mixed!.bands, frequencies: [50])[0] - 6) < 0.6,
              "OFF filters + GraphicEQ → curve is used")
        check((try? EQFile.parse("Filter 1: OFF PK Fc 100 Hz Gain 3 dB Q 1", name: "off"))?.bands.first?.enabled == false,
              "All-off file still loads (round-trips)")
        let longName = String(repeating: "🎧", count: 120)
        check(PresetLibrary.cleanName(longName).utf8.count <= 200, "Long emoji names fit the file-name limit")

        // Spectrum at Bluetooth headset rates must not crash.
        for sr in [8_000.0, 16_000, 24_000, 32_000] {
            let dsp = DSPCore()
            dsp.prepare(sampleRate: sr)
            _ = SpectrumAnalyzer().update(from: dsp)
        }
        check(true, "Spectrum analyser at 8/16/24/32 kHz")

        // Names can't escape the presets folder or become hidden.
        let names = ["../../../Documents/x", "..", ".hidden", "   ", "a/b:c", "Example IEM"].map(PresetLibrary.cleanName)
        check(names.allSatisfy { !$0.contains("/") && !$0.hasPrefix(".") && !$0.isEmpty } && names.last == "Example IEM", "Unsafe names cleaned: \(names)")
        check(PresetLibrary().url(for: "file:../x.txt") == nil && PresetLibrary().url(for: "file:..") == nil, "Preset ids can't point outside the folder")

        // Swapping presets every buffer (slider drag / fast hotkeys): never a click, and the newest wins.
        let dsp = DSPCore()
        dsp.prepare(sampleRate: 48_000)
        dsp.setCrossfade(milliseconds: 80)
        var prev: Float = 0, maxJump: Float = 0, phase = 0
        for block in 0..<600 {
            dsp.install(FilterChain(bands: [EQBand(type: .peak, frequency: 220, gain: block % 2 == 0 ? 12 : -12, q: 1)], preampDB: 0, sampleRate: 48_000))
            for i in 0..<256 { let v = Float(0.2 * sin(2 * .pi * 220 * Double(phase) / 48_000)); phase += 1; l[i] = v; r[i] = v }
            dsp.process(l, r, 256)
            for i in 0..<256 { if block > 4 { maxJump = max(maxJump, abs(l[i] - prev)) }; prev = l[i] }
        }
        check(maxJump < 0.06, String(format: "Swap every buffer (±12 dB): no clicks (max step %.4f)", maxJump))
    }

    private static func genres() {
        let cases: [(String, GenreFamily)] = [("Alternative", .rock), ("Hip-Hop/Rap", .hipHop), ("Dance", .electronic),
                                              ("Singer/Songwriter", .acoustic), ("Pop Punk", .rock), ("K-Pop", .pop),
                                              ("Heavy Metal", .metal), ("R&B/Soul", .rnb), ("Classical", .classical),
                                              ("Soundtrack", .soundtrack), ("Reggaeton", .latin), ("Polka", .other)]
        let bad = cases.filter { GenreFamily.classify($0.0) != $0.1 }
        check(bad.isEmpty, "Genre families \(bad.isEmpty ? "" : "wrong for \(bad.map(\.0))")")
        check(ContentDetector.spotifyKind(id: "spotify:episode:abc", override: nil) == .podcast &&
              ContentDetector.spotifyKind(id: "spotify:track:abc", override: nil) == .music &&
              ContentDetector.spotifyKind(id: "spotify:ad:abc", override: nil) == .ad, "Spotify content kinds from track IDs")
        check(GenreLookup.primaryArtist("Calvin Harris, Dua Lipa") == "Calvin Harris" &&
              GenreLookup.cleanTitle("Song (Remastered 2011) - Live") == "Song", "Artist/title clean-up")
    }
}
