# 唤醒测试记录

## 2026-11-06 · 单次合盖睡眠/唤醒（LECOO）

环境：MacBook Air M3 / macOS 14.6 / LECOO M3221PL（DisplayPort）/
UID `30A30132-0000-0000-0120-0104B5472878`。
工具：`wakespike`（直接写物理端点，绕过 SpeakerAmp）。

### 原始时间线

```
12:59:03.519  event: system will sleep; bound=111
13:00:13.375  event: device 111 alive changed (alive=false)
13:00:13.384  event: device list changed
13:00:13.723  reconcile: found=nil -> silent standby
13:00:13.900  event: system did wake
13:00:13.900  IO STOPPED: id=111 stopErr='!dev'      ← 旧设备已销毁，预期
13:00:14.183  reconcile: found=161 alive=true
13:00:14.184  BIND: id=161 (同一 UID)
13:00:15.222  IO STARTED: id=161
13:00:16.588  event: device 161 alive=false           ← 第二次重建
13:00:18.611  watchdog: device 161 not healthy
13:00:18.934  silent standby / waiting for UID
13:00:18.934  event: system will sleep                ← 系统又短暂睡了一次
13:00:22.359  reconcile: found=176 alive=true
13:00:22.600  BIND: id=176 (同一 UID)
13:00:23.043  IO STARTED: id=176
13:00:26.079  event: system did wake
13:00:26.447  reconcile [didWake]: found=176, running=true -> no-op
13:00:35+     status: bound=176 running=true（持续稳定）
```

### 结果

- **声音恢复**（用户确认）。
- 端点 ID 变化：`111 → 161 → 176`，**UID 始终不变**。
- 没有按旧 `AudioObjectID` 重试，也没有在 161 上死等；watchdog + 设备列表通知把它带到了最终的 176。
- 第二次唤醒时 176 已经 running，`reconcile` 正确判断为健康，**没有做多余的 stop/start**（避免二次爆音/中断）。
- 这正是 SPEC 里说的“显示器上电两轮 Deinit → Init 抖动”；SpeakerAmp 的 devId 逻辑会在这里失败，按 UID 的状态机通过了。

### 时间说明

- 首次唤醒后 1.3 s 内就绑定了 161（13:00:13.9 → 13:00:15.2）。
- 但 OS 随后把 161 也销毁了，并再次短暂睡眠；最终稳定端点 176 在 13:00:23.0 开始出声。
- 这段 9 s 是**异常的双重建 + 二次睡眠**造成的，不是状态机卡住；正常单次唤醒应在 1 s 级恢复。
- 下一次 10 连测会给出正常/异常唤醒的分布。

## 2026-11-06 · 10 连测（LECOO）

- 10 次睡眠 / 10 次唤醒
- **10/10 自动恢复，无任何手动操作**
- 0 个 ERROR
- 端点 ID 序列：`111 → 161 → 176 → 191 → 206 → 221`，**UID 始终不变**
- 恢复延迟（从 `system did wake` 到 `IO STARTED`，或确认已 running）：

| # | 唤醒时间 | 恢复 | 说明 |
|---|---|---|---|
| 1 | 13:03:25.406 | 1.896 s | 161 在睡眠中已重建；唤醒后系统把 IO 停了，重启 |
| 2 | 13:03:49.397 | 0.459 s | 161 原地重启 |
| 3 | 13:04:13.504 | 4.194 s | 161 销毁 → 176；OS 重建端点花了约 4 s |
| 4 | 13:04:40.148 | 0 s | 176 保持 running，唤醒时已在跑 |
| 5 | 13:05:05.584 | 3.873 s | 176 销毁 → 191；端点出现后约 0.2 s 绑定 |
| 6 | 13:05:31.760 | 0.478 s | 191 原地重启 |
| 7 | 13:05:55.786 | 0.955 s | 191 销毁 → 206 |
| 8 | 13:06:19.946 | 0 s | 206 保持 running |
| 9 | 13:06:44.449 | 0.630 s | 206 销毁 → 221 |
| 10 | 13:07:09.732 | 0 s | 221 保持 running |

