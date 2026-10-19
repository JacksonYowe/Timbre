import CoreAudio
import Foundation

/// Small typed wrappers around the CoreAudio property API.
enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) -> T {
        var addr = address(selector, scope)
        var out = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &out)
        return status == noErr ? out : value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func array(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, qualifierSize, qualifier, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, qualifierSize, qualifier, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func format(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioStreamBasicDescription? {
        var addr = address(selector)
        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &fmt) == noErr else { return nil }
        return fmt
    }

    static func channelCounts(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [UInt32] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map(\.mNumberChannels)
    }

    static var defaultOutputDevice: AudioDeviceID {
        CA.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0))
    }

    static func deviceName(_ id: AudioDeviceID) -> String {
        string(id, kAudioObjectPropertyName) ?? "Output"
    }

    static func sampleRate(_ id: AudioDeviceID) -> Double {
        get(id, kAudioDevicePropertyNominalSampleRate, default: 48_000.0)
    }

    static func transportType(_ id: AudioDeviceID) -> UInt32 {
        get(id, kAudioDevicePropertyTransportType, default: UInt32(0))
    }

    static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return status == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    /// Bundle IDs of apps currently sending sound to an output (macOS 14.4+ process objects).
    static func appsPlayingAudio() -> [(bundleID: String, pid: pid_t)] {
        let own = getpid()
        return array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { obj in
            let running: UInt32 = get(obj, kAudioProcessPropertyIsRunningOutput, default: 0)
            guard running != 0 else { return nil }
            let pid: pid_t = get(obj, kAudioProcessPropertyPID, default: -1)
            guard pid != own, let bundle = string(obj, kAudioProcessPropertyBundleID), !bundle.isEmpty else { return nil }
            return (bundle, pid)
        }
    }
}
