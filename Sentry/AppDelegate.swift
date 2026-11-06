import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 启动与窗口无关的锁屏观察和录像清理任务，喵~
    func applicationDidFinishLaunching(_ notification: Notification) { Sentry.shared.launch() }
    // 保持菜单栏守卫常驻，关闭设置窗口不影响后续锁屏，喵~
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    // 给文件输出留出收尾时间后再退出进程，喵~
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Sentry.shared.shutdown()
        Sentry.shared.capture.waitForFinished { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
