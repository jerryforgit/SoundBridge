# 自制音频 App —— 需求规格（交接文档）

> **2026-11-06 环境更新**：显示器已**永久换为 LECOO M3221PL（DisplayPort）**，音频 UID `30A30132-0000-0000-0120-0104B5472878`。§2 的 COOCAA 27 4K 数据（vendor 9747 / model 9984、DDC 实测、BetterDisplay `tagID=118`）仅作历史参考；LECOO 的 DDC/亮度/音量需重新实测。核心架构与验收标准不变。详见 `docs/ENVIRONMENT.md`。

> 目的：替换 SpeakerAmp，自己控制"菜单栏音量 + 音频优化（EQ / 空间感）+ 唤醒不丢声音"。
> 本文档自包含，新 session 只需读这一份即可开工。

---

## 1. 背景

当前用 SpeakerAmp 7.0（HAL 虚拟声卡 + App）作为系统默认输出，转发到显示器的 HDMI 音频端点。它的价值**不是增益**，而是：

1. 让 HDMI 输出**可调音量**（macOS 原生不给 HDMI 端点音量控制）
2. **系统音量键 + 菜单栏音量**可用
3. **10 段 EQ + 3D 空间效果**（用户说"听习惯了，去掉后声音明显变平"）

问题：**每次合盖睡眠/唤醒后经常没声音**，必须在 SpeakerAmp 里重选一次输出设备才恢复。

### 已定位的根因（已确认，勿重复调查）

```
每次 clamshell sleep/wake：
  HALS_Device::_Deactivate: deactivating device 32559  (UID 不变)
  HALS_Device::Activate:    activating   device 33225  (同一个 UID，新 ID)
  ... 下一次唤醒 33225 → 33293
```

- HDMI 端点每次唤醒都会被**销毁重建**，`AudioObjectID` 变化，**UID 不变**。
- SpeakerAmp 唤醒恢复逻辑按数字 `devId` 定位（二进制里有字符串 `Performing update after wake up for devId=`），指向已销毁的对象，落入 `Can't start output device` 分支后放弃重试。
- 竞态：唤醒后约 0.5 s 内设备才重建完成；显示器上电时日志里还会出现两轮 `Deinit → Init` 抖动。
- 客户端/服务端状态不同步：`IO_Sender.cpp: Failed to send io sender message id 5, need to resynch` 反复出现，此时只能靠 stop→start 重建。

**新 App 必须按 UID 重绑 + 监听设备增删 + 失败退避重试。这是本项目的核心需求，不是可选项。**

---

## 2. 环境事实

| 项 | 值 |
|---|---|
| 机型 | MacBook Air M3，`Mac15,12`，16 GB |
| 系统 | macOS 14.6（23G80） |
| 使用方式 | **合盖（clamshell）+ 外接 4K 显示器 + 交流电** |
| 显示器 | COOCAA 27 4K（vendor 9747 / model 9984 / serial 25616） |
| 连接 | HDMI 链路（USB-C 转接），4K60，RGB Full |
| 音频端点 | `COOCAA 27 4K`，transport = HDMI，2ch，48 kHz |
| 音频 UID | `26130027-0000-0000-2522-010380000078` |
| BetterDisplay | Pro，`tagID=118`，UUID `0508C91A-309B-4C36-8849-C814EF5F07C2` |
| 已装驱动 | `BlackHole2ch.driver`、`MAXHUBAudio.driver`、`SpeakerAmpDrv.driver`（均在 `/Library/Audio/Plug-Ins/HAL/`） |

### 显示器能力（实测）

| 功能 | 结论 |
|---|---|
| DDC 音量 VCP `0x62` | ✅ **可用**。写 0 会真的静音，写 100 恢复；OSD 数字同步变化 |
| DDC 亮度 VCP `0x10` | ✅ 可用 |
| DDC 读回（`get --ddc`） | ❌ **完全失效**，只能写。状态必须自己记 |
| 情景模式 | 标准 / RTS / FPS / 文本 / 游戏 / 电影；**只有「标准」能调亮度和对比度**，其余为锁定预设，会覆盖 DDC 的 RGB 增益 |
| RGB 增益 | 50/50/50 可消除偏黄（DDC `0x14/0x16/0x18`） |

