import AppKit
import CoreGraphics

// HotkeyTap implements the global push-to-talk hotkey with a CGEventTap. This is
// a Swift port of the Go internal/hotkey logic. It must run in the frontend
// because the event tap requires Accessibility, which the frontend holds.
final class HotkeyTap {
    var onPress: ((HotkeyMapping) -> Void)?
    var onRelease: ((HotkeyMapping) -> Void)?

    private var mappings: [HotkeyMapping]
    private let lock = NSLock()
    private var pressedMappings = Set<String>()
    private var heldKeys = Set<String>()

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    // Carbon/CGEvent modifier flag bits (match the Go constants).
    private static let flagShift: UInt64 = 1 << 17
    private static let flagControl: UInt64 = 1 << 18
    private static let flagOption: UInt64 = 1 << 19
    private static let flagCommand: UInt64 = 1 << 20
    private static let flagSecondaryFn: UInt64 = 1 << 23

    private struct Modifier { let keycode: Int64; let flag: UInt64 }

    private static let modifierKeys: [String: Modifier] = [
        "left_control": Modifier(keycode: 59, flag: flagControl),
        "right_control": Modifier(keycode: 62, flag: flagControl),
        "left_option": Modifier(keycode: 58, flag: flagOption),
        "right_option": Modifier(keycode: 61, flag: flagOption),
        "left_command": Modifier(keycode: 55, flag: flagCommand),
        "right_command": Modifier(keycode: 54, flag: flagCommand),
        "left_shift": Modifier(keycode: 56, flag: flagShift),
        "right_shift": Modifier(keycode: 60, flag: flagShift),
    ]

    private static let regularKeycodes: [String: Int64] = [
        "space": 49,
    ]

    init(key: String) {
        self.mappings = [HotkeyMapping(id: "default", keys: HotkeyTap.normalize(key), mode: "long_press", label: key)]
    }

    func setMappings(_ mappings: [HotkeyMapping]) {
        lock.lock()
        self.mappings = mappings.map { mapping in
            HotkeyMapping(
                id: mapping.id,
                keys: HotkeyTap.normalize(mapping.keys),
                mode: mapping.mode,
                label: mapping.label
            )
        }
        self.pressedMappings.removeAll()
        self.heldKeys.removeAll()
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

        updateHeldKeys(keycode: keycode, type: type, flags: flags)

        let events = mappingEvents()
        for event in events {
            switch event.kind {
            case .press:
                DispatchQueue.main.async { [weak self] in self?.onPress?(event.mapping) }
            case .release:
                DispatchQueue.main.async { [weak self] in self?.onRelease?(event.mapping) }
            }
        }
    }

    private enum EventKind { case press, release }
    private struct MappingEvent {
        let kind: EventKind
        let mapping: HotkeyMapping
    }

    private func mappingEvents() -> [MappingEvent] {
        lock.lock()
        defer { lock.unlock() }

        var events: [MappingEvent] = []
        for mapping in mappings {
            let parts = keyParts(mapping.keys)
            let active = !parts.isEmpty && parts.allSatisfy { heldKeys.contains($0) }
            let wasActive = pressedMappings.contains(mapping.id)
            if active && !wasActive {
                pressedMappings.insert(mapping.id)
                events.append(MappingEvent(kind: .press, mapping: mapping))
            } else if !active && wasActive {
                pressedMappings.remove(mapping.id)
                events.append(MappingEvent(kind: .release, mapping: mapping))
            }
        }
        return events
    }

    private func updateHeldKeys(keycode: Int64, type: CGEventType, flags: UInt64) {
        let eventKey = keyName(keycode: keycode, type: type)

        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        for (key, modifier) in HotkeyTap.modifierKeys {
            if flags & modifier.flag != 0 {
                heldKeys.insert(key)
            } else {
                heldKeys.remove(key)
            }
        }

        if flags & HotkeyTap.flagSecondaryFn != 0 {
            heldKeys.insert("fn")
        } else {
            heldKeys.remove("fn")
        }

        if let eventKey, HotkeyTap.regularKeycodes[eventKey] != nil {
            if type == .keyDown {
                heldKeys.insert(eventKey)
            } else if type == .keyUp {
                heldKeys.remove(eventKey)
            }
        }
    }

    private func keyName(keycode: Int64, type: CGEventType) -> String? {
        if keycode == 63 {
            return "fn"
        }
        if let match = HotkeyTap.modifierKeys.first(where: { $0.value.keycode == keycode }) {
            return match.key
        }
        if let match = HotkeyTap.regularKeycodes.first(where: { $0.value == keycode }) {
            return match.key
        }
        return nil
    }

    private static func normalize(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    private func keyParts(_ value: String) -> [String] {
        value.split(separator: "+").map(String.init).filter { !$0.isEmpty }
    }
}
