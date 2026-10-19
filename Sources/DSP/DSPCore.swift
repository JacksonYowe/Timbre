// Portions of this file are adapted from SystemEQ for Mac by denzam and contributors
// (https://github.com/denzam/SystemEQ-for-Mac, GPLv3). Modified for Timbre, October 2026.
// See NOTICE for details. Timbre is licensed under the GNU GPL v3 (see LICENSE).

import Accelerate
import Foundation

/// One immutable set of biquad coefficients plus the running filter memory.
/// Built on the main thread, handed to the audio thread, released back on the main thread.
final class FilterChain {
    let sections: Int
    let preampGain: Float
    private let setupL: vDSP_biquad_Setup?
    private let setupR: vDSP_biquad_Setup?
    private let delayCount: Int
    private let delaysL: UnsafeMutablePointer<Float>
    private let delaysR: UnsafeMutablePointer<Float>

    init(bands: [EQBand], preampDB: Double, sampleRate: Double) {
        let coeffs = bands.map { BiquadCoefficients(band: $0, sampleRate: sampleRate) }
        sections = coeffs.count
        // Any finite cut is safe (the app relies on big cuts to undo big boosts); boosts are capped.
        preampGain = preampDB.isFinite ? Float(pow(10, min(24, preampDB) / 20)) : 1
        var flat = [Double]()
        flat.reserveCapacity(coeffs.count * 5)
        for c in coeffs { flat += [c.b0, c.b1, c.b2, c.a1, c.a2] }
        setupL = sections > 0 ? vDSP_biquad_CreateSetup(flat, vDSP_Length(sections)) : nil
        setupR = sections > 0 ? vDSP_biquad_CreateSetup(flat, vDSP_Length(sections)) : nil
        delayCount = 2 * sections + 2
        delaysL = .allocate(capacity: delayCount)
        delaysR = .allocate(capacity: delayCount)
        delaysL.initialize(repeating: 0, count: delayCount)
        delaysR.initialize(repeating: 0, count: delayCount)
    }

    deinit {
        if let setupL { vDSP_biquad_DestroySetup(setupL) }
        if let setupR { vDSP_biquad_DestroySetup(setupR) }
        delaysL.deallocate()
        delaysR.deallocate()
    }

    /// ⚡ Carry the filter memory over from the chain being replaced, so a small change
    /// (a slider nudge) continues smoothly instead of restarting from silence.
    @inline(__always)
    func inheritState(from other: FilterChain) {
        guard other.sections == sections else { return }
        delaysL.update(from: other.delaysL, count: delayCount)
        delaysR.update(from: other.delaysR, count: delayCount)
    }

    /// ⚡ Real-time safe: no allocation, no locks.
    @inline(__always)
    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        if preampGain != 1 {
            var g = preampGain
            vDSP_vsmul(l, 1, &g, l, 1, vDSP_Length(n))
            vDSP_vsmul(r, 1, &g, r, 1, vDSP_Length(n))
        }
        guard let setupL, let setupR else { return }
        guard Self.isFinite(delaysL, delayCount), Self.isFinite(delaysR, delayCount) else {
            delaysL.update(repeating: 0, count: delayCount)
            delaysR.update(repeating: 0, count: delayCount)
            return
        }
        vDSP_biquad(setupL, delaysL, l, 1, l, 1, vDSP_Length(n))
        vDSP_biquad(setupR, delaysR, r, 1, r, 1, vDSP_Length(n))
    }

    @inline(__always)
    private static func isFinite(_ p: UnsafeMutablePointer<Float>, _ n: Int) -> Bool {
        var m: Float = 0
        vDSP_maxmgv(p, 1, &m, vDSP_Length(n))
        return m.isFinite && m < 1e6
    }
}

/// Everything the audio thread touches. The UI talks to it only through lock-free slots:
/// it drops a new FilterChain into `pending`, the audio thread picks it up at the next buffer,
/// crossfades from the old chain and parks the old one in a `retired` slot for the UI to free.
final class DSPCore {
    static let maxFrames = 4096
    static let ringSize = 16_384
    private static let retiredSlots = 8

    // Slot 0 = pending chain, 1… = retired chains (all Unmanaged<FilterChain> pointers).
    private let slots: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    // 🔧 Shared scalars.
    private let bypassTarget = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let fadeFramesSetting = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let counters = UnsafeMutablePointer<Int64>.allocate(capacity: 4)   // callbacks, lastAudible, ringWrite, -
    private let meters = UnsafeMutablePointer<Float>.allocate(capacity: 4)     // inPeak, outPeak, limiter, -

