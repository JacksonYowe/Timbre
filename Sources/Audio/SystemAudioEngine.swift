// Portions of this file are adapted from SystemEQ for Mac by denzam and contributors
// (https://github.com/denzam/SystemEQ-for-Mac, GPLv3). Modified for Timbre, October 2026.
// See NOTICE for details. Timbre is licensed under the GNU GPL v3 (see LICENSE).

import Accelerate
import AppKit
import CoreAudio
import Foundation

// System-wide capture via a Core Audio process tap (macOS 14.4+): every app's sound is
// tapped and muted, run through the EQ, and played on the real output through a private
// aggregate device. No virtual driver (BlackHole) needed.
// Tap/aggregate setup adapted from SystemEQ for Mac's ProcessTapEngine.

final class SystemAudioEngine {
    enum State: Equatable {
        case off
        case starting
        case running(device: String, sampleRate: Double)
        case needsPermission
        case failed(String)
    }

    let dsp: DSPCore
    /// True when a real music/video player says it is playing — used to tell "no permission"
    /// (tap is silent although something is playing) from "nothing is playing".
    /// How many seconds of pure silence to allow before assuming it's a permission problem, or
    /// nil when nothing is reliably playing.
    var silenceAllowance: (() -> Int?)?
    /// Builds a chain for the given sample rate (the model's current EQ).
    var makeChain: ((Double) -> FilterChain)?
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .off { didSet { if state != oldValue { onStateChange?(state) } } }
    /// False once the engine has given up by itself (no permission / keeps failing).
    private(set) var wantsRunning = false
    private var recentRestarts: [Date] = []
    private var lastDeviceCallbacks: Int64 = 0
    private var rejectedTicks = 0
    private var silentPlayingTicks = 0
    private var gaveUp = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var renderContext: RenderContext?

    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var restartWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var lastCallbackCount: Int64 = 0
    private var stalledTicks = 0
    private var heardAudioThisRun = false
    private var wakeObserver: NSObjectProtocol?

