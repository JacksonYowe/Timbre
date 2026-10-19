import CoreAudio
import Foundation

extension AppModel {
    /// Gear currently in use, judged from what the presets point at.
    var currentGear: String? {
        Gear.of(fallbackPresetID ?? "") ?? Gear.of(activePresetID) ?? rules.lazy.compactMap { Gear.of($0.presetID) }.first
    }

    /// Point Flat, auto-switch, favourites and the playing preset at another gear's presets.
    func switchGear(to gear: String?, announce: Bool = true) {
        let lib = library
        rules = rules.map { var r = $0; r.presetID = Gear.translate(r.presetID, to: gear, library: lib); return r }
        fallbackPresetID = fallbackPresetID.map { Gear.translate($0, to: gear, library: lib) }
        favourites = favourites.map { Gear.translate($0, to: gear, library: lib) }
        let next = Gear.translate(activePresetID, to: gear, library: lib)
        if next != activePresetID { select(next, reason: .auto) }
        if announce { showToast(gear.map { "Tuned for \($0)" } ?? "No headphone correction") }
    }

    /// Called whenever the Mac's output changes.
    func outputChanged() {
        guard let out = OutputInfo.current() else { return }
        let isNew = knownOutputs[out.uid] == nil
        knownOutputs[out.uid] = out
        currentOutput = out
        let gears = Gear.all(in: library)

        if let saved = outputGear[out.uid] {
            let gear = saved.isEmpty ? nil : saved
            if out.kind.cantIdentify {
                // Can't know what's in the jack — use last choice but ask.
                gearQuestion = out
            }
            if gear != currentGear { switchGear(to: gear) }
            return
        }
        // First time on this output.
        if let guess = Gear.guess(for: out.name, among: gears) {
            outputGear[out.uid] = guess
            if guess != currentGear { switchGear(to: guess) }
            return
        }
        if out.kind == .speakers || out.kind == .hdmi || out.kind == .airplay {
            outputGear[out.uid] = ""   // speakers/TVs: no IEM correction
            if currentGear != nil { switchGear(to: nil) }
            return
        }
        if isNew || out.kind.cantIdentify { gearQuestion = out }
    }

    /// The listener answered "what is this?" for an output.
    func assignGear(_ gear: String?, to out: OutputInfo) {
        outputGear[out.uid] = gear ?? ""
        if gearQuestion?.uid == out.uid { gearQuestion = nil }
        if currentOutput?.uid == out.uid, gear != currentGear { switchGear(to: gear) }
    }

    func startOutputMonitor() {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            // Let the device finish appearing (names/UIDs settle a moment after the switch).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.outputChanged() }
        }
        outputChanged()
    }
}
