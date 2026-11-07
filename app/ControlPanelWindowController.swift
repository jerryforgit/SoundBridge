import AppKit
import Foundation

final class ControlPanelWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    enum Tab {
        case spatial
        case equalizer
        case shortcuts
        case about
    }

    private let spatialController: SpatialWindowController
    private let eqController: EQWindowController
    private let shortcutsController: ShortcutsWindowController
    private let tabView: NSTabView
    private let spatialTab: NSTabViewItem
    private let eqTab: NSTabViewItem
    private let shortcutsTab: NSTabViewItem
    private let aboutTab: NSTabViewItem
    private let outputDescription: () -> String
    private var aboutTextView: NSTextView?

    init(dsp: SpatialDSP, outputDescription: @escaping () -> String, hotKeys: HotKeyManager) {
        self.outputDescription = outputDescription
        spatialController = SpatialWindowController(dsp: dsp)
        eqController = EQWindowController(eq: dsp.eq)
        shortcutsController = ShortcutsWindowController(hotKeys: hotKeys)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("SoundBridge 控制面板", "SoundBridge Control Panel")
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SoundBridgeControlPanel")

        tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 540, height: 450))
        spatialTab = NSTabViewItem(identifier: "spatial")
        eqTab = NSTabViewItem(identifier: "equalizer")
        shortcutsTab = NSTabViewItem(identifier: "shortcuts")
        aboutTab = NSTabViewItem(identifier: "about")

        super.init(window: window)

        window.delegate = self
        tabView.delegate = self
        buildTabs()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildTabs() {
        guard let content = window?.contentView else { return }
        tabView.frame = content.bounds
        tabView.autoresizingMask = [.width, .height]
        content.addSubview(tabView)

        spatialTab.label = L("空间感", "Spatial")
        if let view = spatialController.window?.contentView {
            view.autoresizingMask = [.width, .height]
            spatialTab.view = view
        }
        tabView.addTabViewItem(spatialTab)

        eqTab.label = L("均衡器", "Equalizer")
        if let view = eqController.window?.contentView {
            view.autoresizingMask = [.width, .height]
            eqTab.view = view
        }
        tabView.addTabViewItem(eqTab)

        shortcutsTab.label = L("快捷键", "Shortcuts")
        if let view = shortcutsController.window?.contentView {
            view.autoresizingMask = [.width, .height]
            shortcutsTab.view = view
        }
        tabView.addTabViewItem(shortcutsTab)

        aboutTab.label = L("关于", "About")
        aboutTab.view = makeAboutView()
        tabView.addTabViewItem(aboutTab)

        window?.setContentSize(size(for: .spatial))
    }

    private func makeAboutView() -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.string = aboutText()
        aboutTextView = textView
        scroll.documentView = textView
        return scroll
    }

    private func refreshAbout() {
        aboutTextView?.string = aboutText()
    }

    private func aboutText() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        let appPath = Bundle.main.bundlePath
        let output = outputDescription()

        return L(
            """
            SoundBridge \(version) (build \(build))

            一个 macOS 菜单栏音频工具，用来替代 SpeakerAmp。

            架构：
            • 虚拟输出设备 SoundBridge（AudioServerPlugin HAL 驱动）
            • 引擎按 UID 把音频转发到当前显示器
            • 原生音量键 / 系统 OSD / 静音键
            • 10 段 EQ + look-ahead 限幅器
            • AUMatrixReverb（Large Hall）空间感，已与 SpeakerAmp Hall 50% 校准
            • 唤醒时按 UID 重绑，处理设备重建两次的抖动

            当前输出：
            \(output)

            技术栈：
            AudioServerPlugIn (C++ / libASPL) + Swift + CoreAudio + AUMatrixReverb

            项目主页：
            https://github.com/jerryforgit/SoundBridge

            App 位置：
            \(appPath)

            日志：
            ~/Library/Logs/SoundBridge/engine.log

            安装 / 卸载：
            SoundBridge.pkg             安装 App + HAL 插件
            Uninstall SoundBridge.pkg   彻底卸载

            SpeakerAmp 仍然保留，可随时切回作为回退。
            """,
            """
            SoundBridge \(version) (build \(build))

            A macOS menu bar audio tool built to replace SpeakerAmp.

            Architecture:
            • Virtual output device SoundBridge (AudioServerPlugin HAL driver)
            • Engine forwards audio to the current display by UID
            • Native volume keys / system OSD / mute
            • 10-band EQ + look-ahead limiter
            • AUMatrixReverb (Large Hall), calibrated against SpeakerAmp Hall 50%
            • UID-based rebinding on wake, including double device rebuilds

            Current output:
            \(output)

            Stack:
            AudioServerPlugIn (C++ / libASPL) + Swift + CoreAudio + AUMatrixReverb

            Project:
            https://github.com/jerryforgit/SoundBridge

            App location:
            \(appPath)

            Log:
            ~/Library/Logs/SoundBridge/engine.log

            Install / uninstall:
            SoundBridge.pkg             install app + HAL plugin
            Uninstall SoundBridge.pkg   clean uninstall

            SpeakerAmp remains installed as a fallback.
            """
        )
    }

    private func size(for tab: Tab) -> NSSize {
        switch tab {
        case .spatial:
            return NSSize(width: 540, height: 450)
        case .equalizer:
            return NSSize(width: 780, height: 480)
        case .shortcuts:
            return NSSize(width: 540, height: 430)
        case .about:
            return NSSize(width: 580, height: 470)
        }
    }

    private func tab(for item: NSTabViewItem) -> Tab {
        if item == eqTab { return .equalizer }
        if item == shortcutsTab { return .shortcuts }
        if item == aboutTab { return .about }
        return .spatial
    }

    func show(tab: Tab) {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let item: NSTabViewItem
        switch tab {
        case .spatial: item = spatialTab
        case .equalizer: item = eqTab
        case .shortcuts: item = shortcutsTab
        case .about: item = aboutTab
        }
        tabView.selectTabViewItem(item)
        window?.setContentSize(size(for: tab))
        if tab == .about { refreshAbout() }
    }

    func reloadSpatial() {
        spatialController.reloadFromDSP()
    }

    func reloadEQ() {
        eqController.reloadFromDSP()
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let tabViewItem else { return }
        let tab = tab(for: tabViewItem)
        window?.setContentSize(size(for: tab))
        if tab == .about { refreshAbout() }
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
