import Accelerate
import Foundation

/// Turns the latest post-EQ audio into a smoothed, log-frequency spectrum for the graph.
final class SpectrumAnalyzer {
    static let pointCount = 160
    let frequencies = EQResponse.logFrequencies(count: SpectrumAnalyzer.pointCount)

    private let log2n: vDSP_Length = 13
    private let n = 8192
    private let fft: FFTSetup
    private var window: [Float]
    private var samples: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var smoothed: [Float]

    init() {
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        samples = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        mags = [Float](repeating: 0, count: n / 2)
        smoothed = [Float](repeating: -100, count: Self.pointCount)
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Returns dBFS per display point (-100…0).
    func update(from dsp: DSPCore) -> [Float] {
        samples.withUnsafeMutableBufferPointer { dsp.latestSamples(into: $0.baseAddress!, count: n) }
        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(n))

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBufferPointer { sp in
                    sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        // Normalise: zrip output is scaled by 2, Hann (normalised) has coherent gain ~0.5.
        var scale = Float(1) / Float(n * n) * 4
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(n / 2))

        let sr = dsp.sampleRate
        let binHz = sr / Double(n)
        let ratio = pow(frequencies[1] / frequencies[0], 0.5)
        var out = [Float](repeating: -100, count: Self.pointCount)
        for (i, f) in frequencies.enumerated() {
            let lo = max(1, Int((f / ratio) / binHz))
            let hi = min(n / 2 - 1, max(lo, Int((f * ratio) / binHz)))
            // Above Nyquist (low sample rates, e.g. Bluetooth headset mode) there is nothing to show.
            guard lo <= hi else { smoothed[i] = -100; out[i] = -100; continue }
            var power: Float = 0
            for b in lo...hi { power = max(power, mags[b]) }
            let db = 10 * log10(max(power, 1e-12))
            // Pink-ish tilt (+3 dB/oct) so music looks level instead of bass-heavy.
            let tilt = Float(3 * log2(f / 1000))
            let target = min(0, max(-100, db + tilt))
            let prev = smoothed[i]
            smoothed[i] = target > prev ? prev + (target - prev) * 0.55 : prev + (target - prev) * 0.12
            out[i] = smoothed[i]
        }
        return out
    }
}
