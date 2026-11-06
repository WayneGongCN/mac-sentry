import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var sentry = Sentry.shared
    @StateObject private var settings = SentryConfigurationManager.shared
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var preview: PreviewMode?
    @State private var notificationOptions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image(systemName: "eye.circle.fill").font(.system(size: 48)).foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mac 哨兵").font(.largeTitle.bold())
                        Text("本地人形检测 · 事件录像").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(sentry.isMonitoring ? "守卫中" : "待命").foregroundStyle(.cyan)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("锁屏后自动守卫", isOn: $sentry.automaticEnabled)
                        Toggle("检测人员靠近", isOn: $settings.cfg.sentryTriggersHumanEnabled)
                        Toggle("保存人形事件录像", isOn: $settings.cfg.sentryRecordingEnabled)
                        Text("锁屏后自动开始。人员离开 10 秒后恢复守卫；录像保留 24 小时或最多 5GB。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("接电时持续亮屏守卫，电池供电遵循系统休眠。设置变更从下一次锁屏生效。")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("摄像头与运行状态") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(cameraStatus == .authorized ? "摄像头已授权" : "需要摄像头权限", systemImage: "camera")
                        if cameraStatus != .authorized {
                            Button(cameraStatus == .notDetermined ? "授权摄像头" : "打开摄像头隐私设置", action: authorizeCamera)
                        }
                        Text(sentry.lastEvent).font(.callout)
                        if let issue = sentry.cameraIssue { Text(issue).foregroundStyle(.orange) }
                        Text(sentry.recordingState.label).foregroundStyle(.secondary)
                        Button("打开录像目录", action: openRecordings)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                HStack {
                    Button("预览机械眼与扫描") { preview = .guarding }
                    Button("预览实时画面与警灯") { preview = .warning }
                    Spacer()
                }
                Text("预览只展示界面，不保存录像。告警预览会使用摄像头；底部灰色区域代表系统解锁区。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("其他可选触发与通知") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("合盖触发", isOn: $settings.cfg.sentryTriggersLidEnabled)
                        Toggle("断网触发", isOn: $settings.cfg.sentryTriggersInternetEnabled)
                        Toggle("拔电源触发", isOn: $settings.cfg.sentryTriggersPowerEnabled)
                        HStack {
                            Button("声音与通知设置") { notificationOptions = true }
                        }
                    }.padding(.top, 12)
                }
                Text("基于 Lakr233/Sentry 1.3.13 · 定制版 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1") · 检测任何人形，包括机主")
                    .font(.caption).foregroundStyle(.tertiary)
            }.padding(28)
        }
        .frame(minWidth: 660, minHeight: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        }
        .sheet(item: $preview) { mode in DesktopPreview(mode: mode) }
        .sheet(isPresented: $notificationOptions) { SetupNotificationsView() }
    }

    // 仅在桌面由用户点击时申请摄像头权限，喵~
    private func authorizeCamera() {
        if cameraStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in
                DispatchQueue.main.async { cameraStatus = AVCaptureDevice.authorizationStatus(for: .video) }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
        }
    }
}