统计：`0s × 3`，`≤1s × 4`，`1.896s × 1`，`~4s × 2`。

结论：

- **验收标准 #1 的“无需手动操作”通过。**
- 端点可用时，绑定/重启都在 0.46–0.96 s；两次 ~4 s 是 macOS 自身重建端点的时间，端点不存在时任何 App 都无法出声。
- 三次唤醒端点根本没被销毁，IO 一直 running，恢复时间 0 s。
- 每次唤醒系统默认输出都会短暂切到内置扬声器再切回 SpeakerAmp；P3 需要监听默认输出，必要时重新声明自己。

### 根据这次结果做的改进

- `Logger` 改为异步写入：唤醒事件风暴时，状态机线程不再被 stdout/磁盘日志阻塞。
- 重试间隔在头 10 秒内上限 1 s（`0.2 / 0.5 / 0.5 / 1 / 1 … / 2`），更快抓住端点出现。

## 2026-11-06 · P2/P3/P4（插件 + 引擎 + 最终唤醒）

### P2 HAL 插件 v0

- `SoundBridge.driver` 安装后设备出现：`id=127`，UID `com.jerry.soundbridge.device`
- 2ch / 48 kHz / float32，输出+输入各一条 stream
- 系统音量键实测：
  - SoundBridge `device.volumeScalar`: `1.0000 → 0.8789`
  - 系统 `output volume`: `100 → 88`
  - BetterDisplay DDC volume: `1.0 → 1.0`（没被改）
- 静音键实测：`device.mute 0 → 1`，系统 `output muted=true`
- 结论：原生音量键 / OSD 确实走 SoundBridge，不是 BetterDisplay。

### P3 引擎 v0

- `SoundBridge` input → ring（16384 帧）→ `LECOO` output
- 48 kHz float32，输出按 UID 解析
- 启动后 ring 稳定在 700–1000 帧
- 系统默认输出切到 SoundBridge 后，`Glass` 音效经引擎从 LECOO 出声

### P4 唤醒加固

10 连测（修复前）结果：10/10 恢复，输出 ID 序列 `54 → 175 → 190 → 205 → 220 → 235 → 250`，UID 不变。
但发现两个问题：

1. 重绑后 ring 冲到 16384 帧（341 ms），需要 1–2 分钟才排空。
2. 睡眠过渡期间 watchdog 误判 input 无帧，连续重启 5 次。

修复：

- `AudioRing.setReadPosition()`：重绑/启动时精确对齐读写索引，不再只向前推。
- `willSleep` 标志：睡眠期间 watchdog 暂停。
- `didWake` 时强制 prefill，把睡眠期间积压的数据丢掉并重新淡入。
- 输入/输出“有 running 但无帧/无回调”1 秒检测，真正卡死才重启。
- 漂移控制器改成 PI（比例+积分），消除固定时钟差造成的稳态偏移。

最终单次唤醒（2026-11-06 13:52）：

```
13:52:26.249  system will sleep
13:52:45.395  system did wake
13:52:45.795  output REBIND: 125 → 174 (uid unchanged)
13:52:46.753  OUTPUT STARTED ring=828
13:52:46.812  status ring=956
13:52:56.855  status ring=1087
```

- 睡眠期间 0 次 watchdog 重启
- 唤醒到 OUTPUT STARTED 约 1.36 s
- ring 保持在 ~1k，延迟约 20 ms 级
- 声音恢复

## 2026-11-06 · P5 菜单栏 App 最终 10 连测