### 刻度换算（实测，非线性，勿用纯公式）

**亮度**（BetterDisplay 的 `--brightness` 值 b）：

```
b ≤ 0.5        → 纯软件调光，DDC 不动
b > 0.5        → hardwareBrightness = (b - 0.5) × 2
BetterDisplay 写出的 DDC 值 ≈ hardwareBrightness × 128
显示器 OSD 显示的数字 ≈ DDC × 2   （即真实范围 0–200，但进度条只画到 100）
```

实测点：`h=0.200 → OSD 53`、`h=0.274 → OSD 65`、`h=0.400 → OSD 103`、`raw DDC 60 → OSD 120`。
当前固定值：`combinedBrightness=0.637` / `hardwareBrightness=0.274` → OSD 65。

**音量**：DDC 0–100 线性，0 = 静音，100 = 最大，OSD 数字一致。

---

## 3. 目标（要做什么）

### P0 必须

1. **虚拟输出设备**：出现在系统声音列表里，可设为默认输出，转发到物理输出设备（当前是 HDMI 端点）。
2. **音量控制**：
   - 系统音量键（F10/F11/F12 那一组）可调
   - 系统 OSD / 控制中心能显示真实音量（原生 `kAudioDevicePropertyVolumeScalar` 实现最好）
   - 菜单栏图标显示百分比 + 点击出滑块
   - 静音键可用
3. **音频处理**（这是保留 SpeakerAmp 的核心理由）：
   - 10 段图形 EQ（20 Hz – 20 kHz，±12 dB），带预设，可开关
   - **空间感 / 3D 效果**：立体声展宽 + 交叉馈送（crossfeed）+ 短早期反射；强度可调，可 A/B 对比
   - 限幅器（防止调 EQ 后削波），阈值可调
4. **唤醒鲁棒性**：
   - 监听 `kAudioHardwarePropertyDevices`，按 **UID** 重绑，**绝不按 AudioObjectID/devId**
   - 物理设备消失时静默保持（不报错、不崩溃），重新出现后 1 s 内自动恢复出声
   - `StartIO` 失败时按退避重试（如 0.2 / 0.5 / 1 / 2 s，总共 ≥ 10 s）
   - 处理"设备重建两次"的抖动，不要被中途的 `Deactivate` 打乱
5. **无爆音**：任何启动/停止/切换设备都用 10–20 ms 淡入淡出
6. **设置持久化 + 开机自启**

### P1 应该

- 输出设备选择器（在虚拟设备内部切到 HDMI / 内置扬声器 / 其他）
- 简单电平表（VU）
- 菜单栏可显示/隐藏、可选图标样式
- EQ 预设导入导出（JSON）
- 采样率自动跟随物理设备变化

### P2 可选

- 频谱显示
- 每设备独立配置（记忆不同输出的 EQ/音量）
- 通过 DDC 同步调节显示器硬件音量（与软件增益二选一，见 §5 决策）
- 快捷键自定义

---

## 4. 非目标

- 不做 per-app 音量/路由（不需要）
- 不做录音、直播、虚拟麦克风
- 不做音乐库播放器
- 不做大幅增益（用户明确说"增益那些功能没怎么用到"，保留限幅即可，最大 +6~9 dB 够了）
- 不需要 App Store 上架 / 公证（自用）

---

## 5. 待决策（开工前先定）

