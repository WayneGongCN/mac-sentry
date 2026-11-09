import AVFoundation
import SwiftUI

struct SentryView: View {
    @ObservedObject var sentry: Sentry
    let wallpaper: WallpaperPlayback

    var body: some View {
        LockScreenWallpaper(wallpaper: wallpaper,
                            camera: sentry.isAlrming && sentry.cameraIssue == nil && sentry.capture.session.isRunning
                                ? sentry.capture.session : nil)
    }
}

struct LockScreenWallpaper: View {
    @ObservedObject var wallpaper: WallpaperPlayback
    var camera: AVCaptureSession?
    var fallback: NSImage?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let box = WallpaperLayout.camera(in: size)
            Color.clear
                .overlay {
                    if let frame = wallpaper.frame ?? fallback {
                        Image(nsImage: frame)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .clipped()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let camera {
                        CameraPreviewView(captureSession: camera)
                            .background(.black)
                            .frame(width: box.width, height: box.height)
                            .clipShape(RoundedRectangle(cornerRadius: WallpaperLayout.cornerRadius))
                            .padding(box.minY)
                    }
                }
        }
        .allowsHitTesting(false)
    }
}

struct PreviewUnlockLabel: View {
    var body: some View {
        Text("原生解锁界面示意")
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.bottom, 32)
    }
}
