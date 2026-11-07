# SoundBridge v0.4

Universal build: Apple Silicon and Intel, macOS 13.0 or newer.

## What's new

- **Universal binary**
  - app and HAL plugin are now `arm64 + x86_64`
  - Apple Silicon runs natively; Intel Macs use the `x86_64` slice
- **Minimum macOS lowered to 13.0 (Ventura)**
  - `SMAppService`, the shared-memory transport, EQ, spatial processing and the
    gain stage are all available on Ventura
  - no LaunchAgent fallback is needed at this minimum
- Existing v0.3 features remain:
  - configurable global shortcuts for volume up/down and mute
    (Carbon, no Accessibility permission)
  - pre-amp gain −15…+15 dB before the EQ, protected by the limiter
  - login item under **Open at Login**, cleaned up on uninstall
  - 10-band EQ, Spatial/Hall, look-ahead limiter
  - shared-memory transport, no microphone permission
  - dynamic About tab, UID-based wake rebinding

## Assets

| File | Size | SHA-256 |
|---|---|---|
| `SoundBridge.pkg` | 937 KB | `134d933793bec8195ddb13c886b8bbb4159e7df05d5d99d8357636e318ee81bb` |
| `Uninstall.SoundBridge.pkg` | 3.6 KB | `8decd7a7a1105b374196946f3643d4b4e0ac4a7488f4294e9ef8984203e0942b` |

> The app and HAL plugin are ad-hoc signed; the PKGs are unsigned. This is a
> personal/self-use build. If Gatekeeper blocks a double-click, right-click →
> Open, or use `sudo installer` as shown below.

## Requirements

- **macOS 13.0 or newer (Ventura+)**
- Apple Silicon (`arm64`) or Intel (`x86_64`)
- A physical HDMI / DisplayPort audio output
- Tested natively on macOS 14.6 / MacBook Air M3 with LECOO M3221PL
- x86_64 app slice verified under Rosetta; x86_64 HAL driver needs an Intel
  machine for final verification

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

**Full Changelog**: https://github.com/jerryforgit/SoundBridge/commits/v0.4

---

## 中文说明

SoundBridge v0.4：Universal 构建，支持 Apple Silicon 和 Intel，最低 macOS 13.0。

新增 / 变化：

- **Universal 二进制**
  - App 和 HAL 插件都是 `arm64 + x86_64`
  - Apple Silicon 原生运行，Intel Mac 使用 `x86_64` 切片
- **最低系统降到 macOS 13.0（Ventura）**
  - `SMAppService`、共享内存、EQ、空间感、增益在 Ventura 上都可用
  - 这个最低版本不需要 LaunchAgent fallback
- v0.3 功能继续保留：
  - 可录制全局快捷键：音量 +、音量 −、静音（Carbon，不需要辅助功能权限）
  - 前置增益 −15…+15 dB（EQ 前应用，限幅器保护）
  - 登录项显示在「登录时打开」，卸载时清理
  - 10 段 EQ、Hall 空间感、look-ahead 限幅器
  - 共享内存传输，不需要麦克风权限
  - 动态 About 页、UID 唤醒重绑

安装：双击 `SoundBridge.pkg`，音频会中断 2–3 秒。
卸载：双击 `Uninstall.SoundBridge.pkg`。
SpeakerAmp 不会被卸载，可随时回退。
