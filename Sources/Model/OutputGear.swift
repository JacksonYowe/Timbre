import CoreAudio
import Foundation

/// A place sound can come out of, and how it's connected.
struct OutputInfo: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case speakers, headphoneJack, bluetooth, usb, hdmi, airplay, other

        var label: String {
            switch self {
            case .speakers: "Built-in speakers"
            case .headphoneJack: "Headphone jack (3.5 mm)"
            case .bluetooth: "Bluetooth"
            case .usb: "USB"
            case .hdmi: "HDMI / DisplayPort"
            case .airplay: "AirPlay"
            case .other: "Other"
            }
        }

        var symbol: String {
            switch self {
            case .speakers: "laptopcomputer"
            case .headphoneJack: "cable.connector"
            case .bluetooth: "dot.radiowaves.left.and.right"
            case .usb: "cable.connector.horizontal"
            case .hdmi: "tv"
            case .airplay: "airplayaudio"
            case .other: "speaker.wave.2"
            }
        }

        /// The jack can't tell Timbre what's plugged in, so it asks each time.
        var cantIdentify: Bool { self == .headphoneJack }
    }

    var uid: String
    var name: String
    var kind: Kind
    var id: String { uid }

    static func current() -> OutputInfo? {
        let dev = CA.defaultOutputDevice
        guard dev != kAudioObjectUnknown, let uid = CA.string(dev, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = CA.deviceName(dev)
        return OutputInfo(uid: uid, name: name, kind: kind(dev, name: name))
    }

    private static func kind(_ dev: AudioDeviceID, name: String) -> Kind {
        switch CA.transportType(dev) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .hdmi
        case kAudioDeviceTransportTypeAirPlay: return .airplay
        case kAudioDeviceTransportTypeBuiltIn:
            // Apple silicon shows the jack as its own "External Headphones" device; Intel Macs
            // switch the speaker device's data source to 'hdpn'.
            let source: UInt32 = CA.get(dev, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, default: 0)
            if name.localizedCaseInsensitiveContains("headphone") || source == 0x6864_706E { return .headphoneJack }
            return .speakers
        default: return .other
        }
    }
}

/// Gear = a set of tuned presets ("Flat · X", "Rock · X", …). nil = no correction (built-ins).
enum Gear {
    static let flatPrefix = "Flat · "

    /// Every IEM/headphone that has a "Flat · <name>" preset.
    static func all(in library: PresetLibrary) -> [String] {
        library.files.compactMap { p in p.name.hasPrefix(flatPrefix) ? String(p.name.dropFirst(flatPrefix.count)) : nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Which gear a preset id belongs to (nil = built-in / not gear-specific).
    static func of(_ id: String) -> String? {
        guard id.hasPrefix("file:"), let r = id.range(of: " · ") else { return nil }
        return String(id[r.upperBound...]).replacingOccurrences(of: ".txt", with: "")
    }

    /// The same sound on different gear: "Rock · A" → "Rock · B", "builtin:rock" ↔ "Rock · B".
    static func translate(_ id: String, to gear: String?, library: PresetLibrary) -> String {
        let genres = [("builtin:flat", "Flat")] + IEMCorrection.genrePresets.map { ($0.id, $0.name) }
        var genre: (String, String)?
        if let g = genres.first(where: { $0.0 == id }) { genre = g }
        else if id.hasPrefix("file:") {
            let name = String(id.dropFirst(5)).replacingOccurrences(of: ".txt", with: "")
            genre = genres.first { name.hasPrefix($0.1 + " · ") }
        }
        guard let genre else { return id }                 // a preset that isn't part of a gear set
        guard let gear else { return genre.0 }
        let target = "file:\(genre.1) · \(gear).txt"
        return library.preset(id: target) != nil ? target : id
    }

    /// Best guess at which gear a device is, from its name ("Example IEM BT" → "Example IEM").
    static func guess(for device: String, among gears: [String]) -> String? {
        let d = GenreLookup.norm(device)
        return gears.first { g in
            let n = GenreLookup.norm(g)
            return !n.isEmpty && (d.contains(n) || n.contains(d))
        }
    }
}
