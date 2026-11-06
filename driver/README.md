# SoundBridge HAL plugin v0

这是 P2 的虚拟设备插件，**只做设备 + 原生音量/静音 + loopback**，不做 DSP、不碰物理输出。DSP 和 HDMI 转发在 P3 的引擎里。

## 它发布什么

- 设备名：`SoundBridge`
- UID：`com.jerry.soundbridge.device`
- 2ch / 48 kHz / float32
- 一个 output stream（客户端写入）+ 一个 input stream（引擎读取）
- output stream 带 Volume / Mute 控件 → 系统音量键、OSD、控制中心
- 插件内部 16384 帧 ring buffer，固定 loopback 延迟 512 帧（10.7 ms）

## 构建

```bash
cd speakeramp-replacement/driver
./build.sh
```

产物：`driver/build/SoundBridge.driver`（arm64，ad-hoc 签名）。

依赖：[libASPL](https://github.com/gavv/libASPL)（MIT），已 vendored 在 `driver/third_party/libASPL`，不需要 CMake。

## 安装（需要 sudo，音频中断 2–3 秒）

```bash
cd speakeramp-replacement
./scripts/install.sh
```

脚本会先打印完整命令并等待确认，然后：

```bash
sudo rm -rf "/Library/Audio/Plug-Ins/HAL/SoundBridge.driver"
sudo cp -R "driver/build/SoundBridge.driver" "/Library/Audio/Plug-Ins/HAL/SoundBridge.driver"
sudo chown -R root:wheel "/Library/Audio/Plug-Ins/HAL/SoundBridge.driver"
sudo chmod -R 755 "/Library/Audio/Plug-Ins/HAL/SoundBridge.driver"
sudo killall coreaudiod
```

`coreaudiod` 会自动重启；音频中断 2–3 秒。SpeakerAmp 不会被卸载，默认输出也不会被改。

## 验证设备

```bash
./tools/audiodefault list
```

应该能看到：

```
<id> SoundBridge uid=com.jerry.soundbridge.device
```

切到它：

```bash
./tools/audiodefault set com.jerry.soundbridge.device
```

然后按 F10/F11/F12、静音键，看系统 OSD 是否显示 SoundBridge 的音量。

> 注意：P2 阶段还没有引擎，SoundBridge 是一个“只进不出”的 loopback。切它做默认输出后系统声音会静音，这是预期的。验证完切回：

```bash
./tools/audiodefault set com.nimblesnail.adrv112   # SpeakerAmp
# 或
./tools/audiodefault set 30A30132-0000-0000-0120-0104B5472878   # LECOO
```

## 卸载 / 回退

```bash
cd speakeramp-replacement
./scripts/uninstall.sh
```

或者手动：

```bash
sudo rm -rf "/Library/Audio/Plug-Ins/HAL/SoundBridge.driver"
sudo killall coreaudiod
```

## 已知待验证

- 系统音量键 / OSD 是否能直接驱动 output stream 的 VolumeControl。
  - 如果不能，下一步会在 `aspl::Device` 上补 `kAudioDevicePropertyVolumeScalar` / `Mute` 的设备级属性。
- loopback 的 512 帧延迟和读写顺序，需要 P3 引擎接上后实测。
