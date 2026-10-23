import Carbon.HIToolbox
import Foundation
import MuninnCore

public enum HotkeyError: Error, Equatable {
    case unsupported(Hotkey)
    case status(OSStatus)
}

public enum HotkeyParser {
    public static func carbon(_ h: Hotkey) -> (keyCode: UInt32, modifiers: UInt32)? {
        guard let keyCode = keyCodes[h.key.uppercased()] else { return nil }
        var modifiers: UInt32 = 0
        for name in h.modifiers {
            guard let flag = modifierFlags[name.lowercased()] else { return nil }
            modifiers |= flag
        }
        guard modifiers & (UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)) != 0 else { return nil }
        return (UInt32(keyCode), modifiers)
    }

    private static let modifierFlags: [String: UInt32] = [
        "control": UInt32(controlKey),
        "option": UInt32(optionKey),
        "command": UInt32(cmdKey),
        "shift": UInt32(shiftKey),
    ]

    private static let keyCodes: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E,
        "F": kVK_ANSI_F, "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J,
        "K": kVK_ANSI_K, "L": kVK_ANSI_L, "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O,
        "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R, "S": kVK_ANSI_S, "T": kVK_ANSI_T,
        "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X, "Y": kVK_ANSI_Y,
        "Z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4, "F5": kVK_F5, "F6": kVK_F6,
        "F7": kVK_F7, "F8": kVK_F8, "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12,
    ]
}

public enum HotkeyText {
    private static let aliases = [
        "ctrl": "control", "control": "control",
        "opt": "option", "alt": "option", "option": "option",
        "cmd": "command", "command": "command",
        "shift": "shift",
    ]

    public static func format(_ hotkey: Hotkey) -> String {
        (hotkey.modifiers + [hotkey.key]).joined(separator: "+")
    }

    public static func parse(_ text: String) -> Hotkey? {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let key = parts.last, !key.isEmpty else { return nil }
        var modifiers: [String] = []
        for part in parts.dropLast() {
            guard let name = aliases[part.lowercased()] else { return nil }
            if !modifiers.contains(name) { modifiers.append(name) }
        }
        return Hotkey(key: key.uppercased(), modifiers: modifiers)
    }
}

@MainActor
public final class GlobalHotkey {
    private static let signature: OSType = 0x4D4E4E48 // 'MNNH'
    private static var counter: UInt32 = 0

    private let id: UInt32
    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    public init(hotkey: Hotkey, handler: @escaping () -> Void) throws {
        guard let parsed = HotkeyParser.carbon(hotkey) else { throw HotkeyError.unsupported(hotkey) }
        Self.counter += 1
        id = Self.counter
        self.handler = handler

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed
            )
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            guard status == noErr, pressed.signature == GlobalHotkey.signature, pressed.id == hotkey.id else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { hotkey.handler() } }
            return noErr
        }
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )
        guard installed == noErr else { throw HotkeyError.status(installed) }

        let registered = RegisterEventHotKey(
            parsed.keyCode, parsed.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registered == noErr else {
            unregister()
            throw HotkeyError.status(registered)
        }
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    isolated deinit {
        unregister()
    }
}
