import AppKit
import CoreGraphics

// HotkeyTap implements the global push-to-talk hotkey with a CGEventTap. This is
// a Swift port of the Go internal/hotkey logic. It must run in the frontend
// because the event tap requires Accessibility, which the frontend holds.
final class HotkeyTap {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var key: String
    private let lock = NSLock()
    private var pressed = false

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    // Carbon/CGEvent modifier flag bits (match the Go constants).
    private static let flagShift: UInt64 = 1 << 17
    private static let flagControl: UInt64 = 1 << 18
    private static let flagOption: UInt64 = 1 << 19
    private static let flagSecondaryFn: UInt64 = 1 << 23

    private struct Modifier { let keycode: Int64; let flag: UInt64 }

    private static let modifierKeys: [String: Modifier] = [
        "left_control": Modifier(keycode: 59, flag: flagControl),
        "right_control": Modifier(keycode: 62, flag: flagControl),
        "left_option": Modifier(keycode: 58, flag: flagOption),
        "right_option": Modifier(keycode: 61, flag: flagOption),
        "left_shift": Modifier(keycode: 56, flag: flagShift),
        "right_shift": Modifier(keycode: 60, flag: flagShift),
    ]

    private static let regularKeycodes: [String: Int64] = [
        "space": 49,
    ]

    init(key: String) {
        self.key = HotkeyTap.normalize(key)
    }

    func setKey(_ key: String) {
        lock.lock()
        self.key = HotkeyTap.normalize(key)
        lock.unlock()
    }

    var isRunning: Bool { thread != nil }

    /// Starts the event tap on a dedicated thread. Returns false if the tap
    /// could not be created (usually missing Accessibility permission).
    @discardableResult
    func start() -> Bool {
        guard thread == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let me = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
                    me.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let thread = Thread { [weak self] in
            guard let self else { return }
            let loop = CFRunLoopGetCurrent()
            self.runLoop = loop
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "com.voicy.hotkey"
        self.thread = thread
        thread.start()
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = UInt64(event.flags.rawValue)

        guard let (down, matched) = match(keycode: keycode, type: type, flags: flags), matched else { return }

        if down {
            lock.lock()
            let fire = !pressed
            if fire { pressed = true }
            lock.unlock()
            if fire { DispatchQueue.main.async { [weak self] in self?.onPress?() } }
        } else {
            lock.lock()
            let fire = pressed
            if fire { pressed = false }
            lock.unlock()
            if fire { DispatchQueue.main.async { [weak self] in self?.onRelease?() } }
        }
    }

    /// Returns (pressed, matched). matched=false means this event is unrelated
    /// to the configured key and should be ignored.
    private func match(keycode: Int64, type: CGEventType, flags: UInt64) -> (Bool, Bool)? {
        lock.lock()
        let key = self.key
        lock.unlock()

        if key == "fn" {
            if type == .flagsChanged {
                return (flags & HotkeyTap.flagSecondaryFn != 0, true)
            }
            if keycode == 63 {
                return (type == .keyDown, true)
            }
            return (false, false)
        }

        if let modifier = HotkeyTap.modifierKeys[key] {
            if type != .flagsChanged || keycode != modifier.keycode {
                return (false, false)
            }
            return (flags & modifier.flag != 0, true)
        }

        if let expected = HotkeyTap.regularKeycodes[key], keycode == expected {
            switch type {
            case .keyDown: return (true, true)
            case .keyUp: return (false, true)
            default: return (false, false)
            }
        }

        return (false, false)
    }

    private static func normalize(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }
}