- App：`/Applications/SoundBridge.app`，菜单栏图标 + 音量滑块 + 静音 + 输出设备 + 默认输出 + 日志 + 退出
- `launch at login enabled` 14:11:40，登录项已注册
- 11 次睡眠 / 11 次唤醒（10 次手动 + 1 次系统自动唤醒）
- 输出 ID：`125 → 176 → 191 → 206 → 221`，UID 始终不变
- 每次唤醒都恢复出声；睡眠期间没有 watchdog 误重启
- 自动唤醒原因：`SMC.OutboxNotEmpty smc.70070000 wifibt bluetooth-pcie/` + `HID Activity`，是 macOS/蓝牙/USB-C HID 触发，不是 App
- ring：多数唤醒后 500–1100 帧；少数唤醒后冲到 6000–16384 帧，再慢慢排空
- 遗留问题：少数唤醒后会有短暂的 130–340 ms 延迟（声音不丢，但会晚一点）
- 建议修复：ring > 8192 时直接把读指针跳到 `writePosition - 1024` 并淡入，牺牲一次极短的淡入换低延迟

## 2026-11-06 · ring reset 验证（M1 收尾）

- 唤醒后 ring 冲到 8704 帧，输出回调 0.14 秒内把它拉到 896
- 这次遇到第二次设备重建：`177 → 193 → 208`，UID 不变
- 第二次重建导致输入流短暂停帧，flow watchdog 重启 input；最终 `OUTPUT STARTED id=208`，ring 512–896
- 默认输出保持 SoundBridge，音量/静音正常
- 用户确认“感觉挺正常的”

**M1 完成。**

## 2026-11-06 · 共享内存 + 去掉麦克风权限（最终架构）

- 插件改为把音量处理后的音频写入 `/tmp/soundbridge_ring_v1`
- App 引擎直接读共享内存，不再打开 SoundBridge 的 input stream
- 日志确认：`shared memory: available`，`input=shared`，**0 次 `INPUT STARTED`**
- `tccutil reset Microphone com.jerry.soundbridge` 后重新启动，不再弹录音权限
- 状态栏橙色麦克风指示器消失
- 应用 Info.plist 已移除 `NSMicrophoneUsageDescription`

### 最终 10 连测（共享内存）

- 10 次睡眠 / 10 次唤醒，0 次 input IO
- 输出 ID：`54 → 177 → 192 → 207 → 222`，UID 不变
- 无 watchdog 错误、无 `output unavailable`
- 旧版共享内存泵入只读当前 buffer，ring 经常在 1 附近；已改为每次补齐到目标 1024 帧
- 440 Hz 测试：ring 514–720，shm write/read 差 192（无积压、无 underrun）

## 待做

- [x] 10 段 EQ + look-ahead 限幅器（默认 Flat）
- [x] 空间感 Hall（AUMatrixReverb Large Hall，wet 50 校准）
- [x] 最终 App 10 连测（共享内存版本，10/10）
- [x] 彻底去掉麦克风权限 / 橙色麦克风
- [x] 新泵入逻辑下做 1–2 次唤醒复测
- [x] 连续播放 2 小时，观察 CPU / 内存 / ring
- [x] 卸载测试：移除插件后系统音频恢复正常
- [x] PKG 卸载包测试（删除 App + 插件 + 设置 + 日志 + 登录项）

## 2026-11-06 · 2 小时 soak

- 17:43:37 → 19:46:57，−60 dB 粉红噪声循环
- RSS 19.6 MB → 19.8 MB（+224 KB）
- CPU 2.0% → 2.5%（AUMatrixReverb 是主要成本）
- 697 次状态采样：ring min 114 / median 512 / max 838
- ring < 64 帧：0 次；无 `OUTPUT STOPPED`、无 watchdog 错误、无 `INPUT STARTED`
- 进程 PID 全程不变

## 2026-11-06 · PKG 安装修复 + 验证

第一次 `SoundBridge.pkg` 双击安装失败：

- Installer 把 `SoundBridge.app` 重定位到构建目录
  `packaging/build/install-root/Applications/SoundBridge.app`
