# 新 Session 开场提示词（直接复制粘贴）

---

我要做一个 macOS 菜单栏音频 App，用来替换 SpeakerAmp。

完整需求在 `/Users/jerry/Syncthing/repos/jerry/SoundBridge/SPEC.md`，**请先完整读一遍**，里面有环境事实、已定位的唤醒 bug 根因、DDC 实测数据、架构对比和验收标准。

核心诉求四句话：

1. 虚拟输出设备转发到显示器的 HDMI 端点（当前是 `COOCAA 27 4K`）。
2. 唤醒**绝不能再丢声音**——必须按 UID 重绑，不能按 AudioObjectID。
3. 保留 10 段 EQ + 空间感（这是我不想用 HDMI 直连的唯一原因）。
4. 音量键、系统 OSD、菜单栏滑块都要能用。

我倾向 SPEC 里的**方案 A（自写 AudioServerPlugin HAL 驱动）**，因为只有这样才能让系统音量键和 OSD 原生可用，不用拦截媒体键、不用辅助功能权限。

开始前先跟我确认这几件事：

- 先给我一个最小可运行版本（能出声、能调音量、能扛唤醒），再逐步加 EQ 和空间效果
- 每一步都在本机实测，我要亲自验证"合盖睡眠 → 唤醒"这条
- 装完插件要 `sudo killall coreaudiod` 的地方，先告诉我再执行

我的现有配置：

- MacBook Air M3 / macOS 14.6 / 合盖 + 4K 显示器 + 电源
- SpeakerAmp 7.0 还装着（作为回退，别卸载）
- BetterDisplay Pro 在跑（负责亮度和分辨率，音量键可以交给新 App）
- BlackHole 2ch 已装

先读 SPEC，然后告诉我你的实施顺序和第一个要动手的部分。
