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
                        Text("本地人脸检测 · 事件录像").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(sentry.isMonitoring ? "守卫中" : "待命").foregroundStyle(.cyan)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("锁屏后自动守卫", isOn: $sentry.automaticEnabled)
                        Toggle("检测中央区域人脸", isOn: $settings.cfg.sentryTriggersHumanEnabled)
                        Toggle("保存人脸事件录像", isOn: $settings.cfg.sentryRecordingEnabled)
                        Text("锁屏后自动开始。合格人脸消失 10 秒后恢复守卫；录像保留 24 小时或最多 5GB。")
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
                    Button("预览守卫画面") { preview = .guarding }
                    Button("预览告警画面") { preview = .warning }
                    Button("画面、声音与通知设置") { notificationOptions = true }
                    Spacer()
                }
                Text("预览不录像、不播放告警音；未设置告警图片时会使用摄像头。主屏底部为系统解锁区，扩展屏铺满。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("其他可选触发") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("合盖触发", isOn: $settings.cfg.sentryTriggersLidEnabled)
                        Toggle("断网触发", isOn: $settings.cfg.sentryTriggersInternetEnabled)
                        Toggle("拔电源触发", isOn: $settings.cfg.sentryTriggersPowerEnabled)
                    }.padding(.top, 12)
                }
                Text("基于 Lakr233/Sentry 1.3.13 · 定制版 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0") · 人脸检测包含机主，不区分身份或活体")
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
