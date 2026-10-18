import AppKit
import Carbon.HIToolbox
import QuothCore

enum HotkeyEvent {
    case triggerDown
    case triggerUp
    case escape
    /// Any other key while the trigger is held (e.g. Fn+Arrow) – used to cancel.
    case otherKey
    case pasteLast
    /// Control pressed with the trigger held: this dictation is a Command Mode instruction.
    case commandModifier
    /// ⌥1…⌥9: run transform N.
    case transform(Int)
    /// ⌥O: show the last transform's diff.
    case viewDiff
    /// ⌥S: toggle the Scratchpad.
    case scratchpad
}

/// Global key listener built on a CGEventTap (needs Accessibility + Input Monitoring).
/// Fn is not a normal key: it only shows up as a flagsChanged event with keycode 63.
final class HotkeyMonitor {
    var trigger: HotkeyChoice = .fn
    /// Set by the controller while a dictation is in progress, so Esc can be swallowed.
    var isActive = false
    var onEvent: ((HotkeyEvent) -> Void)?
    var transformHotkeys = true
    var scratchpadHotkey = true
    /// Thumb Talk: CGEvent button number (2 = middle, 3/4 = side buttons), 0 = off.
    var mouseDictateButton = 0
    var mouseEnterButton = 0

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerDown = false
    private var mouseDown = false

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: me
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
    }

    private var triggerKeyCode: Int64 {
        switch trigger {
        case .fn: 63               // kVK_Function
        case .rightOption: 61      // kVK_RightOption
        case .rightCommand: 54     // kVK_RightCommand
        }
    }

    private var triggerFlag: CGEventFlags {
        switch trigger {
        case .fn: .maskSecondaryFn
        case .rightOption: .maskAlternate
        case .rightCommand: .maskCommand
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables slow taps; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == triggerKeyCode {
                let down = event.flags.contains(triggerFlag)
                if down != triggerDown {
                    triggerDown = down
                    emit(down ? .triggerDown : .triggerUp)
                    if down && event.flags.contains(.maskControl) { emit(.commandModifier) }
                }
            } else if (code == 59 || code == 62) && triggerDown && event.flags.contains(.maskControl) {
                // Control added while the trigger is held (Fn+Ctrl / Right Option+Ctrl).
                emit(.commandModifier)
            }
            return Unmanaged.passUnretained(event)

        case .otherMouseDown, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            let down = type == .otherMouseDown
            if mouseDictateButton != 0 && button == mouseDictateButton {
                if down != mouseDown {
                    mouseDown = down
                    emit(down ? .triggerDown : .triggerUp)
                }
                return nil
            }
            if mouseEnterButton != 0 && button == mouseEnterButton {
                if down { DispatchQueue.main.async { TextInserter.sendReturn() } }
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            // ⌃⌘V: paste last transcript.
            if code == Int64(kVK_ANSI_V), flags.contains(.maskCommand), flags.contains(.maskControl),
               !flags.contains(.maskAlternate), !flags.contains(.maskShift) {
                emit(.pasteLast)
                return nil
            }
            // ⌥-shortcuts (Option alone, not while dictating). They would otherwise type ¡ ™ £ … ø ß.
            if !triggerDown && flags.contains(.maskAlternate)
                && !flags.contains(.maskCommand) && !flags.contains(.maskControl) && !flags.contains(.maskShift) {
                let digits: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
                if transformHotkeys, let n = digits[code] { emit(.transform(n)); return nil }
                if transformHotkeys && code == Int64(kVK_ANSI_O) { emit(.viewDiff); return nil }
                if scratchpadHotkey && code == Int64(kVK_ANSI_S) { emit(.scratchpad); return nil }
            }
            if isActive && code == Int64(kVK_Escape) {
                emit(.escape)
                return nil
            }
            if triggerDown { emit(.otherKey) }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func emit(_ e: HotkeyEvent) {
        // Never do work inside the tap callback; macOS kills slow taps.
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }
}
