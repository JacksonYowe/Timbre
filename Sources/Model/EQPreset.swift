import Foundation

/// The shape of one EQ band. Raw values double as the EqualizerAPO filter codes we write out.
enum FilterType: String, Codable, CaseIterable, Identifiable {
    case peak = "PK"
    case lowShelf = "LSC"
    case highShelf = "HSC"
    case lowPass = "LPQ"
    case highPass = "HPQ"
    case notch = "NO"
    case bandPass = "BP"
    case allPass = "AP"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .peak: "Bell"
        case .lowShelf: "Low shelf"
        case .highShelf: "High shelf"
        case .lowPass: "Low cut-off (high-cut)"
        case .highPass: "High-pass (low-cut)"
        case .notch: "Notch"
        case .bandPass: "Band-pass"
        case .allPass: "All-pass"
        }
    }

    var shortLabel: String {
        switch self {
        case .peak: "Bell"
        case .lowShelf: "Lo shelf"
        case .highShelf: "Hi shelf"
        case .lowPass: "Hi cut"
        case .highPass: "Lo cut"
        case .notch: "Notch"
        case .bandPass: "Band"
        case .allPass: "All-pass"
        }
    }

    /// Whether the gain knob does anything for this shape.
    var usesGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }
}

struct EQBand: Codable, Hashable {
    var type: FilterType = .peak
    var frequency: Double
    var gain: Double = 0
    var q: Double = EQBand.thirdOctaveQ
    var enabled: Bool = true

    /// Q of a 1/3-octave bell — the classic 31-band graphic EQ width.
    static let thirdOctaveQ = 4.318

    /// Bands that have no audible effect can be skipped when drawing handles.
    var isNeutral: Bool { !enabled || (type.usesGain && abs(gain) < 0.01) }
}

struct EQPreset: Codable, Hashable, Identifiable {
    enum Origin: String, Codable { case builtIn, file }

    var id: String
    var name: String
    var preamp: Double = 0
    var bands: [EQBand]
    var origin: Origin = .builtIn
    /// One-line, plain-English description shown to beginners.
    var blurb: String = ""

    static let maxBands = 64

    /// ISO 1/3-octave centres — the 31 points of a true 31-band EQ.
    static let isoCentres: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630,
        800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
    ]

    static func flat31() -> [EQBand] {
        isoCentres.map { EQBand(type: .peak, frequency: $0, gain: 0, q: EQBand.thirdOctaveQ) }
    }

    /// True when the preset is the standard 31 ISO bells (so the slider view maps 1:1).
    var isGraphic31: Bool {
        bands.count == 31 && zip(bands, Self.isoCentres).allSatisfy {
            $0.type == .peak && abs($0.frequency - $1) < 0.5 && abs($0.q - EQBand.thirdOctaveQ) < 0.01
        }
    }
}

/// The beginner "tone" controls. They sit on top of whichever preset is active, so an
/// automatic genre switch never throws away the listener's own taste.
struct ToneLayer: Codable, Hashable {
    var bass: Double = 0
    var warmth: Double = 0
    var vocals: Double = 0
    var detail: Double = 0
    var air: Double = 0

    static let range: ClosedRange<Double> = -8...8

    var isNeutral: Bool { [bass, warmth, vocals, detail, air].allSatisfy { abs($0) < 0.01 } }

    /// Always five sections (neutral ones are identity filters) so the filter chain keeps
    /// the same structure and slider moves stay click-free.
    var bands: [EQBand] {
        [
            EQBand(type: .lowShelf, frequency: 105, gain: bass, q: 0.7),
            EQBand(type: .peak, frequency: 280, gain: warmth, q: 0.8),
            EQBand(type: .peak, frequency: 2200, gain: vocals, q: 0.9),
            EQBand(type: .peak, frequency: 5500, gain: detail, q: 1.0),
            EQBand(type: .highShelf, frequency: 10500, gain: air, q: 0.7),
        ]
    }
}
