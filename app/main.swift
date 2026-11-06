import AppKit
import Foundation
import ServiceManagement

// 测试 / 脚本用：直接开关 SMAppService 登录项
if let index = CommandLine.arguments.firstIndex(of: "--login"),
   index + 1 < CommandLine.arguments.count {
    let value = CommandLine.arguments[index + 1]
    do {
        switch value {
        case "on":
            try LoginItem.enable()
        case "off":
            try LoginItem.disable()
        case "status":
            break
        default:
            FileHandle.standardError.write(Data("usage: --login on|off|status\n".utf8))
            exit(2)
        }
        print(LoginItem.isEnabled ? "enabled" : "disabled")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("login item failed: \(error)\n".utf8))
        exit(1)
    }
}

// 卸载器 / 安装器用：注销当前 App 的登录项。
// 必须在删除或替换 App 包之前执行，这样注册用的 cdhash 仍然匹配。
if CommandLine.arguments.contains("--unregister-login") {
    do {
        try LoginItem.disable()
        FileHandle.standardError.write(Data("unregister-login: ok\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("unregister-login failed: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
