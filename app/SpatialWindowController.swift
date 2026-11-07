import AppKit
import Foundation

final class SpatialWindowController: NSWindowController {
    private let dsp: SpatialDSP
    private let defaults = UserDefaults.standard

    private var presetPopup: NSPopUpButton!
    private var widthSlider: NSSlider!
    private var depthSlider: NSSlider!
    private var reverbSlider: NSSlider!
    private var gainSlider: NSSlider!
    private var widthValueLabel: NSTextField!
    private var depthValueLabel: NSTextField!
    private var reverbValueLabel: NSTextField!
    private var gainValueLabel: NSTextField!
    private var bypassCheckbox: NSButton!
    private var limiterCheckbox: NSButton!
    private var thresholdSlider: NSSlider!
    private var thresholdValueLabel: NSTextField!
    private var engineLabel: NSTextField!

    private struct Preset {
        let name: String
        let width: Double
        let depth: Double
        let reverb: Double
        let mode: Int // 0 = Schroeder, 1 = AU Medium Hall, 2 = AU Large Hall
        let bypass: Bool
    }

    private let presets: [Preset] = [
        Preset(name: "Off", width: 0, depth: 0, reverb: 0, mode: 0, bypass: true),
        Preset(name: "Standard", width: 30, depth: 20, reverb: 15, mode: 0, bypass: false),
        Preset(name: "Hall", width: 0, depth: 0, reverb: 50, mode: 2, bypass: false),
        Preset(name: "Hall (Schroeder)", width: 27, depth: 40, reverb: 20, mode: 0, bypass: false),
        Preset(name: "SpeakerAmp (Medium Hall)", width: 0, depth: 0, reverb: 50, mode: 1, bypass: false),
        Preset(name: "Movie", width: 50, depth: 40, reverb: 30, mode: 0, bypass: false),
        Preset(name: "Music", width: 40, depth: 30, reverb: 25, mode: 0, bypass: false),
        Preset(name: "Night", width: 20, depth: 10, reverb: 10, mode: 0, bypass: false),
    ]

    init(dsp: SpatialDSP) {
        self.dsp = dsp

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 410),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("SoundBridge 空间感", "SoundBridge Spatial")
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SoundBridgeSpatialWindow")

        super.init(window: window)

        buildUI()
        reloadFromDSP()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let title = NSTextField(labelWithString: L("空间感", "Spatial"))
        title.frame = NSRect(x: 24, y: 368, width: 200, height: 24)
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        content.addSubview(title)

        let presetLabel = NSTextField(labelWithString: L("预设：", "Preset:"))
        presetLabel.frame = NSRect(x: 24, y: 332, width: 60, height: 20)
        content.addSubview(presetLabel)