- `postinstall` 的 `chown /Applications/SoundBridge.app` 因此失败

修复：

- `pkgbuild --analyze` 生成 component plist，两个 bundle 都设置
  `BundleIsRelocatable=false`
- 新增 `preinstall`：安装前 `pkill -x SoundBridge`
- `postinstall` 先检查 App/插件是否存在，再 `chown`/`chmod`
- 构建完成后删除 staging root，避免再成为重定位候选

重新安装验证：

- Installer 返回 `The install was successful.`
- `/Applications/SoundBridge.app` 与
  `/Library/Audio/Plug-Ins/HAL/SoundBridge.driver` 均在正确路径
- 两者 `codesign -v` 通过
- 系统设备列表出现 `SoundBridge`，默认输出成功切换
- App 启动后 `OUTPUT STARTED id=54`，`input=shared`
- 440 Hz 测试：ring 546，无麦克风权限/无 input





## 2026-11-06 · PKG 卸载验证 + LaunchAgent 登录项

第一次卸载测试发现两个遗漏：

- `~/Library/Logs/SoundBridge` 和偏好设置未删除
- 登录项未注销

原因：这台机器 `/dev/console` 属主是 `root`，卸载脚本用
`stat -f%Su /dev/console` 判断当前用户时得到 `root`，跳过了用户级清理。

修复：

- 用户检测改为依次尝试：`/dev/console` → `scutil ConsoleUser` →
  Dock 进程属主 → `who`
- 登录项从 `SMAppService` 改为 LaunchAgent：
  `~/Library/LaunchAgents/com.jerry.soundbridge.plist`
  - SMAppService 按 cdhash 记录，ad-hoc 每次重建都会留下旧记录，卸载器无法清理
  - LaunchAgent 是普通文件，卸载器可直接 `launchctl bootout` + 删除
- 卸载器同时保留旧版 `--unregister-login` 调用，兼容早期 SMAppService 记录

重新安装 → 启用登录项 → 卸载，结果：

- `/Applications/SoundBridge.app`：已删除
- `/Library/Audio/Plug-Ins/HAL/SoundBridge.driver`：已删除
- `~/Library/LaunchAgents/com.jerry.soundbridge.plist`：已删除
- `launchctl print gui/501/com.jerry.soundbridge`：不存在
- `~/Library/Logs/SoundBridge`：已删除
- `~/Library/Preferences/com.jerry.soundbridge.plist`：已删除
- `/tmp/soundbridge_ring_v1`：已删除
- 默认输出恢复 SpeakerAmp
- SpeakerAmp / Syncthing 的登录项不受影响

LaunchAgent 启动路径也验证过：

- `--login on` 生成 plist 并 `bootstrap`
- `launchctl print` 显示 `state = running`
- App 以 `--background` 启动，只驻留菜单栏，不打开控制面板
- `--login off` 卸载 job 并删除 plist

## 2026-11-06 · About 页改为动态信息

原来 About 页写死了 `/Users/jerry/Syncthing/repos/jerry/SoundBridge`、
`LECOO M3221PL` 和版本号。现在：

- 版本 / build：读取 `Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`
- 当前输出：按引擎的 `selectedOutputUID` 解析设备名（`findDevice` + `deviceName`）
- App 位置：`Bundle.main.bundlePath`
- 项目主页：GitHub 仓库链接
- 安装 / 卸载：改为两个 PKG 的名称

About 文本在每次切换到「关于」标签时刷新。中英文均已通过辅助功能读取验证：

- 中文：`SoundBridge 0.1 (build 0.1)`、`当前输出：LECOO M3221PL`、
  `App 位置：/Applications/SoundBridge.app`
- 英文：`Current output: LECOO M3221PL`、`App location: /Applications/SoundBridge.app`

## 2026-11-06 · 登录项最终方案：SMAppService

LaunchAgent 方案实测不符合预期：