    // Audio-thread-only state.
    private var current: Unmanaged<FilterChain>?
    private var fading: Unmanaged<FilterChain>?
    private var fadePos = 0
    private var fadeLength = 1
    private var bypassMix: Float = 0
    private var limiter = OutputLimiter()
    private let fadeL = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let fadeR = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let dryL = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let dryR = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    private let ramp = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
    let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringSize)

    private(set) var sampleRate: Double = 48_000

    init() {
        slots = .allocate(capacity: 1 + Self.retiredSlots)
        slots.initialize(repeating: nil, count: 1 + Self.retiredSlots)
        bypassTarget.initialize(to: 0)
        fadeFramesSetting.initialize(to: 1440)
        counters.initialize(repeating: 0, count: 4)
        meters.initialize(repeating: 0, count: 4)
        ring.initialize(repeating: 0, count: Self.ringSize)
    }

    // MARK: - Main-thread API

    /// Called while the audio device is stopped.
    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        limiter.configure(sampleRate: sampleRate)
        current?.release(); current = nil
        fading?.release(); fading = nil
        collectGarbage()
    }

    /// Queue a new chain. Safe to call at any rate (slider drags).
    func install(_ chain: FilterChain) {
        collectGarbage()
        let raw = Unmanaged.passRetained(chain).toOpaque()
        if let replaced = TBExchangePtr(slotPtr(0), raw) {
            Unmanaged<FilterChain>.fromOpaque(replaced).release()   // never reached the audio thread
        }
    }

    func setBypassed(_ on: Bool) { TBStoreFloat(bypassTarget, on ? 1 : 0) }
    func setCrossfade(milliseconds: Double) {
        TBStore64(fadeFramesSetting, Int64(max(1, milliseconds / 1000 * sampleRate)))
    }

    /// Free chains the audio thread has finished with.
    func collectGarbage() {
        for i in 1...Self.retiredSlots {
            if let p = TBExchangePtr(slotPtr(i), nil) {
                Unmanaged<FilterChain>.fromOpaque(p).release()
            }
        }
    }

    var callbackCount: Int64 { TBLoad64(counters) }
    var lastAudibleHostTime: UInt64 { UInt64(bitPattern: TBLoad64(counters + 1)) }
    /// When the input last had any sound in it (distantPast if never).
    var lastAudibleDate: Date {
        let t = lastAudibleHostTime
        guard t > 0 else { return .distantPast }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ago = Double(mach_absolute_time() &- t) * Double(info.numer) / Double(info.denom) / 1e9
        return Date().addingTimeInterval(-ago)
    }
    var ringWriteCount: Int64 { TBLoad64(counters + 2) }
    /// Every IOProc call, including buffers the engine had to reject.
    var deviceCallbackCount: Int64 { TBLoad64(counters + 3) }
    @inline(__always) func noteDeviceCallback() { TBAdd64(counters + 3, 1) }
    var inputPeak: Float { TBLoadFloat(meters) }
    var outputPeak: Float { TBLoadFloat(meters + 1) }
    var limiterReduction: Float { TBLoadFloat(meters + 2) }

    /// Copy the most recent `count` post-EQ mono samples (for the spectrum view).
    func latestSamples(into dest: UnsafeMutablePointer<Float>, count: Int) {
        let end = Int(ringWriteCount)
        for i in 0..<count {
            let idx = (end - count + i) & (Self.ringSize - 1)
            dest[i] = end - count + i >= 0 ? ring[idx] : 0
        }
    }

    // MARK: - ⚡ Audio thread

    @inline(__always)
    func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard n > 0, n <= Self.maxFrames else { return }
        TBAdd64(counters, 1)

        var inPeak: Float = 0, rp: Float = 0
        vDSP_maxmgv(l, 1, &inPeak, vDSP_Length(n))
        vDSP_maxmgv(r, 1, &rp, vDSP_Length(n))
        inPeak = max(inPeak, rp)
        if inPeak > 0.0001 { TBStore64(counters + 1, Int64(bitPattern: mach_absolute_time())) }
        TBStoreFloat(meters, inPeak.isFinite ? inPeak : 0)

        adoptPendingChain()

        let target = TBLoadFloat(bypassTarget)
        let needDry = bypassMix > 0 || target > 0
        if needDry {
            dryL.update(from: l, count: n)
            dryR.update(from: r, count: n)
        }

        if let fading {
            fadeL.update(from: l, count: n)
            fadeR.update(from: r, count: n)
            fading._withUnsafeGuaranteedRef { $0.process(fadeL, fadeR, n) }
        }
        current?._withUnsafeGuaranteedRef { $0.process(l, r, n) }

        if fading != nil {
            // Equal-gain linear crossfade old → new over fadeLength frames.
            let start = Float(fadePos) / Float(fadeLength)
            let step = 1 / Float(fadeLength)
            var s = start, st = step
            vDSP_vramp(&s, &st, ramp, 1, vDSP_Length(n))
            var lo: Float = 0, hi: Float = 1
            vDSP_vclip(ramp, 1, &lo, &hi, ramp, 1, vDSP_Length(n))
            mix(dest: l, a: fadeL, b: l, t: ramp, n)
            mix(dest: r, a: fadeR, b: r, t: ramp, n)
            fadePos += n
            if fadePos >= fadeLength { retire(&self.fading) }
        }

        if needDry {
            // Move toward the target over ~40 ms so A/B switching never clicks.
            let from = bypassMix
            let to = target
            let perSample = Float(1 / (0.04 * sampleRate))
            var s = from, st = to > from ? perSample : -perSample
            vDSP_vramp(&s, &st, ramp, 1, vDSP_Length(n))
            var lo = min(from, to), hi = max(from, to)
            vDSP_vclip(ramp, 1, &lo, &hi, ramp, 1, vDSP_Length(n))
            // ramp = amount of dry signal
            mix(dest: l, a: l, b: dryL, t: ramp, n)
            mix(dest: r, a: r, b: dryR, t: ramp, n)
            bypassMix = abs(ramp[n - 1] - to) < 0.002 ? to : ramp[n - 1]
        }

        limiter.process(l, r, n)

        var outPeak: Float = 0
        vDSP_maxmgv(l, 1, &outPeak, vDSP_Length(n))
        vDSP_maxmgv(r, 1, &rp, vDSP_Length(n))
        TBStoreFloat(meters + 1, max(outPeak, rp))
        TBStoreFloat(meters + 2, limiter.reduction)

        // Post-EQ mono into the analyser ring.
        var w = Int(TBLoad64(counters + 2))
        for i in 0..<n {
            ring[w & (Self.ringSize - 1)] = (l[i] + r[i]) * 0.5
            w += 1
        }
        TBStore64(counters + 2, Int64(w))
    }

    @inline(__always)
    private func mix(dest: UnsafeMutablePointer<Float>, a: UnsafePointer<Float>, b: UnsafePointer<Float>,
                     t: UnsafePointer<Float>, _ n: Int) {
        // dest = a + (b - a) * t
        for i in 0..<n { dest[i] = a[i] + (b[i] - a[i]) * t[i] }
    }

    @inline(__always)
    private func adoptPendingChain() {
        guard TBLoadPtr(slotPtr(0)) != nil else { return }
        // Let a crossfade finish before starting the next one — cutting it short jumps (clicks).
        // The pending slot always holds the newest chain, so nothing is lost while we wait.
        guard fading == nil else { return }
        guard let raw = TBExchangePtr(slotPtr(0), nil) else { return }
        let incoming = Unmanaged<FilterChain>.fromOpaque(raw)
        if let current {
            incoming._withUnsafeGuaranteedRef { new in
                current._withUnsafeGuaranteedRef { new.inheritState(from: $0) }
            }
            fading = current
            fadeLength = Int(TBLoad64(fadeFramesSetting))
            fadePos = 0
        }
        current = incoming
    }

    @inline(__always)
    private func retire(_ chain: inout Unmanaged<FilterChain>?) {
        guard let c = chain else { return }
        let raw = c.toOpaque()
        for i in 1...Self.retiredSlots where TBCompareExchangePtr(slotPtr(i), nil, raw) {
            chain = nil
            return
        }
        // All slots full (UI hasn't collected): keep it alive rather than free it here.
    }

    @inline(__always)
    private func slotPtr(_ i: Int) -> UnsafeMutablePointer<UnsafeMutableRawPointer?> { slots + i }
}
