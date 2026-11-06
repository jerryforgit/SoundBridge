import AppKit
import Foundation

final class EQWindowController: NSWindowController {
    private let eq: EQDSP
    private let defaults = UserDefaults.standard

    private var sliders: [NSSlider] = []
    private var valueLabels: [NSTextField] = []
    private var presetPopup: NSPopUpButton!
    private var bypassCheckbox: NSButton!

    private struct Preset {
        let name: String
        let gains: [Double]
    }

    private let presets: [Preset] = [
        Preset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Bass", gains: [4, 3, 1, 0, 0, -1, -1, -1, 0, 0]),
        Preset(name: "Vocal", gains: [-2, -1, 0, 2, 3, 2, 1, 0, -1, -1]),
        Preset(name: "Movie", gains: [3, 2, 1, 0, 0, 1, 2, 1, 0, 0]),
        Preset(name: "Music", gains: [2, 1, 0, 0, 1, 1, 1, 0, 0, 0]),
    ]

    private let frequencyLabels = ["50", "150", "300", "600", "1k", "3k", "6k", "9k", "12k", "15k"]

    init(eq: EQDSP) {
        self.eq = eq

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("SoundBridge 均衡器", "SoundBridge Equalizer")
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SoundBridgeEQWindow")

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

        let title = NSTextField(labelWithString: L("均衡器", "Equalizer"))
        title.frame = NSRect(x: 24, y: 398, width: 200, height: 24)
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        content.addSubview(title)

        let presetLabel = NSTextField(labelWithString: L("预设：", "Preset:"))
        presetLabel.frame = NSRect(x: 24, y: 364, width: 60, height: 20)
        content.addSubview(presetLabel)

        presetPopup = NSPopUpButton(frame: NSRect(x: 90, y: 360, width: 150, height: 26), pullsDown: false)
        presetPopup.addItems(withTitles: presets.map { $0.name } + ["Custom"])
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))
        content.addSubview(presetPopup)

        bypassCheckbox = NSButton(checkboxWithTitle: L("旁路", "Bypass"),
                                  target: self, action: #selector(bypassChanged(_:)))
        bypassCheckbox.frame = NSRect(x: 260, y: 362, width: 100, height: 22)
        content.addSubview(bypassCheckbox)

        let resetButton = NSButton(title: L("平直", "Flat"), target: self, action: #selector(resetToFlat(_:)))
        resetButton.frame = NSRect(x: 370, y: 356, width: 70, height: 28)
        resetButton.bezelStyle = .rounded
        content.addSubview(resetButton)

        let dbLabel = NSTextField(labelWithString: "dB")
        dbLabel.frame = NSRect(x: 20, y: 220, width: 30, height: 18)
        dbLabel.textColor = .secondaryLabelColor
        content.addSubview(dbLabel)

        let startX: CGFloat = 60
        let spacing: CGFloat = 66
        let sliderY: CGFloat = 120
        let sliderHeight: CGFloat = 220

        for index in 0..<10 {
            let x = startX + CGFloat(index) * spacing

            let valueLabel = NSTextField(labelWithString: "0")
            valueLabel.frame = NSRect(x: x - 8, y: 346, width: 42, height: 18)
            valueLabel.alignment = .center
            valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            content.addSubview(valueLabel)
            valueLabels.append(valueLabel)

            let slider = NSSlider(value: 0, minValue: -12, maxValue: 12,
                                  target: self, action: #selector(gainChanged(_:)))
            slider.frame = NSRect(x: x, y: sliderY, width: 26, height: sliderHeight)
            slider.isVertical = true
            slider.isContinuous = true
            slider.tag = index
            content.addSubview(slider)
            sliders.append(slider)

            let frequency = NSTextField(labelWithString: frequencyLabels[index])
            frequency.frame = NSRect(x: x - 12, y: 96, width: 50, height: 18)
            frequency.alignment = .center
            frequency.font = NSFont.systemFont(ofSize: 10)
            frequency.textColor = .secondaryLabelColor
            content.addSubview(frequency)

            let band = NSTextField(labelWithString: "\(index + 1)")
            band.frame = NSRect(x: x - 12, y: 78, width: 50, height: 16)
            band.alignment = .center
            band.font = NSFont.systemFont(ofSize: 9)
            band.textColor = .tertiaryLabelColor
            content.addSubview(band)
        }

        let note = NSTextField(wrappingLabelWithString: L(
            "10-band peaking EQ：50 / 150 / 300 / 600 / 1k / 3k / 6k / 9k / 12k / 15k Hz，±12 dB，Q 1.2。\n" +
            "EQ 在 Spatial 之前；Limiter 在链路最后。默认 Flat。",
            "10-band peaking EQ: 50 / 150 / 300 / 600 / 1k / 3k / 6k / 9k / 12k / 15k Hz, ±12 dB, Q 1.2.\n" +
            "EQ is before Spatial; Limiter is last. Default is Flat."))
        note.frame = NSRect(x: 24, y: 24, width: 712, height: 44)
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        content.addSubview(note)
    }

    func reloadFromDSP() {
        for index in 0..<10 {
            let gain = Double(eq.gains[index].value)
            sliders[index].doubleValue = gain
            updateValueLabel(index, gain)
        }
        bypassCheckbox.state = eq.bypass.value ? .on : .off

        let savedPreset = defaults.string(forKey: "eq.preset") ?? "Custom"
        if let item = presetPopup.itemTitles.firstIndex(of: savedPreset) {
            presetPopup.selectItem(at: item)
        } else {
            presetPopup.selectItem(withTitle: "Custom")
        }
    }

    @objc private func gainChanged(_ sender: NSSlider) {
        let index = sender.tag
        let value = sender.doubleValue
        eq.gains[index].value = Float(value)
        updateValueLabel(index, value)
        saveGains()
        markCustom()
    }

    @objc private func bypassChanged(_ sender: NSButton) {
        eq.bypass.value = sender.state == .on
        defaults.set(sender.state == .on, forKey: "eq.bypass")
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let name = sender.titleOfSelectedItem ?? "Custom"
        guard let preset = presets.first(where: { $0.name == name }) else {
            defaults.set("Custom", forKey: "eq.preset")
            return
        }
        for index in 0..<10 {
            eq.gains[index].value = Float(preset.gains[index])
            sliders[index].doubleValue = preset.gains[index]
            updateValueLabel(index, preset.gains[index])
        }
        saveGains()
        defaults.set(name, forKey: "eq.preset")
    }

    @objc private func resetToFlat(_ sender: NSButton) {
        presetPopup.selectItem(withTitle: "Flat")
        presetChanged(presetPopup)
    }

    private func updateValueLabel(_ index: Int, _ value: Double) {
        if abs(value) < 0.05 {
            valueLabels[index].stringValue = "0"
        } else {
            valueLabels[index].stringValue = String(format: "%+.1f", value)
        }
    }

    private func saveGains() {
        let values = (0..<10).map { Double(eq.gains[$0].value) }
        defaults.set(values, forKey: "eq.gains")
    }

    private func markCustom() {
        presetPopup.selectItem(withTitle: "Custom")
        defaults.set("Custom", forKey: "eq.preset")
    }

    func show() {
        reloadFromDSP()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
