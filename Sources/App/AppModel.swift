import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// The one source of truth: which EQ is active, the user's edits, auto-switching, settings.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let library = PresetLibrary()
    let detector = ContentDetector()
    let dsp = DSPCore()
    let live: LiveMeters
    private(set) lazy var engine = SystemAudioEngine(dsp: dsp)
    private let hotkeys = HotKeys()

    // Power + engine
    @Published var isOn = false { didSet { if isOn != oldValue, !restoring { applyPower(); scheduleSave() } } }
    @Published private(set) var engineState: SystemAudioEngine.State = .off

    // The EQ itself
    @Published private(set) var activePresetID = "builtin:flat"
    @Published var working: EQPreset = BuiltInPresets.all[0] { didSet { eqChanged() } }
    @Published private(set) var isModified = false
    @Published var tone = ToneLayer() { didSet { eqChanged() } }
    @Published private(set) var appliedPreamp = 0.0
    @Published var comparing = false { didSet { dsp.setBypassed(comparing) } }
    @Published var selectedBand: Int?

    // Auto-switching
    @Published var autoSwitch = true { didSet { if autoSwitch { manualOverride = false; applyAuto() }; scheduleSave() } }
    @Published var rules: [AutoRule] = AutoRule.defaults { didSet { applyAuto(); scheduleSave() } }
    /// Used when auto-switch is on, something is playing and no rule matches. nil = leave as is.
    @Published var fallbackPresetID: String? = "builtin:flat" { didSet { applyAuto(); scheduleSave() } }
    @Published var appKinds: [String: ContentKind] = [:] {
        didSet { detector.appKinds = appKinds; detector.recompute(); scheduleSave() }
    }
    @Published private(set) var context = ListeningContext()
    @Published private(set) var autoReason = ""
    @Published private(set) var manualOverride = false
    @Published private(set) var spotifyAccess: SpotifyClient.Access = .unknown

    // Settings
    @Published var preventClipping = true { didSet { eqChanged(); scheduleSave() } }
    @Published var crossfadeMs = 80.0 { didSet { dsp.setCrossfade(milliseconds: crossfadeMs); scheduleSave() } }
    @Published var onlineGenres = true { didSet { detector.genres.enabled = onlineGenres; scheduleSave() } }
    @Published var favourites: [String] = ["builtin:flat", "builtin:bass", "builtin:vocal"] { didSet { scheduleSave() } }
    @Published var hasOnboarded = false { didSet { scheduleSave() } }

    // Outputs: which gear (IEM preset set) belongs to each speaker/headphone output
    @Published var currentOutput: OutputInfo?
    @Published var gearQuestion: OutputInfo?          // "what's plugged in?" prompt
    @Published var knownOutputs: [String: OutputInfo] = [:] { didSet { scheduleSave() } }
    @Published var outputGear: [String: String] = [:] { didSet { scheduleSave() } }   // uid → gear ("" = none)

    // Transient UI
    @Published var toast: String?
    @Published var fileProblems: [String] = []

    private var drafts: [String: EQPreset] = [:]   // unsaved edits per preset, kept while you hop around
    private var overrideIdentity = ""
    private var saveWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var restoring = false

    private init() {
        live = LiveMeters(dsp: dsp)
        restoring = true
        restore()
        restoring = false

        engine.silenceAllowance = { [weak self] in
            guard let self, let kind = self.context.kind else { return nil }
            // Spotify itself reports "playing" — trustworthy, so a short wait is enough.
            if self.context.bundleID == SpotifyClient.bundleID, self.detector.spotifyIsPlaying { return 15 }
            // Other real players only (browsers, call apps and games hold the output open in
            // silence), and wait long enough for a quiet film intro.
            guard [.music, .podcast, .audiobook, .video].contains(kind),
                  !ContentDetector.browsers.contains(self.context.bundleID) else { return nil }
            return 30
        }
        engine.makeChain = { [weak self] sr in self?.makeChain(sampleRate: sr) ?? FilterChain(bands: [], preampDB: 0, sampleRate: sr) }
        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            self.engineState = state
            self.live.running = { if case .running = state { return true }; return false }()
            // The engine stopped by itself (no permission / output kept failing): show the toggle
            // as off but keep the reason on screen (stop() leaves that state in place).
            switch state {
            case .needsPermission, .failed: if !self.engine.wantsRunning, self.isOn { self.isOn = false }
            default: break
            }
        }
        dsp.setCrossfade(milliseconds: crossfadeMs)

        library.onFileChanged = { [weak self] preset in self?.fileChangedOnDisk(preset) }
        library.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refreshModified() }
        }.store(in: &cancellables)

        detector.appKinds = appKinds
        detector.genres.enabled = onlineGenres
        detector.onChange = { [weak self] in self?.contextChanged($0) }
        detector.onSpotifyAccess = { [weak self] in self?.spotifyAccess = $0 }

        registerHotKeys()
    }

    /// Called once the UI is up (keeps permission prompts out of snapshot/test runs).
    func startServices() {
        detector.start()
        startOutputMonitor()
        if isOn { applyPower() }
    }

    // MARK: - EQ

    /// Headroom is worked out for the sample rate the chain will actually run at, so a device
    /// change (e.g. AirPods dropping to call mode) can't push a boost past the limit.
    private func makeChain(sampleRate: Double) -> FilterChain {
        FilterChain(bands: working.bands + tone.bands, preampDB: safePreamp(sampleRate: sampleRate), sampleRate: sampleRate)
    }

    /// Loudest point of the curve, pulled to 0 dB with "Prevent clipping" and never above
    /// +12 dB without it — so no file or slider combination can blast the listener.
    private func safePreamp(sampleRate: Double) -> Double {
        var pre = working.preamp
        let peak = EQResponse.peakGain(bands: working.bands + tone.bands, sampleRate: sampleRate) + working.preamp
        let ceiling = preventClipping ? 0.0 : 12.0
        if peak.isFinite, peak > ceiling { pre -= peak - ceiling }
        return pre.isFinite ? pre : 0
    }

    private func eqChanged() {
        appliedPreamp = safePreamp(sampleRate: dsp.sampleRate)
        if case .running = engineState {
            engine.update(chain: makeChain(sampleRate: dsp.sampleRate))
        }
        refreshModified()
        if !restoring { scheduleSave() }
    }

    private func refreshModified() {
        let saved = library.preset(id: activePresetID)
        let modified = saved.map { !Self.sameSound($0, working) } ?? true
        if modified != isModified { isModified = modified }
        if modified { drafts[activePresetID] = working } else { drafts[activePresetID] = nil }
    }

    private static func sameSound(_ a: EQPreset, _ b: EQPreset) -> Bool {
        a.bands == b.bands && abs(a.preamp - b.preamp) < 0.001
    }

    enum SelectReason { case manual, auto, hotkey }

    func select(_ id: String, reason: SelectReason = .manual) {
        guard let preset = library.preset(id: id) else { return }
        if isModified { drafts[activePresetID] = working }
        activePresetID = id
        working = drafts[id] ?? preset
        selectedBand = nil
        if reason != .auto, autoSwitch, context.kind != nil {
            manualOverride = true
            overrideIdentity = context.identity
        }
        if reason == .hotkey { showToast(preset.name) }
        scheduleSave()
    }

    func step(_ delta: Int) {
        let all = library.all
        guard !all.isEmpty else { return }
        let i = all.firstIndex { $0.id == activePresetID } ?? 0
        select(all[(i + delta + all.count) % all.count].id, reason: .hotkey)
    }

    func revert() {
        drafts[activePresetID] = nil
        if let p = library.preset(id: activePresetID) { working = p }
    }

    func resetAll() {
        var w = working
        for i in w.bands.indices { w.bands[i].gain = 0 }
        w.preamp = 0
        working = w
    }

    func setGain(_ i: Int, _ g: Double) {
        guard working.bands.indices.contains(i) else { return }
        working.bands[i].gain = min(24, max(-24, g))
    }

    func addBand(at frequency: Double = 1000) {
        guard working.bands.count < EQPreset.maxBands else { return }
        working.bands.append(EQBand(type: .peak, frequency: frequency, gain: 0, q: 1.41))
        selectedBand = working.bands.count - 1
    }

    func removeBand(_ i: Int) {
        guard working.bands.indices.contains(i) else { return }
        working.bands.remove(at: i)
        selectedBand = nil
    }

    /// Re-expresses any curve as the 31 ISO bands (sounds the same, edits like a graphic EQ).
    func convertTo31() {
        let target = EQResponse.curve(bands: working.bands, frequencies: EQPreset.isoCentres)
        let gains = GraphicFit.fit(target: target)
        var b = EQPreset.flat31()
        for i in b.indices { b[i].gain = gains[i] }
        working.bands = b
    }

    // MARK: - Files

    func importFiles(_ urls: [URL]) {
        let result = library.importFiles(urls)
        fileProblems = result.failures
        if let first = result.imported.first {
            select(first.id)
            showToast(result.imported.count == 1 ? "Imported “\(first.name)”" : "Imported \(result.imported.count) presets")
        }
    }

    /// Save over the current file preset, or create a new one for built-ins.
    func save(as name: String? = nil) {
        do {
            let overwrite = name == nil && working.origin == .file
            let fileName = name ?? (working.origin == .file ? String(activePresetID.dropFirst(5)).replacingOccurrences(of: ".txt", with: "") : working.name + " (custom)")
            if overwrite, activePresetID.hasPrefix("file:"),
               let url = library.url(for: activePresetID), url.pathExtension.lowercased() != "txt" {
                // Non-.txt originals (csv…) are kept; save alongside as .txt.
                let id = try library.save(working, as: fileName, overwrite: false)
                drafts[activePresetID] = nil
                select(id)
            } else {
                let id = try library.save(working, as: fileName, overwrite: overwrite)
                drafts[activePresetID] = nil
                activePresetID = id
                if let p = library.preset(id: id) { working = p }
            }
            showToast("Saved")
        } catch {
            showToast("Couldn't save: \(error.localizedDescription)")
        }
    }

    /// Rename a preset file and keep rules, fallback and favourites pointing at it.
    func renamePreset(_ id: String, to name: String) {
        guard let newID = library.rename(id: id, to: name) else { return }
        rules = rules.map { var r = $0; if r.presetID == id { r.presetID = newID }; return r }
        if fallbackPresetID == id { fallbackPresetID = newID }
        favourites = favourites.map { $0 == id ? newID : $0 }
        if activePresetID == id { select(newID) }
    }

    func deletePreset(_ id: String) {
        library.delete(id: id)
        favourites.removeAll { $0 == id }
        if id == activePresetID { select("builtin:flat") }
    }

    private func fileChangedOnDisk(_ preset: EQPreset) {
        guard preset.id == activePresetID else { return }
        drafts[preset.id] = nil
        working = preset
        showToast("Reloaded “\(preset.name)” from disk")
    }

    // MARK: - Power

    private func applyPower() {
        if isOn {
            hasOnboarded = true
            engine.start()
        } else {
            engine.stop()
        }
    }

    // MARK: - Auto-switch

    private func contextChanged(_ ctx: ListeningContext) {
        let identityChanged = ctx.identity != context.identity
        context = ctx
        if manualOverride, identityChanged, ctx.kind != nil, ctx.identity != overrideIdentity {
            manualOverride = false
        }
        applyAuto()
    }

    func resumeAuto() {
        manualOverride = false
        applyAuto()
    }

    private func applyAuto() {
        guard autoSwitch, !restoring else { autoReason = ""; return }
        guard context.kind != nil else { return }        // silence: keep what's on
        if manualOverride { autoReason = "Your pick — auto resumes on the next song"; return }

        // Skip rules whose preset was deleted, so they don't block the rules below or the fallback.
        if let rule = rules.first(where: { $0.matches(context) && library.preset(id: $0.presetID) != nil }) {
            autoReason = "Matched: \(rule.conditionText)"
            if rule.presetID != activePresetID { select(rule.presetID, reason: .auto) }
            return
        }
        // Genre still being looked up — wait instead of flicking to the fallback.
        if context.kind == .music, context.bundleID == SpotifyClient.bundleID, !context.genreLookupDone {
            autoReason = "Working out the genre…"
            return
        }
        if let fallback = fallbackPresetID, library.preset(id: fallback) != nil {
            autoReason = "No rule matched — using your default"
            if fallback != activePresetID { select(fallback, reason: .auto) }
        } else {
            autoReason = "No rule matched"
        }
    }

    /// "Always use this preset for <genre/kind/artist>" from the Now Playing card.
    func teachRule(field: AutoRule.Field, value: String) {
        rules.removeAll { $0.field == field && $0.value.caseInsensitiveCompare(value) == .orderedSame }
        rules.insert(AutoRule(field: field, value: value, presetID: activePresetID), at: 0)
        manualOverride = false
        showToast("Got it — will use “\(working.name)” for that from now on")
    }

    func setArtistGenre(_ genre: String?) {
        guard !context.artist.isEmpty else { return }
        detector.genres.setOverride(artist: GenreLookup.primaryArtist(context.artist), genre: genre)
        detector.refreshGenre()
    }

    // MARK: - Hot keys

    private func registerHotKeys() {
        hotkeys.register(keyCode: HotKeys.rightArrow) { [weak self] in self?.step(1) }
        hotkeys.register(keyCode: HotKeys.leftArrow) { [weak self] in self?.step(-1) }
        hotkeys.register(keyCode: HotKeys.keyE) { [weak self] in
            guard let self else { return }
            self.isOn.toggle()
            self.showToast(self.isOn ? "EQ on" : "EQ off")
        }
        hotkeys.register(keyCode: HotKeys.keyA) { [weak self] in
            guard let self else { return }
            self.autoSwitch.toggle()
            self.showToast(self.autoSwitch ? "Auto-switch on" : "Auto-switch off")
        }
        for (slot, key) in HotKeys.digits.enumerated() {
            hotkeys.register(keyCode: key) { [weak self] in
                guard let self, slot < self.favourites.count else { return }
                self.select(self.favourites[slot], reason: .hotkey)
            }
        }
    }

    func toggleFavourite(_ id: String) {
        if let i = favourites.firstIndex(of: id) { favourites.remove(at: i) }
        else if favourites.count < 9 { favourites.append(id) }
        else { showToast("You can pin up to 9 favourites") }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { showToast("Couldn't change login item: \(error.localizedDescription)") }
            objectWillChange.send()
        }
    }

    // MARK: - Toast

    func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation(UIStyle.ease) { toast = text }
        let work = DispatchWorkItem { [weak self] in withAnimation(UIStyle.ease) { self?.toast = nil } }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    // MARK: - Persistence

    private struct Persisted: Codable {
        var isOn: Bool
        var activePresetID: String
        var working: EQPreset
        var tone: ToneLayer
        var autoSwitch: Bool
        var rules: [AutoRule]
        var fallbackPresetID: String?
        var appKinds: [String: ContentKind]
        var preventClipping: Bool
        var crossfadeMs: Double
        var onlineGenres: Bool
        var favourites: [String]
        var hasOnboarded: Bool
        var knownOutputs: [String: OutputInfo]?
        var outputGear: [String: String]?
    }

    private static let saveKey = "state.v1"

    private func scheduleSave() {
        guard !restoring else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Dev snapshots set this so demo values never overwrite real settings.
    var persistenceDisabled = false

    private func persist() {
        guard !persistenceDisabled else { return }
        let p = Persisted(isOn: isOn, activePresetID: activePresetID, working: working, tone: tone, autoSwitch: autoSwitch,
                          rules: rules, fallbackPresetID: fallbackPresetID, appKinds: appKinds,
                          preventClipping: preventClipping, crossfadeMs: crossfadeMs, onlineGenres: onlineGenres,
                          favourites: favourites, hasOnboarded: hasOnboarded,
                          knownOutputs: knownOutputs, outputGear: outputGear)
        if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: Self.saveKey) }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.saveKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else {
            eqChanged()
            return
        }
        activePresetID = p.activePresetID
        working = p.working
        tone = p.tone
        autoSwitch = p.autoSwitch
        rules = p.rules
        fallbackPresetID = p.fallbackPresetID
        appKinds = p.appKinds
        preventClipping = p.preventClipping
        crossfadeMs = p.crossfadeMs
        onlineGenres = p.onlineGenres
        favourites = p.favourites
        hasOnboarded = p.hasOnboarded
        knownOutputs = p.knownOutputs ?? [:]
        outputGear = p.outputGear ?? [:]
        isOn = p.isOn
        eqChanged()
    }
}

/// Fast-changing readouts kept apart from AppModel so 30 fps updates only redraw the graph.
final class LiveMeters: ObservableObject {
    @Published private(set) var spectrum: [Float] = []
    @Published private(set) var level: Float = 0
    @Published private(set) var limiting = false
    var running = false {
        didSet {
            guard running != oldValue else { return }
            if !running { spectrum = []; level = 0; limiting = false }
        }
    }

    private let dsp: DSPCore
    private let analyzer = SpectrumAnalyzer()
    private var timer: Timer?
    var frequencies: [Double] { analyzer.frequencies }

    init(dsp: DSPCore) {
        self.dsp = dsp
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Only analyse while a window is actually showing it.
    var visible = true

    private func tick() {
        guard running, visible else { return }
        spectrum = analyzer.update(from: dsp)
        let peak = dsp.outputPeak
        level = max(peak, level * 0.85)
        limiting = dsp.limiterReduction < 0.97
    }
}