    init(dsp: DSPCore) {
        self.dsp = dsp
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleRestart(after: 1.0) }
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.scheduleRestart(after: 0.3)
        }
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) { [weak self] in
            guard let self, self.wantsRunning else { return }
            // Our output vanished (headphones unplugged) — rebuild on whatever is default now.
            let alive = CA.array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).contains(self.outputDevice)
            if !alive { self.scheduleRestart(after: 0.3) }
        }
    }

    // MARK: - Control

    func start() {
        wantsRunning = true
        gaveUp = false
        recentRestarts = []
        heardAudioThisRun = false   // only here: internal rebuilds (wake, output change) keep it
        restart()
    }

    func stop() {
        wantsRunning = false
        restartWork?.cancel()
        teardown()
        // Keep the reason visible only if the engine gave up on its own.
        if !gaveUp { state = .off }
    }

    /// Stop for good and hand the Mac's sound back, explaining why.
    private func giveUp(_ final: State) {
        gaveUp = true
        wantsRunning = false
        restartWork?.cancel()
        teardown()
        state = final
    }

    /// Push a freshly built EQ into the running engine.
    func update(chain: FilterChain) { dsp.install(chain) }

    /// `failure`: the restart is because something broke (stall), not a normal device change.
    private func scheduleRestart(after delay: Double, failure: Bool = false) {
        guard wantsRunning else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restart(failure: failure) }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Records a failure; true when there have been too many lately and the engine gave up.
    private func tooManyFailures() -> Bool {
        let now = Date()
        recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < 30 } + [now]
        guard recentRestarts.count > 4 else { return false }
        recentRestarts = []
        giveUp(.failed("The output kept failing, so Timbre stopped and gave your sound back. Try turning it on again."))
        return true
    }

    private func restart(failure: Bool = false) {
        guard wantsRunning else { return }
        // Only failures count toward giving up — plugging in headphones or a call switching
        // the AirPods' sample rate are normal and can happen several times a minute.
        if failure, tooManyFailures() { return }
        teardown()
        state = .starting
        switch build() {
        case .success(let info):
            state = .running(device: info.device, sampleRate: info.sampleRate)
            startWatchdog()
        case .failure(let message):
            teardown()
            if !tooManyFailures() { state = .failed(message) }
        }
    }

    // MARK: - Build / teardown

    private struct StartInfo { let device: String; let sampleRate: Double }
    private enum BuildResult { case success(StartInfo), failure(String) }

    private func build() -> BuildResult {
        let device = CA.defaultOutputDevice
        guard device != kAudioObjectUnknown, let uid = CA.string(device, kAudioDevicePropertyDeviceUID) else {
            return .failure("No sound output found.")
        }
        outputDevice = device

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: CA.ownProcessObject().map { [$0] } ?? [])
        description.name = "Timbre EQ"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr, newTap != kAudioObjectUnknown else {
            return .failure("macOS refused the audio tap (\(status)).")
        }
        tapID = newTap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Timbre EQ",
            kAudioAggregateDeviceUIDKey: "timbre.eq.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard status == noErr, newAggregate != kAudioObjectUnknown else {
            return .failure("Couldn't open the output (\(status)).")
        }
        aggregateID = newAggregate

        // Ask for a small buffer — lower latency, which matters when watching video.
        var frames: UInt32 = 256
        var addr = CA.address(kAudioDevicePropertyBufferFrameSize)
        _ = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        guard let tapFormat = CA.format(tapID, kAudioTapPropertyFormat),
              let inputIndex = findTapStream(tapFormat: tapFormat, physicalInputs: CA.channelCounts(device, scope: kAudioObjectPropertyScopeInput).reduce(0, +))
        else { return .failure("Unsupported audio layout on \(CA.deviceName(device)).") }

        let sampleRate = tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : CA.sampleRate(device)
        dsp.prepare(sampleRate: sampleRate)
        if let chain = makeChain?(sampleRate) { dsp.install(chain) }

        let context = RenderContext(dsp: dsp, inputIndex: inputIndex)
        renderContext = context
        status = AudioDeviceCreateIOProcID(aggregateID, timbreIOProc, Unmanaged.passUnretained(context).toOpaque(), &ioProcID)
        guard status == noErr, let ioProcID else { return .failure("Couldn't start audio (\(status)).") }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { return .failure("Couldn't start audio (\(status)).") }

        listen(device, kAudioDevicePropertyNominalSampleRate, temporary: true) { [weak self] in
            self?.scheduleRestart(after: 0.2)
        }
        listen(device, kAudioDevicePropertyDeviceIsAlive, temporary: true) { [weak self] in
            self?.scheduleRestart(after: 0.2)
        }
        return .success(StartInfo(device: CA.deviceName(device), sampleRate: sampleRate))
    }

    /// Which input stream of the aggregate carries the tap (the physical device may add mic streams).
    private func findTapStream(tapFormat: AudioStreamBasicDescription, physicalInputs: UInt32) -> Int? {
        let streams = CA.array(aggregateID, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        let counts = CA.channelCounts(aggregateID, scope: kAudioDevicePropertyScopeInput)
        guard !streams.isEmpty, streams.count == counts.count else { return nil }
        let candidates = streams.indices.filter { i in
            guard counts[i] == 2, let f = CA.format(streams[i], kAudioStreamPropertyVirtualFormat) else { return false }
            return f.mSampleRate == tapFormat.mSampleRate && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        }
        if candidates.count == 1 { return candidates[0] }
        // Several stereo inputs: the tap starts right after the device's own input channels.
        let wanted = physicalInputs + 1
        return candidates.first { CA.get(streams[$0], kAudioStreamPropertyStartingChannel, default: UInt32(0)) == wanted }
            ?? candidates.last
    }

    private func teardown() {
        watchdog?.invalidate(); watchdog = nil
        removeListeners(temporaryOnly: true)
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        renderContext = nil
        dsp.collectGarbage()
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        lastCallbackCount = dsp.callbackCount
        lastDeviceCallbacks = dsp.deviceCallbackCount
        stalledTicks = 0
        rejectedTicks = 0
        silentPlayingTicks = 0
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        dsp.collectGarbage()
        guard case .running = state else { return }
        let processed = dsp.callbackCount, device = dsp.deviceCallbackCount
        let deviceAlive = device != lastDeviceCallbacks
        let processing = processed != lastCallbackCount
        lastCallbackCount = processed
        lastDeviceCallbacks = device
        stalledTicks = deviceAlive ? 0 : stalledTicks + 1
        rejectedTicks = deviceAlive && !processing ? rejectedTicks + 1 : 0
        if stalledTicks >= 3 {   // device stopped calling us — rebuild
            scheduleRestart(after: 0, failure: true)
            return
        }
        if rejectedTicks >= 3 {  // called, but every buffer is unusable: don't sit there muted
            giveUp(.failed("This output sends audio in a format Timbre can't process, so it gave your sound back."))
            return
        }
        if Date().timeIntervalSince(dsp.lastAudibleDate) < 1.5 { heardAudioThisRun = true }
        // Safety net: without permission the tap is pure silence while the real output is muted.
        // Only judge that while a real player says it's playing (apps like Discord or a browser tab
        // hold the output open in silence), and only if it lasts 8 s.
        if !heardAudioThisRun, let allowed = silenceAllowance?() {
            silentPlayingTicks += 1
            if silentPlayingTicks >= allowed { giveUp(.needsPermission) }
        } else {
            silentPlayingTicks = 0
        }
    }

    // MARK: - Listeners

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, temporary: Bool = false,
                        _ handler: @escaping () -> Void) {
        var addr = CA.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &addr, .main, block) == noErr else { return }
        if temporary {
            listeners.append((object, addr, block))
        } else {
            listeners.insert((object, addr, block), at: 0)
            permanentListeners += 1
        }
    }

    private var permanentListeners = 0

    private func removeListeners(temporaryOnly: Bool) {
        let keep = temporaryOnly ? permanentListeners : 0
        while listeners.count > keep {
            var (object, addr, block) = listeners.removeLast()
            AudioObjectRemovePropertyListenerBlock(object, &addr, .main, block)
        }
    }
}

