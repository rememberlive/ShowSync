import Foundation
import Carbon.HIToolbox

final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    deinit {
        unregister()
    }

    func register() {
        guard ConfigStore.shared.config.role == "main",
              ConfigStore.shared.config.globalHotkeyEnabled else { return }
        guard hotkeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                       eventKind: UInt32(kEventHotKeyPressed))

        let handlerBlock: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotkeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotkeyID)

            if hotkeyID.id == 1 {
                DispatchQueue.main.async {
                    GlobalHotkey.shared.handleHotkey()
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(),
                            handlerBlock,
                            1,
                            &eventType,
                            nil,
                            &eventHandlerRef)

        var hotkeyID = EventHotKeyID(signature: OSType(0x53594E43), id: 1)

        let modifiers: UInt32 = UInt32(controlKey | optionKey | cmdKey)
        let keyCode: UInt32 = 1

        let status = RegisterEventHotKey(keyCode,
                                         modifiers,
                                         hotkeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &hotkeyRef)

        if status == noErr {
            NSLog("[GlobalHotkey] Registered ⌃⌥⌘S")
        } else {
            NSLog("[GlobalHotkey] Failed to register hotkey: %d", status)
            hotkeyRef = nil
        }
    }

    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
            NSLog("[GlobalHotkey] Unregistered")
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }

    private func handleHotkey() {
        let config = ConfigStore.shared.config
        guard config.role == "main" else { return }
        NSLog("[GlobalHotkey] ⌃⌥⌘S pressed, triggering sync")
        SyncEngine.shared.sync(config: config)
    }
}
