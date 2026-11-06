# SoundBridge v0.1

First public release of SoundBridge — a macOS menu bar audio bridge for HDMI /
DisplayPort displays.

SoundBridge creates a virtual output device with native macOS volume/mute,
applies a 10-band EQ and spatial processing, and forwards audio to the physical
display output by UID. It is designed to survive clamshell sleep/wake, including
the “device rebuilt twice” case that breaks ID-based routing.

## Highlights

- **HAL virtual output device** with native `VolumeScalar` / `Mute`
  - system volume keys, native OSD, Control Center and mute key just work
  - no Accessibility permission, no media-key interception
- **UID-based wake rebinding**
  - no cached `AudioObjectID`
  - debounce, backoff and silent standby while the display endpoint is gone
  - 10/10 clamshell sleep/wake recoveries during testing
- **Shared-memory audio transport**
  - plugin → engine via `/tmp/soundbridge_ring_v1`
  - **no microphone permission**, no orange microphone indicator
- **10-band EQ + look-ahead limiter**
  - 50 / 150 / 300 / 600 / 1k / 3k / 6k / 9k / 12k / 15k Hz
  - ±12 dB, default Flat
- **Spatial effect**
  - M/S widening, crossfeed, early reflections
  - Apple `AUMatrixReverb` Large Hall, wet 50, calibrated against SpeakerAmp
    Hall 50%
- **Menu bar app**
  - speaker icon whose sound waves follow volume
  - control panel with Spatial / Equalizer / About tabs
  - output-device picker, language switch (system / 中文 / English)
  - launch at login, engine log
- **Conventional PKG install / uninstall**
  - install app + HAL plugin, restart `coreaudiod`
  - separate uninstall PKG removes app, plugin, LaunchAgent login item, shared
    memory, preferences and logs

## Assets

| File | Size | SHA-256 |
|---|---|---|
| `SoundBridge.pkg` | 584 KB | `2a9167a9cc970cc7bee83647de98cf5931b5d737897b1d8241a9d86a57ae09e2` |
| `Uninstall SoundBridge.pkg` | 3.6 KB | `51613fdc319893f5a3c33e86ee3bf7c988a58f1840053c63148c1143fe9b8dc8` |

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

If an older build left a stale grant:

```bash
tccutil reset Microphone com.jerry.soundbridge
```

## Uninstall

Download `Uninstall SoundBridge.pkg`, double-click it, or:

```bash
sudo installer -pkg "Uninstall SoundBridge.pkg" -target /
```

It will:

- quit the app
- remove the app's LaunchAgent login item
- remove the HAL plugin and `/Applications/SoundBridge.app`
- remove `/tmp/soundbridge_ring_v1`, logs and preferences
- restart `coreaudiod` and Dock

SpeakerAmp / BlackHole / MAXHUB are not modified.

## Known limitations

- Ad-hoc signed / not notarized; personal use only
- No Intel build
- CPU around 2.5% on an M3 with `AUMatrixReverb` enabled (slightly above the
  original 2% target; the reverb is the dominant cost)
- Spatial processing is calibrated by ear against SpeakerAmp, not bit-identical
- The shared-memory ring is a local file in `/tmp`; audio never leaves the Mac
- No App Store distribution

## Notes

- SpeakerAmp is **not** required and is not modified by the installer. It can
  remain installed as a fallback.
- This project is not affiliated with SpeakerAmp.
- Source, build instructions and design notes:
  https://github.com/jerryforgit/SoundBridge

**Full Changelog**: https://github.com/jerryforgit/SoundBridge/commits/v0.1

---

## 中文说明

SoundBridge v0.1 首个公开版本。

- 虚拟输出设备 + 原生音量键 / OSD / 静音
- 按 UID 重绑，合盖睡眠唤醒不丢声音
- 插件 → 引擎走共享内存，不需要麦克风权限
- 10 段 EQ + look-ahead 限幅器
- 空间感使用 Apple AUMatrixReverb Large Hall，已和 SpeakerAmp Hall 50% 校准
- 菜单栏图标声波跟随音量；控制面板含空间感 / 均衡器 / 关于
- 中文 / English 可手动切换

安装：双击 `SoundBridge.pkg`，音频会中断 2–3 秒。
卸载：双击 `Uninstall SoundBridge.pkg`，会删除 App、插件、共享内存、设置和日志。
SpeakerAmp 不会被卸载，可随时回退。
