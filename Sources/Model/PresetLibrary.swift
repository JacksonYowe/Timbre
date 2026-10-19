import AppKit
import Foundation

/// Built-in presets plus every EQ text file in the presets folder. The folder is re-scanned
/// continuously, so dropping a .txt in (or editing one in TextEdit) shows up instantly —
/// and if it's the preset that's playing, the new curve is heard straight away.
final class PresetLibrary: ObservableObject {
    @Published private(set) var builtIns: [EQPreset] = BuiltInPresets.all
    @Published private(set) var files: [EQPreset] = []
    @Published private(set) var fileErrors: [String: String] = [:]   // filename → why it failed

    /// Fires when a file preset's contents change on disk.
    var onFileChanged: ((EQPreset) -> Void)?

    let folder: URL
    private var stamps: [String: Date] = [:]
    private var timer: Timer?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("Timbre/Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        rescan()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.rescan() }
    }

    var all: [EQPreset] { builtIns + files }

    func preset(id: String) -> EQPreset? { all.first { $0.id == id } }

    func rescan() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let eqURLs = urls.filter { ["txt", "csv", "eq", "peq", "apo"].contains($0.pathExtension.lowercased()) }
        var newStamps: [String: Date] = [:]
        for url in eqURLs {
            newStamps[url.lastPathComponent] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        guard newStamps != stamps else { return }

        let changed = newStamps.filter { stamps[$0.key] != nil && stamps[$0.key] != $0.value }.map(\.key)
        stamps = newStamps

        var loaded: [EQPreset] = []
        var errors: [String: String] = [:]
        for url in eqURLs {
            do { loaded.append(try EQFile.load(url: url)) }
            catch { errors[url.lastPathComponent] = error.localizedDescription }
        }
        files = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        fileErrors = errors
        for name in changed {
            if let p = files.first(where: { $0.id == "file:" + name }) { onFileChanged?(p) }
        }
    }

    // MARK: - Import / save

    /// Copies EQ files into the presets folder. Returns the imported presets and any failures.
    @discardableResult
    func importFiles(_ urls: [URL]) -> (imported: [EQPreset], failures: [String]) {
        var imported: [EQPreset] = []
        var failures: [String] = []
        for url in urls {
            do {
                var preset = try EQFile.load(url: url)   // validate before copying
                let dest = uniqueURL(for: Self.cleanName(url.deletingPathExtension().lastPathComponent), ext: "txt")
                // Store parametric files untouched; convert graphic/plain lists so they round-trip exactly.
                let original = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
                if preset.isGraphic31, !original.lowercased().contains("filter") {
                    try EQFile.text(for: preset).write(to: dest, atomically: true, encoding: .utf8)
                } else {
                    try FileManager.default.copyItem(at: url, to: dest)
                }
                preset.id = "file:" + dest.lastPathComponent
                imported.append(preset)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        rescan()
        return (imported, failures)
    }

    /// Saves (or overwrites) a preset as a text file. Returns the new preset id.
    @discardableResult
    /// A name that is safe as a single file name in the presets folder: no path separators,
    /// not hidden, not empty.
    static func cleanName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .filter { !$0.isNewline && $0 != "\0" }
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = "Untitled" }
        // macOS file names max out at 255 bytes (emoji/CJK take several each); leave room for ".txt".
        while s.utf8.count > 200 { s.removeLast() }
        return s
    }

    func save(_ preset: EQPreset, as name: String, overwrite: Bool) throws -> String {
        let clean = Self.cleanName(name)
        let dest = overwrite ? folder.appendingPathComponent(clean + ".txt") : uniqueURL(for: clean, ext: "txt")
        var copy = preset
        copy.name = clean
        // Never write a file the library would then refuse to load (it would silently vanish).
        let text = EQFile.text(for: copy)
        _ = try EQFile.parse(text, name: clean)
        try text.write(to: dest, atomically: true, encoding: .utf8)
        rescan()
        return "file:" + dest.lastPathComponent
    }

    func delete(id: String) {
        guard let url = url(for: id) else { return }
        NSWorkspace.shared.recycle([url]) { [weak self] _, _ in DispatchQueue.main.async { self?.rescan() } }
    }

    func rename(id: String, to name: String) -> String? {
        guard let src = url(for: id) else { return nil }
        let dest = uniqueURL(for: Self.cleanName(name), ext: src.pathExtension.isEmpty ? "txt" : src.pathExtension)
        guard (try? FileManager.default.moveItem(at: src, to: dest)) != nil else { return nil }
        rescan()
        return "file:" + dest.lastPathComponent
    }

    /// Only ever a file directly inside the presets folder.
    func url(for id: String) -> URL? {
        guard id.hasPrefix("file:") else { return nil }
        let name = String(id.dropFirst(5))
        guard !name.isEmpty, !name.contains("/"), name != "..", name != "." else { return nil }
        return folder.appendingPathComponent(name)
    }