| # | 问题 | 建议 |
|---|---|---|
| D1 | 音量由**软件增益**控制，还是**DDC**控制，还是两者分层？ | 软件增益做日常音量（平滑、有 OSD、可到 0），DDC 固定在 80–100 当"功放基准"。**不要两个都动**，会互相打架 |
| D2 | 虚拟设备用 **自写 HAL 插件**，还是 **BlackHole + 用户态 DSP**？ | 见 §6。想要原生音量键 + 系统 OSD，选 HAL 插件（A） |
| D3 | 空间效果要做到多接近 SpeakerAmp？ | 先做"展宽 + crossfeed + 早期反射"三件套，再用 A/B 盲听调参数。不做 HRTF 卷积（成本高、收益不确定） |
| D4 | 与 BetterDisplay 的边界 | BetterDisplay 保留：亮度、分辨率、DDC 音量（可选）。**音量键只能有一个主人**。若新 App 接管音量键，必须关掉 BetterDisplay 的"监听原生音量键" |
| D5 | 命名 / Bundle ID | 自定，例如 `com.jerry.soundbridge` |
| D6 | 用户当前 SpeakerAmp 的 EQ 预设 | 需要用户导出/截图，作为调音参考 |

---

## 6. 架构对比

### 方案 A：自写 AudioServerPlugin（HAL 驱动）+ 宿主 App ★推荐

```
App（UI/菜单栏/配置）
  ↕ Mach / 共享内存
MyDriver.driver（/Library/Audio/Plug-Ins/HAL/）
  → 虚拟输出设备（实现 Volume/Mute 属性）
  → DSP：EQ → 空间 → 限幅 → 增益
  → 写入物理设备（按 UID 解析）
```

优点：
- **原生音量**：只要插件实现 `kAudioDevicePropertyVolumeScalar`/`VolumeScalar` 的 set/get，系统音量键、OSD、控制中心**全部自动可用**，不需要 Accessibility、不需要拦截媒体键
- 延迟最低（可在同一个 IO 线程里完成转发）
- 唤醒重绑在驱动层做，最可靠
- 与 SpeakerAmp 架构相同（它就是这么干的），效果上限最高

缺点：
- C++ 写 HAL 插件，调试靠 `coreaudiod` 日志，学习曲线陡
- 安装要写 `/Library/Audio/Plug-Ins/HAL/` + `sudo killall coreaudiod`
- 插件崩溃会拖垮 coreaudiod（要极其小心内存/线程）

### 方案 B：BlackHole + 用户态 DSP App

```
App 读 BlackHole 输出 → DSP → 写 HDMI 设备
```

优点：上手快，纯 Swift/CoreAudio，不动系统目录（BlackHole 已装好）
缺点：
- 需要 **麦克风 TCC 权限**（读虚拟输入）
- 音量键要自己用 `CGEventTap` 拦（需要**辅助功能**权限，且系统升级易失效）
- 多一层用户态缓冲，延迟 +3~10 ms
- App 崩溃 = 没声音
- 系统音量滑块仍然不可控（还是虚拟设备那套问题）

### 方案 C：A 的简化版 —— 插件只做设备，DSP 放 App

不推荐：跨进程传音频反而更复杂。

**结论：优先 A。** 若时间成本不可接受，退化到 B，但要接受"音量键靠拦截"。

---

## 7. 关键技术要求

### 设备与重绑

- 只用 UID 定位设备：`kAudioDevicePropertyDeviceUID`
- 监听三类通知：
  - `kAudioHardwarePropertyDevices`（增删）
  - `kAudioDevicePropertyDeviceIsAlive`
  - `kAudioHardwarePropertyDefaultOutputDevice`（用户手动切换）
- 物理设备未就绪时：进入"静音待命"状态，保持 IO 运行（避免客户端 stop/start 风暴），输出静音
- 重绑流程：`StopIO(旧)` → 重新 `GetDeviceByUID` → `StartIO(新)`，全程淡入淡出

### 音频

- 内部 float32，交错/非交错皆可，48 kHz 自适应
- 缓冲：128–512 frames；总延迟目标 < 20 ms
- 所有 DSP 用无锁环形缓冲 + 参数原子写入，**不要在实时线程里 malloc / 加锁 / 打日志**
- 参数变化（音量、EQ 开关）用一阶平滑，避免 zipper noise
- 限幅器：前瞻 1–2 ms 的 look-ahead limiter 即可

