import AppKit
import Foundation
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var engine: Engine!
    private var logger: Logger!
    private var updateTimer: Timer?
    private var refreshTimer: Timer?
    private var volumeValueLabel: NSTextField?
    private var previousDefaultUID: String?
    private var cachedSoundBridgeID: AudioDeviceID?
    private var controlPanel: ControlPanelWindowController?
    private var lastStatusSymbol = ""

    private let defaults = UserDefaults.standard
    private let outputUIDKey = "outputUID"
    private let autoDefaultKey = "autoDefault"
    private let launchAtLoginKey = "launchAtLogin"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let isDefaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) ?? true
        let backgroundLaunch = CommandLine.arguments.contains("--background")

        logger = Logger(path: "~/Library/Logs/SoundBridge/engine.log")
        logger.log("==== SoundBridge.app launched ====")

        if defaults.object(forKey: autoDefaultKey) == nil {
            defaults.set(true, forKey: autoDefaultKey)
        }

        let selectedUID = resolveOutputUID()
        defaults.set(selectedUID, forKey: outputUIDKey)

        engine = Engine(inputUID: kSoundBridgeDeviceUID, outputUID: selectedUID, log: logger)
        loadSpatialSettings(into: engine.dsp)
        loadEQSettings(into: engine.dsp.eq)
        engine.start()

        // 安装/更新会先注销旧 build 的登录项；这里按偏好重新注册当前 build。
        // 同时清理早期 LaunchAgent 版本留下的文件。
        LoginItem.reconcile(prefEnabled: defaults.bool(forKey: launchAtLoginKey))

        cachedSoundBridgeID = soundBridgeDeviceID()
        createStatusItem()
        updateStatusTitle()

        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer

        let refresh = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                let id = soundBridgeDeviceID()
                DispatchQueue.main.async { self?.cachedSoundBridgeID = id }
            }
        }
        RunLoop.main.add(refresh, forMode: .common)
        refreshTimer = refresh

        if defaults.bool(forKey: autoDefaultKey) {
            // 等引擎先完成 input/output 绑定，再切默认输出，避免 CoreAudio
            // 在设备重配置时把引擎的首次 reconcile 卡住十几秒。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.enableDefaultOutput()
            }
        }

        // 用户从 Launchpad/Dock/open 启动时打开控制面板；
        // 登录项启动（非 default launch）只驻留菜单栏。
        if isDefaultLaunch && !backgroundLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showControlPanel(tab: .spatial)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        updateTimer = nil
        refreshTimer?.invalidate()
        refreshTimer = nil

        engine?.stop(reason: "app quit")

        if defaults.bool(forKey: autoDefaultKey) {
            restoreDefaultOutput()
        }

        logger?.log("==== SoundBridge.app terminated ====")
        logger?.flush()
    }

    // MARK: - setup

    private func resolveOutputUID() -> String {
        if let saved = defaults.string(forKey: outputUIDKey),
           findDevice(uid: saved) != nil {
            return saved
        }
        if let detected = physicalDisplayOutputs().first,
           let uid = deviceUID(detected) {
            return uid
        }
        return kDefaultOutputUID
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "speaker.wave.2.fill",
                                accessibilityDescription: "SoundBridge")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.title = " --%"
        }

        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        guard let id = cachedSoundBridgeID else {
            setStatusSymbol("speaker.slash.fill")
            button.title = " !"
            return
        }
        let muted = getMute(for: id)
        let volume = getVolume(for: id) ?? 0

        let symbol: String
        if muted || volume <= 0.001 {
            symbol = "speaker.slash.fill"
        } else if volume < 0.34 {
            symbol = "speaker.wave.1.fill"
        } else if volume < 0.67 {
            symbol = "speaker.wave.2.fill"
        } else {
            symbol = "speaker.wave.3.fill"
        }
        setStatusSymbol(symbol)

        button.title = muted ? L(" 静音", " Muted") : " \(Int((volume * 100).rounded()))%"
    }

    private func setStatusSymbol(_ symbol: String) {
        guard symbol != lastStatusSymbol, let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SoundBridge")
        image?.isTemplate = true
        button.image = image
        lastStatusSymbol = symbol
    }

    // MARK: - menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // SpeakerAmp 行为：点状态栏图标时把系统默认输出切到 SoundBridge
        if defaults.bool(forKey: autoDefaultKey) {
            enableDefaultOutput()
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let volume = getSoundBridgeVolume() ?? 1.0
        let muted = getSoundBridgeMute()

        // Volume slider row
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 66))
        let titleLabel = NSTextField(labelWithString: L("音量", "Volume"))
        titleLabel.frame = NSRect(x: 16, y: 44, width: 80, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        let valueLabel = NSTextField(labelWithString: muted ? L("静音", "Muted") : "\(Int((volume * 100).rounded()))%")
        valueLabel.frame = NSRect(x: 140, y: 44, width: 64, height: 18)
        valueLabel.alignment = .right
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        volumeValueLabel = valueLabel

        let slider = NSSlider(value: muted ? 0 : Double(volume),
                             minValue: 0,
                             maxValue: 1,
                             target: self,
                             action: #selector(volumeChanged(_:)))
        slider.frame = NSRect(x: 16, y: 14, width: 188, height: 22)
        slider.isContinuous = true
        slider.isEnabled = soundBridgeDeviceID() != nil

        container.addSubview(titleLabel)
        container.addSubview(valueLabel)
        container.addSubview(slider)

        let volumeItem = NSMenuItem()
        volumeItem.view = container
        menu.addItem(volumeItem)

        let muteItem = NSMenuItem(title: L("静音", "Mute"), action: #selector(toggleMute(_:)), keyEquivalent: "")
        muteItem.target = self
        muteItem.state = muted ? .on : .off
        menu.addItem(muteItem)

        menu.addItem(.separator())

        let panelItem = NSMenuItem(title: L("控制面板…", "Control Panel…"),
                                   action: #selector(openControlPanel(_:)),
                                   keyEquivalent: "")
        panelItem.target = self
        menu.addItem(panelItem)

        let bypassItem = NSMenuItem(title: L("空间感旁路", "Spatial Bypass"),
                                    action: #selector(toggleSpatialBypass(_:)),
                                    keyEquivalent: "")
        bypassItem.target = self
        bypassItem.state = (engine?.dsp.bypass.value == true) ? .on : .off
        menu.addItem(bypassItem)

        let eqBypassItem = NSMenuItem(title: L("EQ 旁路", "EQ Bypass"),
                                      action: #selector(toggleEQBypass(_:)),
                                      keyEquivalent: "")
        eqBypassItem.target = self
        eqBypassItem.state = (engine?.dsp.eq.bypass.value == true) ? .on : .off
        menu.addItem(eqBypassItem)

        menu.addItem(.separator())

        // Output device submenu
        let outputItem = NSMenuItem(title: L("输出设备", "Output Device"), action: nil, keyEquivalent: "")
        let outputMenu = NSMenu()
        let currentUID = engine?.selectedOutputUID ?? ""
        for choice in outputDeviceChoices() {
            let item = NSMenuItem(title: choice.name, action: #selector(selectOutput(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.uid
            item.state = choice.uid == currentUID ? .on : .off
            outputMenu.addItem(item)
        }
        if outputMenu.items.isEmpty {
            let empty = NSMenuItem(title: L("未找到物理输出", "No physical output found"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            outputMenu.addItem(empty)
        }
        outputItem.submenu = outputMenu
        menu.addItem(outputItem)

        let defaultItem = NSMenuItem(title: L("默认输出：SoundBridge", "Default Output: SoundBridge"),
                                     action: #selector(toggleDefaultOutput(_:)),
                                     keyEquivalent: "")
        defaultItem.target = self
        defaultItem.state = defaults.bool(forKey: autoDefaultKey) ? .on : .off
        menu.addItem(defaultItem)

        let loginItem = NSMenuItem(title: L("登录时启动", "Launch at Login"),
                                   action: #selector(toggleLaunchAtLogin(_:)),
                                   keyEquivalent: "")
        loginItem.target = self
        loginItem.state = launchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        let languageItem = NSMenuItem(title: L("语言", "Language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let languageChoices: [(String, String)] = [
            ("system", L("跟随系统", "System")),
            ("zh", "中文"),
            ("en", "English"),
        ]
        let currentLanguage = defaults.string(forKey: appLanguageKey) ?? "system"
        for (value, title) in languageChoices {
            let item = NSMenuItem(title: title, action: #selector(changeLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = currentLanguage == value ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(.separator())

        let statusText = (engine?.isRunningBoth == true)
            ? L("引擎：运行中", "Engine: running")
            : L("引擎：等待设备", "Engine: waiting")
        let statusItemMenu = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItemMenu.isEnabled = false
        menu.addItem(statusItemMenu)

        let logItem = NSMenuItem(title: L("打开引擎日志", "Open Engine Log"), action: #selector(openLog(_:)), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("退出 SoundBridge", "Quit SoundBridge"), action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - actions

    @objc private func volumeChanged(_ sender: NSSlider) {
        let value = Float32(sender.doubleValue)
        if getSoundBridgeMute() {
            _ = setSoundBridgeMute(false)
        }
        _ = setSoundBridgeVolume(value)
        volumeValueLabel?.stringValue = "\(Int((value * 100).rounded()))%"
        updateStatusTitle()
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        let muted = getSoundBridgeMute()
        _ = setSoundBridgeMute(!muted)
        updateStatusTitle()
    }

    @objc private func openControlPanel(_ sender: NSMenuItem) {
        showControlPanel(tab: .spatial)
    }

    @objc private func openSpatial(_ sender: NSMenuItem) {
        showControlPanel(tab: .spatial)
    }

    @objc private func openEQ(_ sender: NSMenuItem) {
        showControlPanel(tab: .equalizer)
    }

    private func showControlPanel(tab: ControlPanelWindowController.Tab) {
        if defaults.bool(forKey: autoDefaultKey) {
            enableDefaultOutput()
        }
        if controlPanel == nil {
            controlPanel = ControlPanelWindowController(dsp: engine.dsp) { [weak self] in
                self?.currentOutputDescription() ?? L("未连接", "Not connected")
            }
        }
        controlPanel?.show(tab: tab)
    }

    @objc private func toggleEQBypass(_ sender: NSMenuItem) {
        let newValue = !(engine?.dsp.eq.bypass.value ?? false)
        engine?.dsp.eq.bypass.value = newValue
        defaults.set(newValue, forKey: "eq.bypass")
        controlPanel?.reloadEQ()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControlPanel(tab: .spatial)
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let spatial = NSMenuItem(title: L("打开空间感", "Open Spatial"),
                                 action: #selector(openSpatial(_:)), keyEquivalent: "")
        spatial.target = self
        menu.addItem(spatial)
        let eq = NSMenuItem(title: L("打开均衡器", "Open Equalizer"),
                            action: #selector(openEQ(_:)), keyEquivalent: "")
        eq.target = self
        menu.addItem(eq)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("退出 SoundBridge", "Quit SoundBridge"),
                              action: #selector(quitApp(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleSpatialBypass(_ sender: NSMenuItem) {
        let newValue = !(engine?.dsp.bypass.value ?? true)
        engine?.dsp.bypass.value = newValue
        defaults.set(newValue, forKey: "spatial.bypass")
        controlPanel?.reloadSpatial()
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        defaults.set(uid, forKey: outputUIDKey)
        engine?.setOutputUID(uid)
        logger?.log("selected output UID=\(uid)")
    }

    @objc private func toggleDefaultOutput(_ sender: NSMenuItem) {
        let enabled = !defaults.bool(forKey: autoDefaultKey)
        defaults.set(enabled, forKey: autoDefaultKey)
        if enabled {
            enableDefaultOutput()
        } else {
            restoreDefaultOutput()
        }
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        defaults.set(value, forKey: appLanguageKey)
        if controlPanel?.window?.isVisible == true {
            controlPanel?.close()
            controlPanel = nil
        }
        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if LoginItem.isEnabled {
                try LoginItem.disable()
                defaults.set(false, forKey: launchAtLoginKey)
                logger?.log("launch at login disabled")
            } else {
                try LoginItem.enable()
                defaults.set(true, forKey: launchAtLoginKey)
                logger?.log("launch at login enabled")
            }
        } catch {
            logger?.log("launch at login failed: \(error)")
            let alert = NSAlert()
            alert.messageText = L("无法更新登录项", "Could not update Login Item")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func openLog(_ sender: NSMenuItem) {
        let path = ("~/Library/Logs/SoundBridge/engine.log" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: ("~/Library/Logs/SoundBridge" as NSString).expandingTildeInPath))
        }
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: - default output

    private func enableDefaultOutput() {
        guard let soundBridge = soundBridgeDeviceID() else { return }
        let current = currentDefaultOutputID()
        if current == soundBridge { return }
        if let current, let uid = deviceUID(current) {
            previousDefaultUID = uid
        }
        setDefaultOutput(soundBridge)
        logger?.log("set SoundBridge as default output (previous=\(previousDefaultUID ?? "nil"))")
    }

    private func restoreDefaultOutput() {
        guard let soundBridge = soundBridgeDeviceID(),
              currentDefaultOutputID() == soundBridge else { return }

        if let previous = previousDefaultUID, let id = findDevice(uid: previous) {
            setDefaultOutput(id)
            logger?.log("restored default output to \(previous)")
            return
        }
        if let selected = engine?.selectedOutputUID, let id = findDevice(uid: selected) {
            setDefaultOutput(id)
            logger?.log("restored default output to engine output \(selected)")
            return
        }
        if let builtIn = findDevice(uid: "BuiltInSpeakerDevice") {
            setDefaultOutput(builtIn)
            logger?.log("restored default output to built-in speakers")
        }
    }

    private func launchAtLoginEnabled() -> Bool {
        LoginItem.isEnabled
    }

    private func currentOutputDescription() -> String {
        guard let engine else { return L("未连接", "Not connected") }
        let uid = engine.selectedOutputUID
        if let id = findDevice(uid: uid), let name = deviceName(id) {
            return name
        }
        return L("未连接", "Not connected")
    }

    private func loadSpatialSettings(into dsp: SpatialDSP) {
        let d = defaults
        dsp.width.value = Float((d.object(forKey: "spatial.width") as? Double ?? 0.0) / 100.0)
        dsp.depth.value = Float((d.object(forKey: "spatial.depth") as? Double ?? 0.0) / 100.0)
        dsp.gainDB.value = Float(d.double(forKey: "output.gainDB"))

        if d.object(forKey: "spatial.reverb") != nil {
            dsp.reverb.value = Float(d.double(forKey: "spatial.reverb") / 100.0)
        } else if d.string(forKey: "spatial.preset") == "Hall" {
            // 新 Hall = AUMatrixReverb Large Hall
            dsp.width.value = 0
            dsp.depth.value = 0
            dsp.reverb.value = 0.50
        } else {
            dsp.reverb.value = 0
        }

        if d.object(forKey: "spatial.reverbMode") != nil {
            dsp.reverbMode.value = Float(d.integer(forKey: "spatial.reverbMode"))
        } else if d.string(forKey: "spatial.preset") == "SpeakerAmp (Medium Hall)" {
            dsp.reverbMode.value = 1
        } else if d.string(forKey: "spatial.preset") == "SpeakerAmp (Large Hall)" {
            dsp.reverbMode.value = 2
        } else if d.string(forKey: "spatial.preset") == "Hall" {
            dsp.reverbMode.value = 2
        } else {
            dsp.reverbMode.value = 0
        }

        // AU 模式 wet 校准迁移：旧的自定义 25% 现在对应 UI 50%
        let mode = Int(dsp.reverbMode.value.rounded())
        let preset = d.string(forKey: "spatial.preset") ?? "Custom"
        if (mode == 1 || mode == 2), d.object(forKey: "spatial.wetCalibration") == nil {
            if preset == "Custom", dsp.reverb.value <= 0.40 {
                let doubled = min(1.0, dsp.reverb.value * 2.0)
                dsp.reverb.value = doubled
                d.set(Double(doubled) * 100.0, forKey: "spatial.reverb")
            }
            d.set(1, forKey: "spatial.wetCalibration")
        }

        dsp.bypass.value = d.object(forKey: "spatial.bypass") != nil
            ? d.bool(forKey: "spatial.bypass")
            : true
        dsp.limiterEnabled.value = d.object(forKey: "limiter.enabled") != nil
            ? d.bool(forKey: "limiter.enabled")
            : true
        dsp.thresholdDB.value = d.object(forKey: "limiter.threshold") != nil
            ? Float(d.double(forKey: "limiter.threshold"))
            : -1.0
    }

    private func loadEQSettings(into eq: EQDSP) {
        if let saved = defaults.array(forKey: "eq.gains") as? [Double], saved.count == 10 {
            for index in 0..<10 {
                eq.gains[index].value = Float(saved[index])
            }
        }
        eq.bypass.value = defaults.object(forKey: "eq.bypass") != nil
            ? defaults.bool(forKey: "eq.bypass")
            : false
    }
}
