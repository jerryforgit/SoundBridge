# PKG 安装 / 卸载

这是给自用/分发的常规方式：安装和卸载分开两个 PKG，都通过 macOS Installer 获取管理员权限。

## 构建

```bash
cd /Users/jerry/Syncthing/repos/jerry/SoundBridge
./packaging/build.sh
```

产物：

```
packaging/build/SoundBridge.pkg             # App + HAL 插件
packaging/build/Uninstall.SoundBridge.pkg   # 彻底卸载
```

App 和 HAL 插件都是 universal（`arm64 + x86_64`），最低 macOS 13.0。

## 安装

双击 `SoundBridge.pkg`，或：

```bash
sudo installer -pkg "packaging/build/SoundBridge.pkg" -target /
```

它会：

- 安装 `/Applications/SoundBridge.app`
- 安装 `/Library/Audio/Plug-Ins/HAL/SoundBridge.driver`
- `chown root:wheel` / `chmod 755`
- `killall coreaudiod`（音频中断 2–3 秒）
- `killall Dock` 刷新 Launchpad

安装后打开 App，按需在菜单里勾选“登录时启动”。

## 卸载

双击 `Uninstall.SoundBridge.pkg`，或：

```bash
sudo installer -pkg "packaging/build/Uninstall.SoundBridge.pkg" -target /
```

它会：

- 退出 App
- 注销 `SMAppService` 登录项（安装在 `登录时打开` 列表里）
- 删除 HAL 插件
- 删除 `/Applications/SoundBridge.app`
- 删除 `/tmp/soundbridge_ring_v1`
- 删除 `~/Library/Logs/SoundBridge` 和 `com.jerry.soundbridge.plist`
- 重启 `coreaudiod` 和 Dock

SpeakerAmp / BlackHole / MAXHUB 不会被修改。

## 签名 / Gatekeeper

App 和插件使用 ad-hoc 签名，PKG 未签名，自用场景足够。若双击被 Gatekeeper 拦截：

- 右键 → 打开，或
- 使用上面的 `sudo installer` 命令

## 开发用脚本

`scripts/install.sh` / `scripts/uninstall.sh` 仍然保留，只操作插件，不碰 App，适合开发调试。