// MARK: - ⚡ Render

private final class RenderContext {
    let dsp: DSPCore
    let inputIndex: Int
    let left = UnsafeMutablePointer<Float>.allocate(capacity: DSPCore.maxFrames)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: DSPCore.maxFrames)

    init(dsp: DSPCore, inputIndex: Int) {
        self.dsp = dsp
        self.inputIndex = inputIndex
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    @inline(__always)
    func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        dsp.noteDeviceCallback()
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard inputIndex < inputs.count, inputs[inputIndex].mNumberChannels == 2,
              let data = inputs[inputIndex].mData else { return silence(outputs) }
        let frames = Int(inputs[inputIndex].mDataByteSize) / (2 * MemoryLayout<Float>.size)
        guard frames > 0, frames <= DSPCore.maxFrames else { return silence(outputs) }

        // Deinterleave → EQ → write to every output channel pair.
        let interleaved = data.assumingMemoryBound(to: Float.self)
        var zero: Float = 0
        vDSP_vsadd(interleaved, 2, &zero, left, 1, vDSP_Length(frames))
        vDSP_vsadd(interleaved + 1, 2, &zero, right, 1, vDSP_Length(frames))
        dsp.process(left, right, frames)

        var totalChannels = 0
        for buffer in outputs { totalChannels += Int(buffer.mNumberChannels) }
        var channelIndex = 0
        for buffer in outputs {
            guard let out = buffer.mData else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let outFrames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            let n = min(frames, outFrames)
            let dest = out.assumingMemoryBound(to: Float.self)
            for ch in 0..<channels {
                // Stereo goes to the first two channels; mono outputs get the sum.
                if totalChannels == 1 {
                    var half: Float = 0.5
                    vDSP_vasm(left, 1, right, 1, &half, dest, 1, vDSP_Length(n))
                } else if channelIndex == 0 {
                    vDSP_vsadd(left, 1, &zero, dest + ch, vDSP_Stride(channels), vDSP_Length(n))
                } else if channelIndex == 1 {
                    vDSP_vsadd(right, 1, &zero, dest + ch, vDSP_Stride(channels), vDSP_Length(n))
                } else {
                    vDSP_vclr(dest + ch, vDSP_Stride(channels), vDSP_Length(n))
                }
                channelIndex += 1
            }
            if outFrames > n { vDSP_vclr(dest + n * channels, 1, vDSP_Length((outFrames - n) * channels)) }
        }
    }

    @inline(__always)
    private func silence(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for b in buffers { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    }
}

private func timbreIOProc(_: AudioObjectID, _: UnsafePointer<AudioTimeStamp>, _ input: UnsafePointer<AudioBufferList>,
                          _: UnsafePointer<AudioTimeStamp>, _ output: UnsafeMutablePointer<AudioBufferList>,
                          _: UnsafePointer<AudioTimeStamp>, _ client: UnsafeMutableRawPointer?) -> OSStatus {
    guard let client else { return noErr }
    Unmanaged<RenderContext>.fromOpaque(client).takeUnretainedValue().render(input, output)
    return noErr
}
