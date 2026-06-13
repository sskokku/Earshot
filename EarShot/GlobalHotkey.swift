//
//  GlobalHotkey.swift
//  EarShot
//

import AppKit
import Carbon.HIToolbox
import os

/// System-wide hotkey registered via Carbon's `RegisterEventHotKey`.
///
/// Picked Carbon over `NSEvent.addGlobalMonitorForEvents` because:
///  - global monitors do not fire while the user is in a secure input field
///    (password prompts), and we need pause to *always* work;
///  - global monitors require Accessibility permission to receive keyDown,
///    whereas hotkeys do not;
///  - Carbon hotkeys still work when the app has no key window and even when
///    another app is fullscreen, which is exactly the ambient-tool requirement
///    in CLAUDE.md's long-run survival checklist.
@MainActor
final class GlobalHotkey {
    /// Cmd+Shift+E. Matches PRD R7 default (pause/resume).
    nonisolated static let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_E)
    nonisolated static let defaultModifiers: UInt32 = UInt32(cmdKey | shiftKey)

    /// Cmd+Shift+B. Bookmark drop hotkey — prompts for a label and
    /// inserts a `bookmarks` row, optionally starting a new ambient
    /// session if none is open.
    nonisolated static let bookmarkKeyCode: UInt32 = UInt32(kVK_ANSI_B)
    nonisolated static let bookmarkModifiers: UInt32 = UInt32(cmdKey | shiftKey)

    private let log = Logger(subsystem: "com.earshot.app", category: "GlobalHotkey")

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void
    private let hotkeyID: UInt32

    /// `hotkeyID` distinguishes multiple `GlobalHotkey` instances under
    /// the same Carbon signature. Two registered hotkeys must use
    /// different ids; otherwise Carbon collapses them onto the same
    /// routing slot and only one handler fires.
    init(hotkeyID: UInt32 = 1, onPress: @escaping () -> Void) {
        self.hotkeyID = hotkeyID
        self.onPress = onPress
    }

    deinit {
        // Carbon handles need explicit teardown. Calling from deinit is safe
        // — Carbon does not require main-thread.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    func register(keyCode: UInt32 = defaultKeyCode, modifiers: UInt32 = defaultModifiers) {
        if hotKeyRef != nil { return }

        // 4-byte signature ("ERSH" → Earshot). Carbon needs SOMETHING unique
        // to match our hotkey ID against the handler routing.
        let signature: OSType = 0x45525348
        let hotKeyID = EventHotKeyID(signature: signature, id: hotkeyID)

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let owner = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon callback fires on the main run loop already, but
                // hop through MainActor explicitly so the closure body can
                // touch main-actor state without a warning.
                Task { @MainActor in
                    owner.onPress()
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &handlerRef
        )

        if installStatus != noErr {
            log.error("InstallEventHandler failed: \(installStatus)")
            return
        }

        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if regStatus != noErr {
            log.error("RegisterEventHotKey failed: \(regStatus)")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil

        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
        handlerRef = nil
    }
}
