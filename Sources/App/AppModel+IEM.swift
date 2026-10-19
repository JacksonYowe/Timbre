import Foundation

extension AppModel {
    struct IEMSetupResult { let flatID: String; let created: Int; let residual: Double }

    /// Turns a traced frequency response into "Flat · <IEM>" plus a tuned copy of every
    /// auto-switch preset, and (optionally) points auto-switch and favourite 1 at them.
    func setUpIEM(name rawName: String, measured: [(Double, Double)], target: IEMTarget, useForAutoSwitch: Bool) throws -> IEMSetupResult {
        // Same clean-up as preset files, so the name can't escape the folder and gear names match.
        // Short enough that "Classical & Jazz · <name>" still fits the file-name limit intact.
        var raw = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.utf8.count > 140 { raw.removeLast() }   // bytes, not characters (CJK/emoji)
        let name = PresetLibrary.cleanName(raw)
        let correction = IEMCorrection.bands(measured: measured, target: target)

        func write(_ label: String, _ bands: [EQBand], blurb: String) throws -> String {
            // Every file in the set must carry the exact same IEM name, or gear switching breaks.
            guard PresetLibrary.cleanName(label) == label else {
                throw EQFile.ParseError(message: "That IEM name is too long — try a shorter one.")
            }
            let peak = EQResponse.peakGain(bands: bands)
            let preset = EQPreset(id: "", name: label, preamp: -max(0, (peak * 10).rounded(.up) / 10), bands: bands,
                                  origin: .file, blurb: blurb)
            return try library.save(preset, as: label, overwrite: true)
        }

        let flatID = try write("Flat · \(name)", correction, blurb: "Makes your \(name) sound neutral (\(target.label.lowercased())).")
        var map: [String: String] = ["builtin:flat": flatID]
        for g in IEMCorrection.genrePresets {
            let bands = IEMCorrection.combine(correction, with: library.preset(id: g.id))
            map[g.id] = try write("\(g.name) · \(name)", bands, blurb: "\(g.name), tailored for your \(name).")
        }

        // Keep the measurement so it can be checked or reused.
        let support = library.folder.deletingLastPathComponent().appendingPathComponent("IEM Measurements", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let csv = "frequency,raw\n" + measured.sorted { $0.0 < $1.0 }.map { String(format: "%.2f,%.2f", $0.0, $0.1) }.joined(separator: "\n")
        try? csv.write(to: support.appendingPathComponent("\(name).csv"), atomically: true, encoding: .utf8)

        if useForAutoSwitch {
            // Any rule pointing at a built-in, or at another IEM's tuned copy, moves to this IEM's.
            func retarget(_ id: String) -> String {
                if let new = map[id] { return new }
                for g in IEMCorrection.genrePresets where id.hasPrefix("file:\(g.name) · ") { return map[g.id] ?? id }
                if id.hasPrefix("file:Flat · ") { return flatID }
                return id
            }
            rules = rules.map { var r = $0; r.presetID = retarget(r.presetID); return r }
            fallbackPresetID = fallbackPresetID.map(retarget)
            favourites = favourites.map(retarget)
            select(flatID)
            // Whatever is playing right now is presumably these IEMs.
            if let out = currentOutput, out.kind != .speakers, out.kind != .hdmi {
                outputGear[out.uid] = name
                if gearQuestion?.uid == out.uid { gearQuestion = nil }
            }
        }

        // How close the result gets (RMS dB from 20 Hz–10 kHz, level-matched).
        let freqs = EQResponse.logFrequencies(count: 120, high: 10_000)
        let sorted = measured.sorted { $0.0 < $1.0 }
        let eq = EQResponse.curve(bands: correction, frequencies: freqs)
        let diffs = freqs.indices.map { GraphicFit.interpolate(sorted, at: freqs[$0]) + eq[$0] - target.value(at: freqs[$0]) }
        let mean = diffs.reduce(0, +) / Double(diffs.count)
        let rms = sqrt(diffs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(diffs.count))
        return IEMSetupResult(flatID: flatID, created: 1 + IEMCorrection.genrePresets.count, residual: rms)
    }
}
