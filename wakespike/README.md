# wakespike — 唤醒 / UID 重绑验证工具

这是 P1 的一次性验证工具，**不是最终 App**。它不安装任何东西，不需要 sudo，也不改系统默认输出。

目的：验证 macOS 14.6 上，用户态进程在合盖睡眠/唤醒后，能不能按 UID 重新找到 HDMI 端点并自动恢复出声。

## 构建

```bash
cd speakeramp-replacement/wakespike
./build.sh
```

## 先看设备

```bash
./wakespike --list
```

确认当前外接显示器的音频端点 `outCh=2`、格式是 `float=1`。工具默认会自动选第一个 HDMI/DisplayPort 且有声道的物理输出；也可以用 `--uid <uid>` 指定。

> 2026-11-06 本机实测：当前接的是 **LECOO M3221PL（DisplayPort，UID `30A30132-0000-0000-0120-0104B5472878`）**，SPEC 里的 COOCAA 27 4K 当前不在设备列表里。两者都适用；换回 COOCAA 时用 `--uid 26130027-0000-0000-2522-010380000078` 即可。

## 跑测试音

```bash
./wakespike
```

默认行为：

- 自动选当前 HDMI/DisplayPort 物理输出，播 440 Hz 测试音，−20 dBFS
- 2 秒一个“呼吸”包络，避免长时间单音刺耳
- 日志写到 `~/Library/Logs/SoundBridge/wakespike.log`，同时打印到终端
- 监听设备增删、`DeviceIsAlive`、`didWake`、`screensDidWake`
- 设备消失 → 静音待命；设备重建 → 自动按 UID 重绑，淡入

指定设备：

```bash
./wakespike --uid 30A30132-0000-0000-0120-0104B5472878
```

停止：`Ctrl-C`。

只跑 5 秒做冒烟测试：

```bash
./wakespike --duration 5
```

## 合盖测试步骤

1. 运行 `./wakespike`，确认显示器出声（测试音在 HDMI 上，SpeakerAmp 仍是系统默认输出，两者会混音，正常）。
2. 保持终端窗口开着（合盖会睡眠，终端不用管）。
3. 合盖，等 10 秒，唤醒。
4. 听测试音是否在 1 秒内恢复。
5. 看终端/日志里的 `REBIND: old id=... -> new id=...` 和 `IO STARTED` 时间戳。
6. 重复 10 次。

日志关键行：

```
event: device list changed
event: device 87 alive changed (alive=0)
device unavailable; entering silent standby
event: system did wake
REBIND: old id=87 -> new id=33225 (uid unchanged)
IO STARTED: id=33225 ...
```

成功标准：每次唤醒后都能看到新的 `IO STARTED`，并且测试音恢复。

## 常见问题

- **没有声音**：先 `--list` 看 `outCh` 和 `format`；如果格式不是 float32，把输出贴给我。
- **测试音和 SpeakerAmp 同时出声**：正常。两者都是 HDMI 的客户端，CoreAudio 会混音。
- **权限**：这个工具不需要麦克风、辅助功能、屏幕录制权限。