    private func uniqueURL(for base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

/// Starter presets, written as smooth target curves and fitted onto the 31 bands.
enum BuiltInPresets {
    static let all: [EQPreset] = [
        make("flat", "No EQ", "Nothing changed — your headphones' own sound, uncorrected.") { _ in 0 },
        make("bass", "Bass Boost", "Extra thump and rumble without muddying vocals.") { f in
            shelfLow(f, 90, 6.5) - bell(f, 300, 1.0, 0.8)
        },
        make("vocal", "Vocal Clarity", "Brings singers and dialogue forward.") { f in
            -shelfLow(f, 120, 2) + bell(f, 2500, 0.9, 3.5) + bell(f, 5000, 1.2, 1.5) - bell(f, 350, 1.0, 1.5)
        },
        make("voice", "Podcast & Speech", "Crisp, easy-to-follow voices. Cuts boom and hiss.") { f in
            -shelfLow(f, 110, 7) + bell(f, 3000, 1.0, 4) - shelfHigh(f, 9000, 3) - bell(f, 250, 1.2, 1.5)
        },
        make("rock", "Rock", "Punchy drums, crunchy guitars, airy cymbals.") { f in
            shelfLow(f, 100, 4) - bell(f, 500, 0.9, 2) + bell(f, 3000, 1.0, 2) + shelfHigh(f, 9000, 3.5)
        },
        make("electronic", "Electronic", "Deep sub-bass and sparkly highs — the classic V shape.") { f in
            shelfLow(f, 70, 7) - bell(f, 800, 0.7, 2.5) + shelfHigh(f, 8000, 4.5)
        },
        make("hiphop", "Hip-Hop", "Heavy 808s and clear vocals.") { f in
            shelfLow(f, 80, 7) + bell(f, 45, 1.2, 1.5) - bell(f, 400, 1.0, 2) + bell(f, 2500, 1.0, 2)
        },
        make("pop", "Pop", "Bright, polished and vocal-forward.") { f in
            shelfLow(f, 100, 2.5) + bell(f, 2500, 0.8, 2.5) + shelfHigh(f, 10000, 2.5) - bell(f, 300, 1.0, 1)
        },
        make("acoustic", "Acoustic", "Natural warmth for guitars, piano and folk.") { f in
            bell(f, 200, 0.9, 2) + bell(f, 3500, 1.0, 1.5) + shelfHigh(f, 12000, 1.5) - shelfLow(f, 50, 1)
        },
        make("classical", "Classical & Jazz", "Wide, open and gentle — lets acoustic instruments breathe.") { f in
            shelfLow(f, 100, 1.5) - bell(f, 2500, 0.8, 1.2) + shelfHigh(f, 10000, 2.5)
        },
        make("movie", "Movies & Games", "Cinematic rumble with dialogue kept clear.") { f in
            shelfLow(f, 60, 6) + bell(f, 2800, 1.0, 2.5) + shelfHigh(f, 10000, 1.5) - bell(f, 600, 1.0, 1)
        },
        make("night", "Late Night", "Fuller sound at low volume (loudness compensation).") { f in
            shelfLow(f, 120, 6) + shelfHigh(f, 9000, 4) - bell(f, 2500, 0.8, 1)
        },
        make("treble", "Bright & Detailed", "More sparkle and detail for dark-sounding headphones.") { f in
            shelfHigh(f, 4500, 4.5) + bell(f, 12000, 1.0, 1.5)
        },
        make("warm", "Warm & Smooth", "Tames harsh, fatiguing treble.") { f in
            shelfLow(f, 200, 2.5) - shelfHigh(f, 5000, 4) - bell(f, 3200, 1.2, 1.5)
        },
    ]

    private static func make(_ id: String, _ name: String, _ blurb: String, curve: (Double) -> Double) -> EQPreset {
        let gains = GraphicFit.fit(target: EQPreset.isoCentres.map(curve))
        var bands = EQPreset.flat31()
        for i in bands.indices { bands[i].gain = gains[i] }
        return EQPreset(id: "builtin:" + id, name: name, preamp: 0, bands: bands, origin: .builtIn, blurb: blurb)
    }

    // Smooth curve helpers (dB).
    private static func shelfLow(_ f: Double, _ fc: Double, _ g: Double) -> Double { g / (1 + pow(f / fc, 2)) }
    private static func shelfHigh(_ f: Double, _ fc: Double, _ g: Double) -> Double { g / (1 + pow(fc / f, 2)) }
    private static func bell(_ f: Double, _ fc: Double, _ widthOct: Double, _ g: Double) -> Double {
        let o = log2(f / fc) / widthOct
        return g * exp(-o * o * 1.4)
    }
}
