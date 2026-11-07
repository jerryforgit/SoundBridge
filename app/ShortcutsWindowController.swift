import AppKit
import Foundation

final class ShortcutsWindowController: NSWindowController {
    private let hotKeys: HotKeyManager
    private var recorders: [ShortcutAction: ShortcutRecorderButton] = [:]
    private var clearButtons: [ShortcutAction: NSButton] = [:]
    private var statusLabel: NSTextField!

    init(hotKeys: HotKeyManager) {
        self.hotKeys = hotKeys

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("SoundBridge 快捷键", "SoundBridge Shortcuts")
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SoundBridgeShortcutsWindow")

        super.init(window: window)
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: L("全局快捷键", "Global Shortcuts"))
        title.frame = NSRect(x: 24, y: 338, width: 300, height: 24)
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        content.addSubview(title)

        let note = NSTextField(wrappingLabelWithString: L(
            "点击右侧按钮后按下组合键。Delete 清除，Esc 取消。\n" +
            "快捷键由 Carbon 注册，不需要辅助功能权限。",
            "Click a button, then press a key combination. Delete clears, Esc cancels.\n" +
            "Shortcuts are registered with Carbon and need no Accessibility permission."))
        note.frame = NSRect(x: 24, y: 292, width: 472, height: 38)
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        content.addSubview(note)

        let rows: [CGFloat] = [244, 198, 152]
        for (index, action) in ShortcutAction.allCases.enumerated() {
            let y = rows[index]

            let label = NSTextField(labelWithString: action.title)
            label.frame = NSRect(x: 24, y: y + 4, width: 170, height: 20)
            content.addSubview(label)

            let detail = NSTextField(labelWithString: action.detail)
            detail.frame = NSRect(x: 24, y: y - 14, width: 180, height: 16)
            detail.font = NSFont.systemFont(ofSize: 10)
            detail.textColor = .secondaryLabelColor
            content.addSubview(detail)

            let recorder = ShortcutRecorderButton()
            recorder.frame = NSRect(x: 214, y: y, width: 230, height: 28)
            recorder.onCapture = { [weak self] shortcut in
                self?.apply(shortcut, for: action)
            }
            recorders[action] = recorder
            content.addSubview(recorder)

            let clear = NSButton(title: "×", target: self, action: #selector(clearOne(_:)))
            clear.frame = NSRect(x: 452, y: y, width: 32, height: 28)
            clear.bezelStyle = .rounded
            clear.tag = index
            clearButtons[action] = clear
            content.addSubview(clear)
        }

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 24, y: 112, width: 472, height: 18)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        content.addSubview(statusLabel)

        let clearAll = NSButton(title: L("清除全部", "Clear All"),
                                target: self, action: #selector(clearAll(_:)))
        clearAll.frame = NSRect(x: 24, y: 70, width: 110, height: 28)
        clearAll.bezelStyle = .rounded
        content.addSubview(clearAll)

        let footer = NSTextField(labelWithString: L(
            "系统音量键、OSD 和静音键仍然照常工作。",
            "The native volume keys, OSD and mute key still work as before."))
        footer.frame = NSRect(x: 24, y: 28, width: 472, height: 18)
        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        content.addSubview(footer)
    }

    func reload() {
        for action in ShortcutAction.allCases {
            recorders[action]?.shortcut = hotKeys.shortcut(for: action)
        }
        updateClearButtons()
        if !hotKeys.failed.isEmpty {
            statusLabel.stringValue = L("部分快捷键被占用，请重新设置。",
                                        "Some shortcuts are in use; please set them again.")
            statusLabel.textColor = .systemRed
        } else {
            statusLabel.stringValue = ""
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private func apply(_ shortcut: Shortcut?, for action: ShortcutAction) {
        let previous = hotKeys.shortcut(for: action)
        if hotKeys.setShortcut(shortcut, for: action) {
            recorders[action]?.shortcut = shortcut
            statusLabel.stringValue = shortcut == nil
                ? L("已清除", "Cleared")
                : L("已保存", "Saved")
            statusLabel.textColor = .secondaryLabelColor
        } else {
            recorders[action]?.shortcut = previous
            statusLabel.stringValue = L("快捷键被占用，请换一个。",
                                        "Shortcut is in use; choose another.")
            statusLabel.textColor = .systemRed
        }
        updateClearButtons()
    }

    private func updateClearButtons() {
        for action in ShortcutAction.allCases {
            clearButtons[action]?.isEnabled = hotKeys.shortcut(for: action) != nil
        }
    }

    @objc private func clearOne(_ sender: NSButton) {
        let actions = ShortcutAction.allCases
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        apply(nil, for: actions[sender.tag])
    }

    @objc private func clearAll(_ sender: NSButton) {
        for action in ShortcutAction.allCases {
            _ = hotKeys.setShortcut(nil, for: action)
            recorders[action]?.shortcut = nil
        }
        updateClearButtons()
        statusLabel.stringValue = L("已清除全部快捷键", "All shortcuts cleared")
        statusLabel.textColor = .secondaryLabelColor
    }

    func show() {
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
