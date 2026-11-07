# SoundBridge v0.2

Second release. Adds a pre-amp gain control and fixes the login item so it
appears under **Open at Login**.

## What's new

- **Pre-amp gain −15…+15 dB**
  - new slider in the **Spatial** tab
  - applied before the 10-band EQ
  - positive gain is protected by the look-ahead limiter
  - persisted in `output.gainDB`
  - matches the idea of SpeakerAmp's per-device pre-amp attenuator
    (0…−15 dB) and also allows boost
- **Login item now uses `SMAppService`**
  - appears under System Settings → General → Login Items → **Open at Login**
  - the installer unregisters the old build's item before replacing the app
  - the new build re-registers on launch when launch-at-login is enabled
  - avoids stale records caused by ad-hoc signing / changing cdhash
- **Uninstaller**
  - unregisters the login item
  - removes app, HAL plugin, shared memory, preferences and logs
  - restores the previous output
- **About tab** now reads the version, app path and current output dynamically
- **PKG install** no longer relocates `SoundBridge.app` into the build folder

## Assets

| File | Size | SHA-256 |
|---|---|---|
| `SoundBridge.pkg` | 586 KB | `59942db70df5312849ce22750379f0e6f5ff442b67c57ac5a3de015c98624a41` |
| `Uninstall.SoundBridge.pkg` | 3.6 KB | `501444c14328d972a6774b3ecf12076aa90d075c2006706ff253fda61d14f5ff` |

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
- The shared-memory ring is a local file in `/tmp`; audio never leaves the Mac
- No App Store distribution

## Notes

- SpeakerAmp is **not** required and is not modified by the installer. It can
  remain installed as a fallback.
- This project is not affiliated with SpeakerAmp.
- Source, build instructions and design notes:
  https://github.com/jerryforgit/SoundBridge

**Full Changelog**: https://github.com/jerryforgit/SoundBridge/commits/v0.2

---

## 中文说明

SoundBridge v0.2 第二个版本。

新增：

- **前置增益 −15…+15 dB**
  - 在「空间感」页
  - EQ 之前应用，正增益由限幅器保护
  - 设置保存在 `output.gainDB`
  - 对应 SpeakerAmp 的 Pre-amp attenuator（0…−15 dB），同时支持提升
- **登录项改为 `SMAppService`**
  - 显示在 系统设置 → 通用 → 登录项 → **登录时打开**
  - 安装时先注销旧 build 的登录项，新 build 启动后按偏好重新注册
- **卸载包**
  - 注销登录项，删除 App、HAL 插件、共享内存、设置和日志
  - 恢复之前的输出设备
- **关于页**改为动态版本、App 路径和当前输出
- **PKG 安装**不再把 App 重定位到构建目录

安装：双击 `SoundBridge.pkg`，音频会中断 2–3 秒。
卸载：双击 `Uninstall.SoundBridge.pkg`。
SpeakerAmp 不会被卸载，可随时回退。
