import AppKit
import Foundation
import ServiceManagement

// 测试 / 脚本用：直接开关 LaunchAgent 登录项
if let index = CommandLine.arguments.firstIndex(of: "--login"),
   index + 1 < CommandLine.arguments.count {
    let value = CommandLine.arguments[index + 1]
    do {
        switch value {
        case "on":
            try LaunchAtLogin.enable()
        case "off":
            LaunchAtLogin.disable()
        case "status":
            break
        default:
            FileHandle.standardError.write(Data("usage: --login on|off|status\n".utf8))
            exit(2)
        }
        print(LaunchAtLogin.isEnabled ? "enabled" : "disabled")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("login item failed: \(error)\n".utf8))
        exit(1)
    }
}

// 兼容旧版本：卸载器先注销 SMAppService 登录项（旧版注册方式），
// 再删除 App。新版登录项是 LaunchAgent，卸载器直接删 plist。
if CommandLine.arguments.contains("--unregister-login") {
    if #available(macOS 13.0, *) {
        do {
            try SMAppService.mainApp.unregister()
            FileHandle.standardError.write(Data("unregister-login: ok\n".utf8))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("unregister-login failed: \(error)\n".utf8))
            exit(1)
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