        presetPopup = NSPopUpButton(frame: NSRect(x: 90, y: 328, width: 240, height: 26), pullsDown: false)
        presetPopup.addItems(withTitles: presets.map { $0.name } + ["Custom"])
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))
        content.addSubview(presetPopup)

        engineLabel = NSTextField(labelWithString: "")
        engineLabel.frame = NSRect(x: 90, y: 308, width: 406, height: 16)
        engineLabel.font = NSFont.systemFont(ofSize: 10)
        engineLabel.textColor = .secondaryLabelColor
        content.addSubview(engineLabel)

        widthValueLabel = NSTextField(labelWithString: "0")
        widthValueLabel.frame = NSRect(x: 456, y: 286, width: 44, height: 20)
        widthValueLabel.alignment = .right
        widthValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        content.addSubview(widthValueLabel)

        let widthLabel = NSTextField(labelWithString: L("宽度", "Width"))
        widthLabel.frame = NSRect(x: 24, y: 286, width: 80, height: 20)
        content.addSubview(widthLabel)

        widthSlider = NSSlider(value: 0, minValue: 0, maxValue: 100,
                               target: self, action: #selector(widthChanged(_:)))
        widthSlider.frame = NSRect(x: 110, y: 282, width: 336, height: 24)
        widthSlider.isContinuous = true
        content.addSubview(widthSlider)

        depthValueLabel = NSTextField(labelWithString: "0")
        depthValueLabel.frame = NSRect(x: 456, y: 246, width: 44, height: 20)
        depthValueLabel.alignment = .right
        depthValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        content.addSubview(depthValueLabel)

        let depthLabel = NSTextField(labelWithString: L("深度", "Depth"))
        depthLabel.frame = NSRect(x: 24, y: 246, width: 80, height: 20)
        content.addSubview(depthLabel)

        depthSlider = NSSlider(value: 0, minValue: 0, maxValue: 100,
                               target: self, action: #selector(depthChanged(_:)))
        depthSlider.frame = NSRect(x: 110, y: 242, width: 336, height: 24)
        depthSlider.isContinuous = true
        content.addSubview(depthSlider)

        reverbValueLabel = NSTextField(labelWithString: "0")
        reverbValueLabel.frame = NSRect(x: 456, y: 206, width: 44, height: 20)
        reverbValueLabel.alignment = .right
        reverbValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        content.addSubview(reverbValueLabel)

        let reverbLabel = NSTextField(labelWithString: L("混响", "Reverb"))
        reverbLabel.frame = NSRect(x: 24, y: 206, width: 80, height: 20)
        content.addSubview(reverbLabel)

        reverbSlider = NSSlider(value: 0, minValue: 0, maxValue: 100,
                                target: self, action: #selector(reverbChanged(_:)))
        reverbSlider.frame = NSRect(x: 110, y: 202, width: 336, height: 24)
        reverbSlider.isContinuous = true
        content.addSubview(reverbSlider)

        gainValueLabel = NSTextField(labelWithString: "+0 dB")
        gainValueLabel.frame = NSRect(x: 448, y: 168, width: 52, height: 20)
        gainValueLabel.alignment = .right
        gainValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        content.addSubview(gainValueLabel)

        let gainLabel = NSTextField(labelWithString: L("增益", "Gain"))
        gainLabel.frame = NSRect(x: 24, y: 168, width: 80, height: 20)
        content.addSubview(gainLabel)

        gainSlider = NSSlider(value: 0, minValue: -15, maxValue: 15,
                              target: self, action: #selector(gainChanged(_:)))
        gainSlider.frame = NSRect(x: 110, y: 164, width: 330, height: 24)
        gainSlider.isContinuous = true
        content.addSubview(gainSlider)

        bypassCheckbox = NSButton(checkboxWithTitle: L("旁路 (A/B)", "Bypass (A/B)"),
                                  target: self, action: #selector(bypassChanged(_:)))
        bypassCheckbox.frame = NSRect(x: 24, y: 132, width: 180, height: 22)
        content.addSubview(bypassCheckbox)

        let separator = NSBox(frame: NSRect(x: 24, y: 116, width: 472, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)

        limiterCheckbox = NSButton(checkboxWithTitle: L("限幅器", "Limiter"),
                                   target: self, action: #selector(limiterChanged(_:)))
        limiterCheckbox.frame = NSRect(x: 24, y: 92, width: 120, height: 22)
        content.addSubview(limiterCheckbox)

        let thresholdLabel = NSTextField(labelWithString: L("阈值", "Threshold"))
        thresholdLabel.frame = NSRect(x: 140, y: 92, width: 80, height: 20)
        content.addSubview(thresholdLabel)

        thresholdSlider = NSSlider(value: -1, minValue: -6, maxValue: 0,
                                   target: self, action: #selector(thresholdChanged(_:)))
        thresholdSlider.frame = NSRect(x: 220, y: 88, width: 210, height: 24)
        thresholdSlider.isContinuous = true
        content.addSubview(thresholdSlider)

        thresholdValueLabel = NSTextField(labelWithString: "-1.0 dB")
        thresholdValueLabel.frame = NSRect(x: 438, y: 92, width: 62, height: 20)
        thresholdValueLabel.alignment = .right
        thresholdValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        content.addSubview(thresholdValueLabel)

        let note = NSTextField(wrappingLabelWithString: L(
            "Hall = AUMatrixReverb — Large Hall，Reverb 50（已按 SpeakerAmp ×0.5 校准）。\n" +
            "Width = M/S 展宽；Depth = crossfeed + 早期反射；Bypass 做 A/B。\n" +
            "Gain 在 EQ 前应用（±15 dB），正增益由限幅器保护。\n" +
            "Hall (Schroeder) 是原来的近似版本，可随时切回。",
            "Hall = AUMatrixReverb — Large Hall, Reverb 50 (calibrated to SpeakerAmp ×0.5).\n" +
            "Width = M/S widening; Depth = crossfeed + early reflections; Bypass for A/B.\n" +
            "Gain is applied before the EQ (±15 dB); positive gain is protected by the limiter.\n" +
            "Hall (Schroeder) is the previous approximation."))
        note.frame = NSRect(x: 24, y: 8, width: 472, height: 70)
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        content.addSubview(note)
    }

    func reloadFromDSP() {
        let width = Double(dsp.width.value) * 100.0
        let depth = Double(dsp.depth.value) * 100.0
        let reverb = Double(dsp.reverb.value) * 100.0
        widthSlider.doubleValue = width
        depthSlider.doubleValue = depth
        reverbSlider.doubleValue = reverb
        gainSlider.doubleValue = Double(dsp.gainDB.value)
        widthValueLabel.stringValue = "\(Int(width.rounded()))"
        depthValueLabel.stringValue = "\(Int(depth.rounded()))"
        reverbValueLabel.stringValue = "\(Int(reverb.rounded()))"
        gainValueLabel.stringValue = String(format: "%+.0f dB", dsp.gainDB.value)
        bypassCheckbox.state = dsp.bypass.value ? .on : .off
        limiterCheckbox.state = dsp.limiterEnabled.value ? .on : .off
        thresholdSlider.doubleValue = Double(dsp.thresholdDB.value)
        thresholdValueLabel.stringValue = String(format: "%.1f dB", dsp.thresholdDB.value)

        switch Int(dsp.reverbMode.value.rounded()) {
        case 1:
            engineLabel.stringValue = L("混响引擎：AUMatrixReverb — Medium Hall",
                                        "Reverb engine: AUMatrixReverb — Medium Hall")
        case 2:
            engineLabel.stringValue = L("混响引擎：AUMatrixReverb — Large Hall",
                                        "Reverb engine: AUMatrixReverb — Large Hall")
        default:
            engineLabel.stringValue = L("混响引擎：Schroeder（内置）",
                                        "Reverb engine: Schroeder (internal)")
        }

        let savedPreset = defaults.string(forKey: "spatial.preset") ?? "Custom"
        if let index = presetPopup.itemTitles.firstIndex(of: savedPreset) {
            presetPopup.selectItem(at: index)
        } else {
            presetPopup.selectItem(withTitle: "Custom")
        }
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let name = sender.titleOfSelectedItem ?? "Custom"
        guard let preset = presets.first(where: { $0.name == name }) else {
            defaults.set("Custom", forKey: "spatial.preset")
            return
        }
        dsp.width.value = Float(preset.width / 100.0)
        dsp.depth.value = Float(preset.depth / 100.0)
        dsp.reverb.value = Float(preset.reverb / 100.0)
        dsp.reverbMode.value = Float(preset.mode)
        dsp.bypass.value = preset.bypass
        defaults.set(name, forKey: "spatial.preset")
        defaults.set(preset.width, forKey: "spatial.width")
        defaults.set(preset.depth, forKey: "spatial.depth")
        defaults.set(preset.reverb, forKey: "spatial.reverb")
        defaults.set(preset.mode, forKey: "spatial.reverbMode")
        defaults.set(preset.bypass, forKey: "spatial.bypass")
        reloadFromDSP()
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        dsp.width.value = Float(sender.doubleValue / 100.0)
        widthValueLabel.stringValue = "\(Int(sender.doubleValue.rounded()))"
        defaults.set(sender.doubleValue, forKey: "spatial.width")
        markCustom()
    }

    @objc private func depthChanged(_ sender: NSSlider) {
        dsp.depth.value = Float(sender.doubleValue / 100.0)
        depthValueLabel.stringValue = "\(Int(sender.doubleValue.rounded()))"
        defaults.set(sender.doubleValue, forKey: "spatial.depth")
        markCustom()
    }

    @objc private func reverbChanged(_ sender: NSSlider) {
        dsp.reverb.value = Float(sender.doubleValue / 100.0)
        reverbValueLabel.stringValue = "\(Int(sender.doubleValue.rounded()))"
        defaults.set(sender.doubleValue, forKey: "spatial.reverb")
        markCustom()
    }

    @objc private func gainChanged(_ sender: NSSlider) {
        let db = sender.doubleValue.rounded()
        sender.doubleValue = db
        dsp.gainDB.value = Float(db)
        gainValueLabel.stringValue = String(format: "%+.0f dB", db)
        defaults.set(db, forKey: "output.gainDB")
    }

    @objc private func bypassChanged(_ sender: NSButton) {
        dsp.bypass.value = sender.state == .on
        defaults.set(sender.state == .on, forKey: "spatial.bypass")
    }

    @objc private func limiterChanged(_ sender: NSButton) {
        dsp.limiterEnabled.value = sender.state == .on
        defaults.set(sender.state == .on, forKey: "limiter.enabled")
    }

    @objc private func thresholdChanged(_ sender: NSSlider) {
        dsp.thresholdDB.value = Float(sender.doubleValue)
        thresholdValueLabel.stringValue = String(format: "%.1f dB", sender.doubleValue)
        defaults.set(sender.doubleValue, forKey: "limiter.threshold")
    }

    private func markCustom() {
        presetPopup.selectItem(withTitle: "Custom")
        defaults.set("Custom", forKey: "spatial.preset")
    }

    func show() {
        reloadFromDSP()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
