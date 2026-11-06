# 当前环境（2026-11-06 更新）

> 这份文件记录本机实测到的环境事实。SPEC §2 里的 COOCAA 数据是 2026-10-31 的历史值，**显示器已永久更换**，不要直接套用。

## 机器 / 系统

| 项 | 值 |
|---|---|
| 机型 | MacBook Air M3，`Mac15,12`，16 GB |
| 系统 | macOS 14.6（23G80） |
| 使用方式 | 合盖（clamshell）+ 外接显示器 + 交流电 |
| Xcode | 16.0（16A242d） |

## 显示器（当前）

| 项 | 值 |
|---|---|
| 型号 | **LECOO M3221PL** |
| 连接 | DisplayPort |
| 分辨率 | 4608 × 2592（UI 2304 × 1296 @ 60 Hz） |
| 主显示器 | 是 |
| 音频端点 | 名称 `LECOO M3221PL`，transport = DisplayPort，2ch，48 kHz |
| 音频 UID | `30A30132-0000-0000-0120-0104B5472878` |
| 实测格式 | float32，2ch，interleaved，bytesPerFrame = 8 |
| 当前设备 ID | 会随唤醒变化，**不要缓存**；本次实测为 111 |

## 已不再连接

- **COOCAA 27 4K**（HDMI，UID `26130027-0000-0000-2522-010380000078`）：2026-11-06 用户确认已永久换成 LECOO。
- SPEC §2 中 COOCAA 的 DDC 实测（VCP `0x62` / `0x10`、情景模式、RGB 增益、BetterDisplay `tagID=118`）**只适用于 COOCAA，不能直接套到 LECOO**。
- LECOO 的 DDC 音量/亮度、情景模式、BetterDisplay tagID 都还需要重新实测。

## 当前音频状态（实测）

- 系统默认输出：**SpeakerAmp**（虚拟设备）。
- SpeakerAmp 的 `cfg.xml` 里 `currentlySelectedDeviceUID` 仍指向 COOCAA UID，而 COOCAA 当前不存在；因此 SpeakerAmp 很可能处于“找不到目标”的静音状态。
- 本次唤醒测试用 `wakespike` **直接**打开 LECOO 物理端点，不经过 SpeakerAmp；测试音和 SpeakerAmp 的输出会由 CoreAudio 混音。
- 已安装驱动（`/Library/Audio/Plug-Ins/HAL/`）：
  - `BlackHole2ch.driver`
  - `MAXHUBAudio.driver`
  - `SpeakerAmpDrv.driver`（保留，作为回退，**不要卸载**）

## 开发约定

- 任何物理输出都**按 UID 解析**，绝不把 `AudioObjectID` 持久化。
- 当前唤醒测试工具：`wakespike/`，默认自动选第一个 HDMI/DisplayPort 物理输出；也可 `--uid` 指定。
- 每次安装 HAL 插件、`sudo killall coreaudiod` 之前，先告知用户并等待确认。
- BetterDisplay 继续负责亮度/分辨率；音量键最终只归新 App，DDC 音量固定为基准值（数值待 LECOO 实测后确定）。
