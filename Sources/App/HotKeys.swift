import Carbon
import Foundation

/// System-wide shortcuts (work while another app is in front). Carbon hot keys need no
/// Accessibility permission.
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { me.handlers[id.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// ⌃⌥⌘ + key.
    func register(keyCode: Int, _ action: @escaping () -> Void) {
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hotID = EventHotKeyID(signature: OSType(0x5442_524B), id: id)   // 'TBRK'
        let mods = UInt32(controlKey | optionKey | cmdKey)
        if RegisterEventHotKey(UInt32(keyCode), mods, hotID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
    }

    static let leftArrow = kVK_LeftArrow
    static let rightArrow = kVK_RightArrow
    static let keyE = kVK_ANSI_E
    static let keyA = kVK_ANSI_A
    static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
}
