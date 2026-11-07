# SoundBridge v0.3

Third release. Adds user-recordable global shortcuts for volume and mute.

## What's new

- **Configurable global shortcuts**
  - Volume Up / Volume Down: 1/16 (6.25%) per press
  - Mute: toggle
  - click a recorder button and press the key combination
  - `Delete` clears, `Esc` cancels
  - shortcuts are off by default; native volume keys and OSD still work
  - registered with Carbon `RegisterEventHotKey` — **no Accessibility
    permission** required
  - custom shortcuts do not show the system OSD; the menu bar percentage updates
- **Shortcuts tab** in the control panel, also reachable from the status menu
- Existing v0.2 features remain:
  - pre-amp gain −15…+15 dB before the EQ, protected by the limiter
  - login item under **Open at Login**, cleaned up on uninstall
  - 10-band EQ, Spatial/Hall, look-ahead limiter
  - shared-memory transport, no microphone permission
  - dynamic About tab, UID-based wake rebinding

## Assets

| File | Size | SHA-256 |
|---|---|---|
| `SoundBridge.pkg` | 615 KB | `41276ff64e56cbf7bf1dc4458c12fc74b9a9fcee4628cab164be865049a7cbc5` |
| `Uninstall.SoundBridge.pkg` | 3.6 KB | `178db4630ef41d6d2e4f15b2c8e6b87050ec72b316b1e74ab9f6daaa5e3b7e89` |

> The app and HAL plugin are ad-hoc signed; the PKGs are unsigned. This is a
> personal/self-use build. If Gatekeeper blocks a double-click, right-click →
> Open, or use `sudo installer` as shown below.

## Requirements

- macOS 14.0 or newer
- Apple Silicon (`arm64`)
- A physical HDMI / DisplayPort audio output
- Tested on macOS 14.6 / MacBook Air M3 with LECOO M3221PL (DisplayPort)

## Install

1. Download `SoundBridge.pkg`.
2. Double-click it, or:

```bash
sudo installer -pkg SoundBridge.pkg -target /
```

The installer copies:

- `/Applications/SoundBridge.app`
- `/Library/Audio/Plug-Ins/HAL/SoundBridge.driver`

and restarts `coreaudiod` — audio is interrupted for 2–3 seconds.

Then open **SoundBridge.app**. The menu bar shows a speaker icon. Clicking it
switches the system default output to SoundBridge (can be disabled in the menu).
No microphone permission is requested.

## Shortcuts

Open **Control Panel → Shortcuts** (or the status menu → **Shortcuts…**):

- click the recorder next to **Volume Up**, **Volume Down** or **Mute**
- press the desired combination, e.g. `⌃⌥↑`, `⌃⌥↓`, `⌃⌥M`
- `Delete` clears a shortcut, `Esc` cancels
- if a combination is already taken, the previous setting is kept and a warning
  is shown

## Uninstall

Download `Uninstall.SoundBridge.pkg`, double-click it, or:

```bash
sudo installer -pkg "Uninstall.SoundBridge.pkg" -target /
```

It will:

- quit the app
- unregister the app's login item
- remove the HAL plugin and `/Applications/SoundBridge.app`
- remove `/tmp/soundbridge_ring_v1`, logs and preferences
- restart `coreaudiod` and Dock

SpeakerAmp / BlackHole / MAXHUB are not modified.

## Known limitations

- Ad-hoc signed / not notarized; personal use only
- No Intel build
- CPU around 2.5% on an M3 with `AUMatrixReverb` enabled
- Spatial processing is calibrated by ear against SpeakerAmp, not bit-identical
- Custom shortcuts do not trigger the system OSD
- The shared-memory ring is a local file in `/tmp`; audio never leaves the Mac
- No App Store distribution

## Notes

- SpeakerAmp is **not** required and is not modified by the installer. It can
  remain installed as a fallback.
- This project is not affiliated with SpeakerAmp.
- Source, build instructions and design notes:
  https://github.com/jerryforgit/SoundBridge

**Full Changelog**: https://github.com/jerryforgit/SoundBridge/commits/v0.3

---

## 中文说明

SoundBridge v0.3 第三个版本。

新增：

- **可录制的全局快捷键**
  - 音量 + / 音量 −：每次 1/16（6.25%）
  - 静音：切换
  - 点击录制按钮后按下组合键，`Delete` 清除，`Esc` 取消
  - 默认不设置；系统音量键、OSD、静音键仍然照常工作
  - 使用 Carbon 注册，**不需要辅助功能权限**
  - 自定义快捷键不会触发系统 OSD，菜单栏百分比会更新
- **快捷键标签页**，也可以从状态栏菜单进入

v0.2 的功能继续保留：

- 前置增益 −15…+15 dB（EQ 前应用，限幅器保护）
- 登录项显示在「登录时打开」，卸载时清理
- 10 段 EQ、Hall 空间感、look-ahead 限幅器
- 共享内存传输，不需要麦克风权限
- 动态 About 页、UID 唤醒重绑

安装：双击 `SoundBridge.pkg`，音频会中断 2–3 秒。
卸载：双击 `Uninstall.SoundBridge.pkg`。
SpeakerAmp 不会被卸载，可随时回退。
