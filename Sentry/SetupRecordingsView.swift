import AppKit
import AVFoundation
import SwiftUI

final class PreviewVideoView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    // 预览图层随布局调整尺寸，并完整保留摄像头画面比例，喵~
    override func layout() {
        super.layout()
        preview.frame = bounds
    }
}

struct CameraPreviewView: NSViewRepresentable {
    let captureSession: AVCaptureSession
    // 将预览图层接入现有采集会话，不创建额外摄像头会话，喵~
    func makeNSView(context: Context) -> PreviewVideoView {
        let view = PreviewVideoView()
        view.wantsLayer = true
        view.preview.session = captureSession
        view.preview.videoGravity = .resizeAspect
        view.layer?.addSublayer(view.preview)
        return view
    }
    // 会话更新时同步图层引用，喵~
    func updateNSView(_ view: PreviewVideoView, context: Context) {
        if view.preview.session !== captureSession { view.preview.session = captureSession }
    }
    // 退出预览时解除图层与会话的连接，喵~
    static func dismantleNSView(_ view: PreviewVideoView, coordinator: ()) { view.preview.session = nil }
}

enum PreviewMode: String, Identifiable { case guarding, warning; var id: String { rawValue } }

final class PreviewCamera: ObservableObject {
    let pipeline = CapturePipeline()
    @Published var issue: String?
    // 预览只发布采集故障，不启用任何录像事件，喵~
    init() { pipeline.onCameraIssue = { [weak self] text in self?.issue = text } }
}

struct DesktopPreview: View {
    let mode: PreviewMode
    var configuration = SentryConfigurationManager.shared.cfg
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = PreviewCamera()
    @ObservedObject private var sentry = Sentry.shared
    @State private var media = SentryMedia()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("界面预览 · 底部为系统解锁区").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            ZStack(alignment: .bottom) {
                Color(white: 0.13)
                Text("此区域在真实锁屏时完全透明，显示 macOS 原生解锁界面")
                    .font(.callout).foregroundStyle(.secondary).padding(.bottom, 80)
                SentryHUD(warning: mode == .warning, session: camera.pipeline.session,
                          issue: camera.issue, isPreview: true, media: media)
            }
        }
        .frame(width: 1000, height: 720)
        .onAppear {
            media = SentryMediaStore.shared.load(configuration)
            if mode == .warning && media.alarmImage == nil { camera.pipeline.start(detectionEnabled: false) }
        }
        .onDisappear { camera.pipeline.stop() }
        .onReceive(sentry.$isMonitoring) { if $0 { dismiss() } }
    }
}
