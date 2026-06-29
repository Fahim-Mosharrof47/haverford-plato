// MARK: - Skilly
// Extracted from BuddyDictationManager.swift (classic pipeline, now removed).
// This enum is still used by GlobalPushToTalkShortcutMonitor and CompanionManager
// for push-to-talk keyboard shortcut handling in the OpenAI Realtime pipeline.

import AppKit
import CoreGraphics
import Foundation

enum BuddyPushToTalkShortcut {
    enum ShortcutOption {
        case shiftFunction
        case controlOption
        case shiftControl
        case controlOptionSpace
        case shiftControlSpace
        // MARK: - Plato — Key-combo (modifiers + the "0" key). Former default.
        case controlOptionZero
        // MARK: - Plato — Key-combo (ctrl + shift + the "8" key). Current default shortcut.
        case controlShiftEight

        init(storedValue: String) {
            switch storedValue {
            case "shiftFunction":
                self = .shiftFunction
            case "controlOption":
                self = .controlOption
            case "shiftControl":
                self = .shiftControl
            case "controlOptionSpace":
                self = .controlOptionSpace
            case "shiftControlSpace":
                self = .shiftControlSpace
            case "controlOptionZero":
                self = .controlOptionZero
            case "controlShiftEight":
                self = .controlShiftEight
            default:
                self = .controlShiftEight
            }
        }

        var displayText: String {
            switch self {
            case .shiftFunction:
                return "shift + fn"
            case .controlOption:
                return "ctrl + option"
            case .shiftControl:
                return "shift + control"
            case .controlOptionSpace:
                return "ctrl + option + space"
            case .shiftControlSpace:
                return "shift + control + space"
            case .controlOptionZero:
                return "ctrl + option + 0"
            case .controlShiftEight:
                return "ctrl + shift + 8"
            }
        }

        var keyCapsuleLabels: [String] {
            switch self {
            case .shiftFunction:
                return ["shift", "fn"]
            case .controlOption:
                return ["ctrl", "option"]
            case .shiftControl:
                return ["shift", "control"]
            case .controlOptionSpace:
                return ["ctrl", "option", "space"]
            case .shiftControlSpace:
                return ["shift", "control", "space"]
            case .controlOptionZero:
                return ["ctrl", "option", "0"]
            case .controlShiftEight:
                return ["ctrl", "shift", "8"]
            }
        }