### DSP 细节建议

- EQ：10 段 peaking（或 5 段 + 高低架），Q 可调
- 空间感：
  - 立体声展宽：mid/side，side gain 0–6 dB
  - crossfeed：把对侧信号延迟 0.1–0.3 ms、衰减 −6~−12 dB 混入
  - 早期反射：2–3 个 5–20 ms 的延迟抽头，低通后混入 −12~−18 dB
  - 建议提供 `width` / `depth` 两个 0–100 的滑块，而不是一堆参数
- 预设：`Off / 标准 / 电影 / 音乐 / 夜间（压缩）`

### 权限与安装

- HAL 插件：写入 `/Library/Audio/Plug-Ins/HAL/<Name>.driver`（需要管理员权限）
- 安装后 `sudo killall coreaudiod`（音频会中断 2–3 秒）
- 方案 B 才需要：麦克风 TCC + 辅助功能
- 自用可 ad-hoc 签名；重启后若系统提示"无法验证"，需在隐私设置里允许

### 性能

- CPU < 2%（单核，48 kHz / 2ch）
- 内存 < 150 MB
- 唤醒后 1 s 内恢复出声

---

## 8. 验收标准

必须逐条验证：

1. **合盖睡眠 → 唤醒，连续 10 次，每次都自动有声音，无需任何手动操作**
2. 音量键可调，系统 OSD 显示的百分比与菜单栏一致
3. 静音键有效，再按恢复
4. 播放中切换输出设备（HDMI ↔ 内置扬声器），无爆音、无卡顿
5. 显示器断电/拔线 → 恢复后自动出声
6. EQ 和空间效果开关时无明显音量跳变
7. 与 SpeakerAmp A/B 盲听：空间感"接近"，不是"完全一致"也算通过
8. 重启 Mac 后设置全部保留、自动启动
9. 连续播放 2 小时无 dropout、无内存增长
10. 卸载后系统音频恢复正常（不留后患）

---

## 9. 已排除的方案（别再走一遍）

| 方案 | 为什么不行 |
|---|---|
| 保留 SpeakerAmp + 唤醒重启兜底 | 能用，但每次唤醒静音 2–3 s，且是治标 |
| 纯 DDC 音量 + HDMI 直连 | 稳定，但**丢失 EQ/空间感**，用户不接受 |
| eqMac | 同样的唤醒 bug（issue #1023 / #834 / #537），且新版本闭源 |
| Background Music | 停更 4 年，Apple Silicon 跑不起来 |
| Soundflower | 已死 |
| 换 USB DAC | 能彻底解决唤醒问题，但没有 EQ/空间感，且用户不想加设备 |

---

## 10. 参考资料

- SpeakerAmp 的架构可参考其驱动：`/Library/Audio/Plug-Ins/HAL/SpeakerAmpDrv.driver`（version 2.2）
- Apple 官方示例：`AudioServerPlugIn` / `NullAudio` 驱动模板
- BlackHole 源码（GPL-3.0）：可直接参考它的 HAL 插件实现
- BetterDisplay CLI：`betterdisplaycli get|set --tagID=118 --volume|--brightness|--ddc --vcp=...`

### 常用命令

```bash
# 列出音频设备（UID / ID / transport）
/private/var/folders/kt/9jcfj7jd19l2wnbwny4pk4n80000gn/T/opencode/audiodevs

# 当前默认输出
system_profiler SPAudioDataType | grep -B3 -A3 'Default Output'

# DDC 音量
betterdisplaycli set --tagID=118 --ddc --vcp=audioSpeakerVolume --value=50

# DDC 亮度
betterdisplaycli set --tagID=118 --ddc --vcp=luminance --value=35

# 重启音频服务（装完插件后必须）
sudo killall coreaudiod

# 看唤醒时设备重建
log show --last 10m --predicate 'process == "coreaudiod"' | grep HALS_Device
```
