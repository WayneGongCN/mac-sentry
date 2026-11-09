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
    @Published private(set) var ready = false

    // 首帧到达后才显示画中画，采集中断时隐藏，喵~
    init() {
        pipeline.onCameraIssue = { [weak self] text in
            self?.issue = text
            self?.ready = false
        }
        pipeline.onDetection = { [weak self] _, _ in
            guard let self, !self.ready else { return }
            self.issue = nil
            self.ready = true
        }
    }
}

struct DesktopPreview: View {
    let mode: PreviewMode
    var configuration = SentryConfigurationManager.shared.cfg
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = PreviewCamera()
    @StateObject private var wallpaper = WallpaperPlayback()
    @State private var fallback: NSImage?
    @ObservedObject private var sentry = Sentry.shared
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(mode == .warning ? "告警画面预览" : "守卫画面预览").font(.headline)
                if let issue = camera.issue {
                    Text(issue).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            ZStack(alignment: .bottom) {
                Color(white: 0.13)
                LockScreenWallpaper(wallpaper: wallpaper, camera: camera.ready ? camera.pipeline.session : nil,
                                    fallback: fallback)
                PreviewUnlockLabel()
            }
        }
        .frame(width: 1000, height: 720)
        .onAppear {
            fallback = NativeWallpaper.previewFallback()
            let media = SentryMediaStore.shared.load(configuration)
            wallpaper.show(mode == .warning ? media.alarmImage : media.guardingImage)
            if mode == .warning { camera.pipeline.start(detectionEnabled: false) }
        }
        .onDisappear {
            wallpaper.show(nil)
            camera.pipeline.stop()
        }
        .onReceive(sentry.$isMonitoring) { if $0 { dismiss() } }
    }
}
