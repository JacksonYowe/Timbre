import Accelerate
import Foundation

// Filter maths adapted from SystemEQ for Mac (GPLv3, github.com/denzam/SystemEQ-for-Mac),
// moved to double precision so very low, very narrow bands stay accurate.

struct BiquadCoefficients {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// Robert Bristow-Johnson "Audio EQ Cookbook" designs.
    init(band: EQBand, sampleRate: Double) {
        guard band.enabled, sampleRate > 0, sampleRate.isFinite,
              band.frequency.isFinite, band.gain.isFinite, band.q.isFinite else { self = .identity; return }
        if band.type.usesGain, abs(band.gain) < 0.001 { self = .identity; return }

        let nyquistSafe = sampleRate * 0.49
        let f = min(max(band.frequency, 1), nyquistSafe)
        let q = min(max(band.q, 0.025), 60)
        let A = pow(10, band.gain / 40)
        let w = 2 * Double.pi * f / sampleRate
        let sinW = sin(w), cosW = cos(w)
        let alpha = sinW / (2 * q)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch band.type {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * cosW; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * cosW; a2 = 1 - alpha / A
        case .lowShelf:
            let k = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosW + k)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosW)
            b2 = A * ((A + 1) - (A - 1) * cosW - k)
            a0 = (A + 1) + (A - 1) * cosW + k
            a1 = -2 * ((A - 1) + (A + 1) * cosW)
            a2 = (A + 1) + (A - 1) * cosW - k
        case .highShelf:
            let k = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosW + k)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosW)
            b2 = A * ((A + 1) + (A - 1) * cosW - k)
            a0 = (A + 1) - (A - 1) * cosW + k
            a1 = 2 * ((A - 1) - (A + 1) * cosW)
            a2 = (A + 1) - (A - 1) * cosW - k
        case .lowPass:
            b0 = (1 - cosW) / 2; b1 = 1 - cosW; b2 = (1 - cosW) / 2
            a0 = 1 + alpha; a1 = -2 * cosW; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cosW) / 2; b1 = -(1 + cosW); b2 = (1 + cosW) / 2
            a0 = 1 + alpha; a1 = -2 * cosW; a2 = 1 - alpha
        case .notch:
            b0 = 1; b1 = -2 * cosW; b2 = 1
            a0 = 1 + alpha; a1 = -2 * cosW; a2 = 1 - alpha
        case .bandPass:
            b0 = alpha; b1 = 0; b2 = -alpha
            a0 = 1 + alpha; a1 = -2 * cosW; a2 = 1 - alpha
        case .allPass:
            b0 = 1 - alpha; b1 = -2 * cosW; b2 = 1 + alpha
            a0 = 1 + alpha; a1 = -2 * cosW; a2 = 1 - alpha
        }
        self.init(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// Magnitude response in dB at `frequency`.
    func gainDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let num = nr * nr + ni * ni, den = dr * dr + di * di
        guard num > 0, den > 0 else { return -120 }
        return 10 * log10(num / den)
    }
}

enum EQResponse {
    /// Combined response (dB) of a set of bands at each frequency.
    static func curve(bands: [EQBand], preamp: Double = 0, frequencies: [Double], sampleRate: Double = 48_000) -> [Double] {
        let coeffs = bands.filter { !$0.isNeutral }.map { BiquadCoefficients(band: $0, sampleRate: sampleRate) }
        return frequencies.map { f in
            coeffs.reduce(preamp) { $0 + $1.gainDB(at: f, sampleRate: sampleRate) }
        }
    }

    /// Log-spaced frequencies from 20 Hz to 20 kHz.
    static func logFrequencies(count: Int, low: Double = 20, high: Double = 20_000) -> [Double] {
        let lo = log(low), span = log(high) - lo
        return (0..<count).map { exp(lo + span * Double($0) / Double(count - 1)) }
    }

    /// Loudest point of the combined curve — used to pull the preamp down so boosts can't clip.
    /// Loudest point of the combined curve at a real sample rate: checked from 10 Hz all the
    /// way to just below Nyquist (not only the audible range — content up there still drives the
    /// output), plus every band's own centre, so narrow peaks can't hide between check points.
    /// Bands above Nyquist are clamped exactly as the filters clamp them.
    static func peakGain(bands: [EQBand], sampleRate: Double = 48_000) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        let top = sampleRate * 0.49
        var freqs = logFrequencies(count: 384, low: 10, high: top)
        freqs += bands.filter { $0.enabled && $0.frequency.isFinite }.map { min(max($0.frequency, 10), top) }
        return curve(bands: bands, frequencies: freqs, sampleRate: sampleRate).max() ?? 0
    }

    /// Whether a file is sane to load at all, judged at normal music rates. Low rates (Bluetooth
    /// call mode) fold every treble band onto Nyquist and would flag ordinary treble lifts; playback
    /// at those rates is protected separately, because headroom is worked out at the real rate.
    static func worstPeakGain(bands: [EQBand]) -> Double {
        [44_100.0, 48_000, 96_000].map { peakGain(bands: bands, sampleRate: $0) }.max() ?? 0
    }
}

/// Soft safety limiter on the output so a heavy boost can never blast the listener.
/// Adapted from SystemEQ's OutputSafetyProcessor.
struct OutputLimiter {
    private var ceiling: Float = 0.977   // -0.2 dBFS
    private var release: Float = 0
    private var gain: Float = 1
    private(set) var reduction: Float = 1

    mutating func configure(sampleRate: Double) {
        release = 1 - exp(-1 / Float(max(sampleRate, 1) * 0.12))
        gain = 1
    }

    @inline(__always)
    mutating func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard n > 0 else { return }
        var pl: Float = 0, pr: Float = 0
        vDSP_maxmgv(l, 1, &pl, vDSP_Length(n))
        vDSP_maxmgv(r, 1, &pr, vDSP_Length(n))
        if gain == 1, pl.isFinite, pr.isFinite, max(pl, pr) <= ceiling { reduction = 1; return }

        var g = gain, minG = g
        for i in 0..<n {
            let a = l[i], b = r[i]
            guard a.isFinite, b.isFinite else { l[i] = 0; r[i] = 0; continue }
            let peak = max(abs(a), abs(b))
            let target: Float = peak > ceiling ? ceiling / peak : 1
            g = target < g ? target : g + (target - g) * release
            minG = min(minG, g)
            l[i] = a * g; r[i] = b * g
        }
        gain = g > 0.9999 ? 1 : g
        reduction = minG
    }
}
