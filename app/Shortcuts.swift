import AppKit
import Carbon
import Foundation

// MARK: - Model

struct Shortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt32   // Carbon modifier mask
    let keyLabel: String

    var display: String {
        Shortcut.modifierSymbols(modifiers) + keyLabel
    }

    static func modifierSymbols(_ modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    static let functionKeys: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
    ]

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeys.contains(keyCode)
    }

    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 76: "⌤",
        115: "↖", 116: "⇞", 117: "⌦", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static func keyLabel(for event: NSEvent) -> String {
        if let special = specialKeys[event.keyCode] { return special }
        if let characters = event.charactersIgnoringModifiers {
            let label = characters.uppercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { return label }
        }
        return "Key \(event.keyCode)"
    }
}

enum ShortcutAction: String, CaseIterable {
    case volumeUp
    case volumeDown
    case mute

    var defaultsKey: String { "shortcut.\(rawValue)" }

    var carbonID: UInt32 {
        UInt32((ShortcutAction.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    var title: String {
        switch self {
        case .volumeUp: return L("音量 +", "Volume Up")
        case .volumeDown: return L("音量 −", "Volume Down")
        case .mute: return L("静音", "Mute")
        }
    }

    var detail: String {
        switch self {
        case .volumeUp: return L("每次 +6.25%", "+6.25% per press")
        case .volumeDown: return L("每次 −6.25%", "−6.25% per press")
        case .mute: return L("切换静音", "Toggle mute")
        }
    }
}

// MARK: - Carbon registration

final class HotKeyManager {
    private static let signature: OSType = 0x53425247 // 'SBRG'

    private var handlerRef: EventHandlerRef?
    private var registrations: [ShortcutAction: EventHotKeyRef] = [:]
    private var shortcuts: [ShortcutAction: Shortcut] = [:]
    private(set) var failed: Set<ShortcutAction> = []

    var onAction: ((ShortcutAction) -> Void)?

    init() {
        installHandler()
        loadShortcuts()
    }

    deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    func shortcut(for action: ShortcutAction) -> Shortcut? {
        shortcuts[action]
    }

    /// Registers the new shortcut first; on failure the previous one is kept.
    @discardableResult
    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) -> Bool {
        let previous = shortcuts[action]
        unregister(action)

        guard let shortcut else {
            shortcuts.removeValue(forKey: action)
            failed.remove(action)
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
            return true
        }

        if register(shortcut, for: action) {
            shortcuts[action] = shortcut
            failed.remove(action)
            persist(shortcut, for: action)
            return true
        }

        // Registration failed (usually a conflict); restore what worked before.
        if let previous, register(previous, for: action) {
            shortcuts[action] = previous
        } else {
            shortcuts.removeValue(forKey: action)
        }
        failed.insert(action)
        return false
    }

    private func loadShortcuts() {
        for action in ShortcutAction.allCases {
            guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
                  let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else {
                continue
            }
            shortcuts[action] = shortcut
            if !register(shortcut, for: action) {
                failed.insert(action)
            }
        }
    }

    private func persist(_ shortcut: Shortcut, for action: ShortcutAction) {
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        }
    }

    private func register(_ shortcut: Shortcut, for action: ShortcutAction) -> Bool {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.carbonID)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref)
        guard status == noErr, let ref else { return false }
        registrations[action] = ref
        return true
    }

    private func unregister(_ action: ShortcutAction) {
        if let ref = registrations.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }

    private func unregisterAll() {
        for (_, ref) in registrations {
            UnregisterEventHotKey(ref)
        }
        registrations.removeAll()
    }

    private func installHandler() {
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = UInt32(kEventHotKeyPressed)
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            userData,
            &handlerRef)
    }

    fileprivate func handleHotKey(id: UInt32) {
        guard let action = ShortcutAction.allCases.first(where: { $0.carbonID == id }) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onAction?(action)
        }
    }
}

private let hotKeyEventHandler: EventHandlerUPP = { _, eventRef, userData in
    guard let eventRef, let userData else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID)
    if status == noErr {
        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        manager.handleHotKey(id: hotKeyID.id)
    }
    return noErr
}

// MARK: - Recorder button

final class ShortcutRecorderButton: NSButton {
    var onCapture: ((Shortcut?) -> Void)?

    var shortcut: Shortcut? {
        didSet { updateTitle() }
    }

    private var monitor: Any?
    private var recording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        if recording {
            finish(shortcut: nil, notify: false)
        }
        return super.resignFirstResponder()
    }

    @objc private func beginRecording() {
        guard !recording else { return }
        recording = true
        title = L("按下组合键…", "Press keys…")
        bezelColor = .controlAccentColor
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.recording else { return event }
            self.handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { // Esc cancels without changing anything
            finish(shortcut: nil, notify: false)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete clears
            finish(shortcut: nil, notify: true)
            return
        }

        let modifiers = Shortcut.carbonModifiers(from: event.modifierFlags)
        let hasCommandish = !event.modifierFlags
            .intersection([.command, .control, .option])
            .isEmpty
        guard hasCommandish || Shortcut.isFunctionKey(event.keyCode) else {
            NSSound.beep()
            return
        }

        let shortcut = Shortcut(
            keyCode: event.keyCode,
            modifiers: modifiers,
            keyLabel: Shortcut.keyLabel(for: event))
        finish(shortcut: shortcut, notify: true)
    }

    private func finish(shortcut: Shortcut?, notify: Bool) {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        bezelColor = nil
        if notify {
            self.shortcut = shortcut
            onCapture?(shortcut)
        } else {
            updateTitle()
        }
    }

    private func updateTitle() {
        title = shortcut?.display ?? L("点击录制", "Click to record")
    }
}
