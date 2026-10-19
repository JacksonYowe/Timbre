import Foundation

/// Reads and writes EQ text files.
///
/// Understands:
///  • EqualizerAPO / AutoEQ "ParametricEQ.txt"  — `Preamp: -6 dB`, `Filter 1: ON PK Fc 105 Hz Gain -2.3 dB Q 0.70`
///  • EqualizerAPO / AutoEQ "GraphicEQ.txt"     — `GraphicEQ: 20 -1.2; 21 -1.1; …`
///  • Plain frequency/gain lists (REW, Wavelet, CSV, spreadsheets) — `100 2.5` or `100, 2.5` per line
///  • Plain 31-number lists — one gain per ISO band, low to high
/// Graphic curves are fitted onto Timbre's 31 bands so they sound like the original.
enum EQFile {
    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func load(url: URL) throws -> EQPreset {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ParseError(message: "\(url.lastPathComponent) isn't a text file.")
        }
        var preset = try parse(text, name: url.deletingPathExtension().lastPathComponent)
        preset.id = "file:" + url.lastPathComponent
        preset.origin = .file
        return preset
    }

    static func parse(_ text: String, name: String) throws -> EQPreset {
        var preamp = 0.0
        var bands: [EQBand] = []
        var graphicPoints: [(Double, Double)] = []
        var plainPairs: [(Double, Double)] = []
        var plainSingles: [Double] = []
        var blurb = ""

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") || line.hasPrefix("//") || line.hasPrefix(";") {
                let comment = line.drop { "#/; ".contains($0) }
                if blurb.isEmpty, comment.lowercased().hasPrefix("description:") {
                    blurb = comment.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            let lower = line.lowercased()

            if lower.hasPrefix("preamp") {
                if let v = numbers(in: line).first, v.isFinite { preamp += v }
                continue
            }
            if lower.hasPrefix("graphiceq") {
                let body = line.drop { $0 != ":" }.dropFirst()
                for pair in body.split(separator: ";") {
                    // European files write "-1,2" for -1.2 inside the pair.
                    var text = String(pair)
                    if text.contains(","), !text.contains(".") { text = text.replacingOccurrences(of: ",", with: ".") }
                    let n = numbers(in: text)
                    if n.count >= 2, let p = point(n[0], n[1]) { graphicPoints.append(p) }
                }
                continue
            }
            if lower.hasPrefix("filter") {
                if let band = parseFilter(line) { bands.append(band) }
                continue
            }
            // APO directives we can safely ignore.
            if ["device", "channel", "stage", "include", "copy", "eval", "convolution", "delay", "if", "elseif", "else", "endif"]
                .contains(where: { lower.hasPrefix($0) }) { continue }

            let n = numbers(in: line)
            if n.count >= 2 { if let p = point(n[0], n[1]) { plainPairs.append(p) } }
            else if n.count == 1, n[0].isFinite { plainSingles.append(clampGain(n[0])) }
        }
        // Never let a file set an extreme level: −24…+12 dB, like the preamp slider allows.
        preamp = min(12, max(-24, preamp))

        // Parametric filters win only if at least one is on; otherwise a GraphicEQ curve or plain
        // list in the same file is used. An all-off file with no curve still loads as all-off.
        let hasCurve = graphicPoints.count >= 2 || plainPairs.count >= 2 || plainSingles.count == 31
        if bands.contains(where: \.enabled) || (!bands.isEmpty && !hasCurve) {
            if bands.count > EQPreset.maxBands {
                throw ParseError(message: "That file has \(bands.count) filters — Timbre can run up to \(EQPreset.maxBands).")
            }
            // Bands can stack on one frequency; refuse files whose combined boost is unsafe.
            let peak = EQResponse.worstPeakGain(bands: bands) + preamp
            if peak > 30 {
                throw ParseError(message: String(format: "“%@” boosts the sound by %.0f dB, which isn't safe to play. Timbre allows up to 30 dB.", name, peak))
            }
            return EQPreset(id: "", name: name, preamp: preamp, bands: bands, blurb: blurb)
        }
        let curve = graphicPoints.isEmpty ? plainPairs : graphicPoints
        if curve.count >= 2 {
            let gains = GraphicFit.fit(curve: curve)
            var b = EQPreset.flat31()
            for i in b.indices { b[i].gain = gains[i] }
            return try checked(EQPreset(id: "", name: name, preamp: preamp, bands: b, blurb: blurb))
        }
        if plainSingles.count == 31 {
            let curve = zip(EQPreset.isoCentres, plainSingles).map { ($0, $1) }
            let gains = GraphicFit.fit(curve: curve)
            var b = EQPreset.flat31()
            for i in b.indices { b[i].gain = gains[i] }
            return try checked(EQPreset(id: "", name: name, preamp: preamp, bands: b, blurb: blurb))
        }
        throw ParseError(message: "Couldn't find any EQ settings in “\(name)”. Timbre reads EqualizerAPO / AutoEQ files (ParametricEQ or GraphicEQ) and simple “frequency gain” lists.")
    }

    /// `Filter 3: ON PK Fc 1000 Hz Gain -3.5 dB Q 1.41` (also BW Oct, LS/HS with slope, LP/HP without Q).
    private static func parseFilter(_ line: String) -> EQBand? {
        let afterColon = line.contains(":") ? String(line.drop { $0 != ":" }.dropFirst()) : line
        let tokens = afterColon.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let upper = tokens.map { $0.uppercased() }
        // "OFF" bands are kept (switched off) so a save → reload round-trips them.
        let enabled = !upper.contains("OFF")

        let typeMap: [String: FilterType] = [
            "PK": .peak, "PEQ": .peak, "MODAL": .peak,
            "LS": .lowShelf, "LSC": .lowShelf, "LSQ": .lowShelf,
            "HS": .highShelf, "HSC": .highShelf, "HSQ": .highShelf,
            "LP": .lowPass, "LPQ": .lowPass,
            "HP": .highPass, "HPQ": .highPass,
            "NO": .notch, "BP": .bandPass, "AP": .allPass,
        ]
        guard let type = upper.lazy.compactMap({ typeMap[$0] }).first else { return nil }

        func value(after key: String) -> Double? {
            guard let i = upper.firstIndex(of: key), i + 1 < tokens.count else { return nil }
            return Double(tokens[i + 1].replacingOccurrences(of: ",", with: "."))
        }
        guard let fcRaw = value(after: "FC"), fcRaw.isFinite, fcRaw > 0 else { return nil }
        let fc = min(22_000, max(10, fcRaw))
        let gainRaw = value(after: "GAIN") ?? 0
        guard gainRaw.isFinite else { return nil }
        let gain = clampGain(gainRaw)
        var q: Double
        if let qv = value(after: "Q") {
            q = qv
        } else if let i = upper.firstIndex(of: "BW"), i + 2 < tokens.count, upper[i + 1] == "OCT",
                  let bw = Double(tokens[i + 2]), bw.isFinite, bw > 0 {
            let p = pow(2, bw)
            q = sqrt(p) / (p - 1)
        } else {
            q = (type == .peak || type == .notch || type == .bandPass) ? 1.41 : 0.7071
        }
        guard q.isFinite else { return nil }
        q = min(max(q, 0.05), 60)
        return EQBand(type: type, frequency: fc, gain: gain, q: q, enabled: enabled)
    }

    /// Refuse anything whose combined boost could blast the listener at some sample rate.
    static func checked(_ p: EQPreset) throws -> EQPreset {
        let peak = EQResponse.worstPeakGain(bands: p.bands) + p.preamp
        if peak > 30 {
            throw ParseError(message: String(format: "“%@” boosts the sound by %.0f dB, which isn't safe to play. Timbre allows up to 30 dB.", p.name, peak))
        }
        return p
    }

    /// Same limits as the editor: ±24 dB per band.
    static func clampGain(_ g: Double) -> Double { min(24, max(-24, g)) }

    private static func point(_ f: Double, _ g: Double) -> (Double, Double)? {
        guard f.isFinite, g.isFinite, f > 0 else { return nil }
        return (f, clampGain(g))
    }

    private static func numbers(in s: String) -> [Double] {
        var out: [Double] = []
        var current = ""
        for ch in s {
            if ch.isNumber || ch == "." || (ch == "-" && current.isEmpty) || (ch == "+" && current.isEmpty) {
                current.append(ch)
            } else if ch == "," && !current.isEmpty && !current.contains(".") && s.contains(";") {
                current.append(".")   // European decimal comma inside GraphicEQ lists
            } else {
                if let v = Double(current) { out.append(v) }
                current = ""
            }
        }
        if let v = Double(current) { out.append(v) }
        return out
    }

    /// Writes EqualizerAPO ParametricEQ format — readable by Timbre, EqualizerAPO, Peace, Wavelet, etc.
    static func text(for preset: EQPreset) -> String {
        var lines = ["# \(preset.name) — saved by Timbre"]
        if !preset.blurb.isEmpty { lines.append("# Description: \(preset.blurb)") }
        lines.append(String(format: "Preamp: %.1f dB", preset.preamp))
        for (i, b) in preset.bands.enumerated() {
            let state = b.enabled ? "ON" : "OFF"
            let fc = b.frequency < 100 ? String(format: "%.1f", b.frequency) : String(format: "%.0f", b.frequency)
            if b.type.usesGain {
                lines.append(String(format: "Filter %d: %@ %@ Fc %@ Hz Gain %.1f dB Q %.3f", i + 1, state, b.type.rawValue, fc, b.gain, b.q))
            } else {
                lines.append(String(format: "Filter %d: %@ %@ Fc %@ Hz Q %.3f", i + 1, state, b.type.rawValue, fc, b.q))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Fits a target curve onto the 31 ISO bells. Neighbouring 1/3-octave bells overlap, so simply
/// copying each target value would overshoot; a few rounds of correction make the summed
/// response land on the target at every band centre.
enum GraphicFit {
    static func fit(curve: [(Double, Double)], sampleRate: Double = 48_000) -> [Double] {
        let sorted = curve.filter { $0.0 > 0 }.sorted { $0.0 < $1.0 }
        let target = EQPreset.isoCentres.map { interpolate(sorted, at: $0) }
        return fit(target: target, sampleRate: sampleRate)
    }

    static func fit(target: [Double], sampleRate: Double = 48_000) -> [Double] {
        let centres = EQPreset.isoCentres
        var gains = target
        for _ in 0..<40 {
            var bands = EQPreset.flat31()
            for i in bands.indices { bands[i].gain = gains[i] }
            let response = EQResponse.curve(bands: bands, frequencies: centres, sampleRate: sampleRate)
            var worst = 0.0
            for i in gains.indices {
                let err = target[i] - response[i]
                worst = max(worst, abs(err))
                gains[i] = min(24, max(-24, gains[i] + err * 0.6))
            }
            if worst < 0.05 { break }
        }
        return gains.map { ($0 * 10).rounded() / 10 }
    }

    /// Linear interpolation in log-frequency; holds the end values outside the data.
    static func interpolate(_ pts: [(Double, Double)], at f: Double) -> Double {
        guard let first = pts.first, let last = pts.last else { return 0 }
        if f <= first.0 { return first.1 }
        if f >= last.0 { return last.1 }
        for i in 1..<pts.count where pts[i].0 >= f {
            let (f0, g0) = pts[i - 1], (f1, g1) = pts[i]
            let t = (log(f) - log(f0)) / max(log(f1) - log(f0), 1e-9)
            return g0 + (g1 - g0) * t
        }
        return last.1
    }
}
