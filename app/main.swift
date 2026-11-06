import AppKit
import ServiceManagement

// 卸载器用：先注销登录项，再删除 App
if CommandLine.arguments.contains("--unregister-login") {
    if #available(macOS 13.0, *) {
        try? SMAppService.mainApp.unregister()
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
