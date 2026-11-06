import SwiftUI

struct App: SwiftUI.App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate
    @StateObject var sentry = Sentry.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Mac 哨兵", id: "settings") { ContentView() }
            .defaultSize(width: 700, height: 600)
            .windowResizability(.contentMinSize)
        MenuBarExtra("Mac 哨兵", systemImage: sentry.isAlrming ? "light.beacon.max.fill" : "eye") {
            Text(sentry.isMonitoring ? "正在守卫" : "等待锁屏")
            Toggle("锁屏后自动守卫", isOn: $sentry.automaticEnabled)
            Button("设置与效果预览") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
            Button("打开录像目录") { openRecordings() }
            Divider()
            Button("退出 Mac 哨兵") { NSApp.terminate(nil) }
        }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

// 打开本应用独立容器内的录像目录，喵~
func openRecordings() {
    do {
        try FileManager.default.createDirectory(at: videoClipDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(videoClipDir)
    } catch { NSApp.presentError(error) }
}