- LaunchAgent 只出现在 系统设置 → 通用 → 登录项 → **允许在后台**
- **登录时打开** 列表里看不到 SoundBridge
- 卸载后「允许在后台」还可能短暂保留条目

已撤销 LaunchAgent，回到 `SMAppService.mainApp`，并解决 ad-hoc cdhash
变化导致的旧记录问题：

- 安装包 `preinstall` 在替换 App 之前，以当前登录用户运行旧 App 的
  `--unregister-login`，注销旧 build 的登录项
- 新 App 首次启动时，如果 `launchAtLogin` 偏好为 true，自动
  `register()` 当前 build
- 卸载器仍调用 `--unregister-login`，覆盖当前 build 的记录
- App 启动时顺带删除早期 LaunchAgent 的 plist 并 `bootout`

系统设置实测：

- 开启后 **登录时打开** 显示 `SoundBridge`，类型为「应用程序」
- 关闭 / 注销后 **登录时打开** 中不再显示 SoundBridge
- **允许在后台** 中没有 SoundBridge
- BTM 记录为 `Type: app`、`Bundle Identifier: com.jerry.soundbridge`

## 2026-11-07 · 前置增益（v0.2）

在「空间感」页加入 Gain 滑块：

- 范围 −15…+15 dB，1 dB 步进
- 在 EQ 之前应用；正增益由 look-ahead limiter 保护
- 每个音频块内做增益渐变，拖动滑块不会产生 click
- 保存到 `output.gainDB`，重启后恢复

DSP 离线测试（440 Hz，0.1 幅度，limiter 关闭）：

```
0 dB  RMS 0.070669
-6 dB RMS 0.035418  ratio 0.5012  (理论 0.5012)
+6 dB RMS 0.141002  ratio 1.9953  (理论 1.9953)
```

UI 测试：

- 滑块显示 `+0 dB` / `+6 dB`
- 辅助功能设置 `slider 4 = 6` 后，`defaults read output.gainDB` 为 6
- 退出重开后滑块回到 6
- 重置为 0 后设置写回 0
- 截图：`docs/images/control-panel.png`

limiter 保护测试（+15 dB，输入 0.5 幅度，阈值 −1 dBFS）：

```
gain 0   RMS 0.3533  peak 0.5000
gain +15 RMS 0.6300  peak 0.8915  (阈值 0.8913，overshoot 0.0002)
```

v0.2 安装后验证：

- App / 插件版本均为 0.2
- 默认输出 SoundBridge，OUTPUT STARTED id=54
- Gain 滑块显示 `+0 dB`，`output.gainDB = 0`
- 登录项 `--login status` = enabled
- 440 Hz 测试 ring 572–646

## 2026-11-07 · 全局快捷键（v0.3）

在「快捷键」页加入三个可录制动作：

- 音量 +：每次 +1/16（6.25%）
- 音量 −：每次 −1/16
- 静音：切换

实现：

- `ShortcutRecorderButton` 录制组合键，Delete 清除，Esc 取消
- `HotKeyManager` 用 Carbon `RegisterEventHotKey` 注册，不需要辅助功能权限
- 冲突时保留旧设置并显示提示
- 保存为 JSON 到 `shortcut.volumeUp` / `shortcut.volumeDown` / `shortcut.mute`

UI / 功能验证：

- 录制 `⌃⌥↑`、`⌃⌥↓`、`⌃⌥M`，按钮标题正确显示
- 重启 App 后三个快捷键仍然显示并生效
- 实际按键日志：

```
16:09:44 hotkey: volume 13%
16:09:45 hotkey: volume 6%
16:09:46 hotkey: mute true
16:10:22 hotkey: mute true
16:10:40 hotkey: mute false
```

- 清除全部后 `defaults` 中不再有 `shortcut.*`
- 截图：`docs/images/shortcuts.png`
- 测试结束后已清空快捷键，默认保持未设置
