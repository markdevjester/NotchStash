import Carbon

/// Глобальная горячая клавиша через Carbon — не требует разрешений.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var ref: EventHotKeyRef?

    init(id: UInt32, keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        HotKey.handlers[id] = handler
        if !HotKey.installed {
            HotKey.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { HotKey.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let hkID = EventHotKeyID(signature: OSType(0x4246_5552), id: id) // 'BFUR'
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit { if let ref { UnregisterEventHotKey(ref) } }
}
