import AVFoundation
import SwiftUI

struct SentryView: View {
    @ObservedObject var sentry: Sentry
    var reservesUnlockArea = true
    var body: some View {
        SentryHUD(warning: sentry.isAlrming, session: sentry.capture.session,
                  recording: sentry.recordingState, issue: sentry.cameraIssue, reason: sentry.alarmReason,
                  media: sentry.media, unlockAreaFraction: reservesUnlockArea ? 0.30 : 0)
    }
}

struct SentryHUD: View {
    var warning: Bool
    var session: AVCaptureSession
    var recording: RecordingState = .idle
    var issue: String?
    var reason = "检测到人脸"
    var isPreview = false
    var previewCamera = true
    var media = SentryMedia()
    var unlockAreaFraction: CGFloat = 0.30
    private let cyan = Color(red: 0.30, green: 0.90, blue: 0.95)

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { clock in
                    let time = clock.date.timeIntervalSinceReferenceDate
                    ZStack {
                        Color(red: 0.018, green: 0.035, blue: 0.055)
                        TechnicalGrid(time: time, color: warning ? .red : cyan)
                        VStack(spacing: 10) {
                            header(date: clock.date)
                            if warning { warningContent(time: time) }
                            else { guardingContent(time: time) }
                            ForEach(media.issues, id: \.self) { message in
                                Text(message).font(.caption).foregroundStyle(.orange)
                            }
                            footer
                        }.padding(.horizontal, max(24, geometry.size.width * 0.055)).padding(.vertical, 20)
                    }
                    .clipped()
                }
                .frame(height: max(0, geometry.size.height * (1 - unlockAreaFraction)))
                Color.clear.frame(height: max(0, geometry.size.height * unlockAreaFraction))
            }
        }
        .preferredColorScheme(.dark)
        .allowsHitTesting(false)
    }

    // 绘制状态标识与时间，避免把实现细节混入面向访客的界面，喵~
    private func header(date: Date) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.circle").font(.title2)
            Text("MAC 哨兵").font(.system(size: 16, weight: .semibold, design: .monospaced)).tracking(4)
            Spacer()
            Circle().fill(warning ? Color.red : cyan).frame(width: 6, height: 6)
            Text(warning ? "警告" : "守卫中").font(.system(size: 12, weight: .medium)).tracking(2)
            Text(date, style: .time).font(.system(size: 13, design: .monospaced)).padding(.leading, 14)
        }.foregroundStyle(warning ? .white : cyan.opacity(0.85))
    }

    // 按屏幕方向排列机械眼或自定义图片，扫描光带保持在卡片范围内，喵~
    private func guardingContent(time: Double) -> some View {
        GeometryReader { space in
            let portrait = space.size.height > space.size.width
            let layout = portrait ? AnyLayout(VStackLayout(alignment: .leading, spacing: 32))
                : AnyLayout(HStackLayout(spacing: 32))
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(LinearGradient(colors: [Color(red: 0.03, green: 0.09, blue: 0.13), .black.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 28).stroke(cyan.opacity(0.2), lineWidth: 1)
                layout {
                    Group {
                        if let image = media.guardingImage { Image(nsImage: image).resizable().scaledToFit() }
                        else { MechanicalEye(time: time) }
                    }
                    .frame(width: max(0, min(space.size.height * (portrait ? 0.60 : 0.86), space.size.width * (portrait ? 0.70 : 0.40))),
                           height: max(0, min(space.size.height * (portrait ? 0.60 : 0.86), space.size.width * (portrait ? 0.70 : 0.40))))
                    VStack(alignment: .leading, spacing: 18) {
                        Text("哨兵模式已开启").font(.system(size: max(1, min(38, space.size.width * 0.035)), weight: .semibold))
                        Text(issue == nil ? "正在监测人脸" : "监测暂不可用")
                            .font(.system(size: 18)).foregroundStyle(issue == nil ? cyan : .orange)
                        Rectangle().fill(cyan.opacity(0.35)).frame(width: 64, height: 2)
                        Text(issue ?? "此电脑正在受到保护\n请勿触碰或移动设备")
                            .font(.system(size: 14)).lineSpacing(7).foregroundStyle(.white.opacity(0.5))
                        Label("检测到人脸后触发警告", systemImage: "viewfinder")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(cyan.opacity(0.7))
                    }
                    if !portrait { Spacer(minLength: 0) }
                }.padding(24)
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, cyan.opacity(0.10), cyan.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(height: 22)
                    .position(x: space.size.width / 2, y: 12 + (space.size.height - 24) * (0.5 + 0.5 * sin(time * .pi / 3)))
                    .blendMode(.screen)
            }.clipShape(RoundedRectangle(cornerRadius: 28))
        }
    }

    // 告警显示自定义图片或完整实时画面，展示内容不写入摄像头录像，喵~
    private func warningContent(time: Double) -> some View {
        VStack(spacing: 10) {
            RotatingBeacon(time: time).frame(height: 48)
            ZStack(alignment: .topLeading) {
                Color.black
                if let image = media.alarmImage {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if previewCamera { CameraPreviewView(captureSession: session) }
                else {
                    VStack(spacing: 12) {
                        Image(systemName: "video.fill").font(.system(size: 40))
                        Text("实时摄像头画面").font(.headline)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.white.opacity(0.35))
                }
                HStack(spacing: 8) {
                    Circle().fill(recording == .recording ? Color.red : .orange).frame(width: 7, height: 7)
                    Text(isPreview ? "效果预览 · 未保存录像" : recording.label)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }.padding(10).background(.black.opacity(0.65)).clipShape(Capsule()).padding(10)
                if let issue {
                    Text(issue).font(.callout).padding(10).background(.black.opacity(0.8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.red.opacity(0.7), lineWidth: 1))
            Text(reason).font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            Text("请立即离开，请勿触碰此电脑。")
                .font(.system(size: 26, weight: .bold)).foregroundStyle(.white).minimumScaleFactor(0.6).lineLimit(1)
        }
    }

    private var footer: some View {
        HStack {
            Label(warning ? "告警已触发" : "本地监测", systemImage: warning ? "exclamationmark.shield" : "shield.lefthalf.filled")
            Spacer()
            if unlockAreaFraction > 0 { Text("使用下方系统界面解锁") }
        }.font(.system(size: 11)).tracking(1).foregroundStyle(.white.opacity(0.35))
    }
}

struct TechnicalGrid: View {
    var time: Double
    var color: Color
    var body: some View {
        Canvas { context, size in
            var grid = Path()
            for x in stride(from: 0.0, through: size.width, by: 48) {
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0.0, through: size.height, by: 48) {
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(color.opacity(0.055)), lineWidth: 0.5)
            for index in 0..<18 {
                let x = (Double(index * 137) + time * 9).truncatingRemainder(dividingBy: max(size.width, 1))
                let y = Double(index * 79).truncatingRemainder(dividingBy: max(size.height, 1))
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(color.opacity(0.3)))
            }
        }
    }
}

struct MechanicalEye: View {
    var time: Double
    private let cyan = Color(red: 0.25, green: 0.90, blue: 0.98)
    var body: some View {
        GeometryReader { space in
            let d = max(0, min(space.size.width, space.size.height))
            ZStack {
                Circle().fill(cyan.opacity(0.07)).blur(radius: 20)
                Circle().stroke(cyan.opacity(0.12), lineWidth: 1).padding(d * 0.02)
                Circle().trim(from: 0.03, to: 0.70).stroke(cyan.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [2, 9]))
                    .rotationEffect(.degrees(time * 12)).padding(d * 0.06)
                Circle().fill(RadialGradient(colors: [.black, cyan.opacity(0.5), .black], center: .center, startRadius: d * 0.10, endRadius: d * 0.39))
                    .overlay(Circle().stroke(cyan.opacity(0.65), lineWidth: 1)).padding(d * 0.13)
                ForEach(0..<64, id: \.self) { index in
                    Capsule().fill(cyan.opacity(index % 4 == 0 ? 0.8 : 0.3))
                        .frame(width: index % 4 == 0 ? 2 : 1, height: d * 0.16)
                        .offset(y: -d * 0.25).rotationEffect(.degrees(Double(index) * 360 / 64 + time * 5))
                }
                Circle().fill(.black).frame(width: d * 0.28, height: d * 0.28)
                    .overlay(Circle().stroke(cyan.opacity(0.9), lineWidth: 2))
                    .shadow(color: cyan.opacity(0.5), radius: 12)
                Circle().fill(cyan.opacity(0.65)).frame(width: d * 0.035, height: d * 0.035).offset(x: d * 0.055, y: -d * 0.055)
                Image(systemName: "plus").font(.system(size: d * 0.075, weight: .ultraLight)).foregroundStyle(cyan.opacity(0.55))
            }.frame(width: d, height: d)
        }
    }
}

struct RotatingBeacon: View {
    var time: Double
    var body: some View {
        HStack(spacing: 6) {
            lens(.red, phase: time * 2 * .pi)
            Text("WARNING").font(.system(size: 11, weight: .heavy, design: .monospaced)).tracking(3).padding(.horizontal, 10)
            lens(.blue, phase: time * 2 * .pi + .pi)
        }
        .padding(6).background(.black.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.15)))
        .frame(maxWidth: 400)
    }

    // 用旋转光束和玻璃高光模拟每秒一圈的警灯，喵~
    private func lens(_ color: Color, phase: Double) -> some View {
        GeometryReader { space in
            ZStack {
                color.opacity(0.3)
                AngularGradient(colors: [color.opacity(0.1), color, .white, color.opacity(0.2)], center: .center)
                    .rotationEffect(.radians(phase)).scaleEffect(2)
                Rectangle().fill(.white.opacity(0.65)).frame(width: 7)
                    .blur(radius: 3).offset(x: sin(phase) * space.size.width * 0.42)
                LinearGradient(colors: [.white.opacity(0.3), .clear, .black.opacity(0.4)], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: color.opacity(0.4 + 0.4 * max(0, cos(phase))), radius: 16)
        }
    }
}