        fileprivate var modifierOnlyFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return [.shift, .function]
            case .controlOption:
                return [.control, .option]
            case .shiftControl:
                return [.shift, .control]
            case .controlOptionSpace, .shiftControlSpace, .controlOptionZero, .controlShiftEight:
                return nil
            }
        }

        // MARK: - Plato — Modifier flags for key-combo shortcuts (modifiers + a real key).
        // Name kept for merge hygiene; now covers any key-combo, not only space combos.
        fileprivate var spaceShortcutModifierFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return nil
            case .controlOption:
                return nil
            case .shiftControl:
                return nil
            case .controlOptionSpace:
                return [.control, .option]
            case .shiftControlSpace:
                return [.shift, .control]
            case .controlOptionZero:
                return [.control, .option]
            case .controlShiftEight:
                return [.control, .shift]
            }
        }

        // MARK: - Plato — Key code of the non-modifier key in a key-combo shortcut.
        // nil for the bare modifier-only chords.
        fileprivate var keyComboKeyCode: UInt16? {
            switch self {
            case .shiftFunction, .controlOption, .shiftControl:
                return nil
            case .controlOptionSpace, .shiftControlSpace:
                return 49  // Space
            case .controlOptionZero:
                return 29  // ANSI "0" on the number row
            case .controlShiftEight:
                return 28  // ANSI "8" on the number row
            }
        }
    }

    enum ShortcutTransition {
        case none
        case pressed
        case released
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    static var currentShortcutOption: ShortcutOption {
        // MARK: - Plato — Default is ctrl+shift+8, a real key-combo (modifiers + the "8" key).
        // Bare modifier-only defaults (the original control+option) collided with common chords —
        // Raycast/hyper keys (control+option+command), ctrl+shift+tab, IDE command palettes — and
        // made Plato trigger by itself. Requiring the "8" key means none of those bare-modifier
        // chords can fire it, and the exact-modifier match below rejects supersets like hyper+8.
        let storedShortcutValue = UserDefaults.standard.string(forKey: "pushToTalkShortcut") ?? "controlShiftEight"
        return ShortcutOption(storedValue: storedShortcutValue)
    }
    static let pushToTalkKeyCode: UInt16 = 49 // Space
    static var pushToTalkDisplayText: String { currentShortcutOption.displayText }
    static var pushToTalkTooltipText: String { "push to talk (\(pushToTalkDisplayText))" }

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: event.type) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    // MARK: - Plato — Whether the event tap should SWALLOW this event.
    // The global tap is an active (.defaultTap) tap, so returning nil for an event
    // deletes it before it reaches the frontmost app. We swallow ONLY the active
    // shortcut's own key presses — for a key-combo, the keyDown/keyUp of its key
    // while its modifiers are held (including OS auto-repeats). Without this, the
    // modified keystroke (e.g. ctrl+shift+8) falls through to whatever app is
    // focused, which has no handler for it and plays the macOS "unhandled key"
    // beep on every press/repeat. Requiring the modifiers means a bare keystroke
    // (typing "8") is never swallowed, so the key still types normally. Modifier-
    // only shortcuts have no key to swallow — and bare modifiers must reach other
    // apps — so they never consume anything.
    static func shouldConsumeEvent(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> Bool {
        guard currentShortcutOption.modifierOnlyFlags == nil,
              let keyComboModifierFlags = currentShortcutOption.spaceShortcutModifierFlags,
              let keyComboKeyCode = currentShortcutOption.keyComboKeyCode,
              keyCode == keyComboKeyCode else {
            return false
        }

        let heldModifiers = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.control, .option, .command, .shift, .function])

        switch eventType {
        case .keyDown:
            // Initial press + auto-repeats: the shortcut key with exactly its modifiers.
            return heldModifiers == keyComboModifierFlags
        case .keyUp:
            // Releasing the shortcut key: swallow while mid-press or with modifiers
            // still held, so the matching keyUp also never reaches the app.
            return wasShortcutPreviouslyPressed || heldModifiers == keyComboModifierFlags
        default:
            return false
        }
    }

    private static func shortcutEventType(for eventType: NSEvent.EventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        if let modifierOnlyFlags = currentShortcutOption.modifierOnlyFlags {
            guard shortcutEventType == .flagsChanged else { return .none }

            // MARK: - Plato — Exact modifier match (was a superset `.contains`).
            // A superset match registered a press on ANY chord that merely *included* the
            // modifiers — ctrl+option+⌘/⇧/fn, VoiceOver (whose modifier is ctrl+option), and
            // other apps' ctrl+option+key bindings — which made Plato trigger by itself.
            // Require the held modifiers to be EXACTLY the shortcut's set.
            let relevantHeldModifiers = modifierFlags.intersection([.control, .option, .command, .shift, .function])
            let isShortcutCurrentlyPressed = relevantHeldModifiers == modifierOnlyFlags

            if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
                return .pressed
            }

            if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
                return .released
            }

            return .none
        }

        // MARK: - Plato — Key-combo shortcuts (modifiers + a real key, e.g. ctrl+option+0).
        // Requiring a real key means the bare modifier prefix never fires, so these are immune to
        // chord collisions (ctrl+shift+tab, hyper keys, IDE palettes). Exact-match the modifiers so
        // a superset like the hyper key (control+option+command) + the key can't trigger it either.
        guard let keyComboModifierFlags = currentShortcutOption.spaceShortcutModifierFlags,
              let keyComboKeyCode = currentShortcutOption.keyComboKeyCode else {
            return .none
        }

        let relevantHeldModifiers = modifierFlags.intersection([.control, .option, .command, .shift, .function])
        let matchesModifierFlags = relevantHeldModifiers == keyComboModifierFlags

        if shortcutEventType == .keyDown
            && keyCode == keyComboKeyCode
            && matchesModifierFlags
            && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if shortcutEventType == .keyUp
            && keyCode == keyComboKeyCode
            && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}
