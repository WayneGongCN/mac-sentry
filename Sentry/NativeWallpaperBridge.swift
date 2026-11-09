import AppKit
import AVFoundation
import CoreImage
import CryptoKit
import ImageIO
import Network
import UniformTypeIdentifiers

enum WallpaperSetupError: LocalizedError {
    case unavailable
    case desktop(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "此系统无法启用 Mac 哨兵锁屏壁纸。"
        case let .desktop(name): return "无法读取「\(name)」的系统壁纸。请先在系统设置中为它选一张本机可读取的静态壁纸。"
        }
    }
}

extension NativeWallpaper {
    // 在用户选择壁纸扩展之前保存每块显示器正在使用的原壁纸，喵~
    static func prepareFallbacks(authorize: (NSScreen, URL) -> URL?) throws {
        guard supported, let directory = cache(create: true), !NSScreen.screens.isEmpty else {
            throw WallpaperSetupError.unavailable
        }
        let workspace = NSWorkspace.shared
        let snapshots: [(URL, Data)] = try NSScreen.screens.compactMap { screen in
            let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            guard let target = fallbackURL(display: display, in: directory) else {
                throw WallpaperSetupError.desktop(screen.localizedName)
            }
            if let url = workspace.desktopImageURL(for: screen), url.isFileURL,
               !url.path.contains("/SentryWallpaper.appex/") {
                let options = workspace.desktopImageOptions(for: screen)
                if let data = desktopSnapshot(url: url, screen: screen, options: options) {
                    return (target, data)
                }
                if let granted = authorize(screen, url),
                   granted.standardizedFileURL == url.standardizedFileURL,
                   let data = desktopSnapshot(url: granted, screen: screen, options: options) {
                    return (target, data)
                }
                throw WallpaperSetupError.desktop(screen.localizedName)
            }
            guard fallback(display: display, in: directory) != nil else {
                throw WallpaperSetupError.desktop(screen.localizedName)
            }
            return nil
        }
        for (url, data) in snapshots { try data.write(to: url, options: .atomic) }
        log.notice("[壁纸] 已准备系统壁纸副本，显示器=\(NSScreen.screens.count)")
    }

    // 预览优先显示当前可读的系统壁纸，启用后读取该屏保存的副本，喵~
    static func previewFallback() -> NSImage? {
        guard let screen = NSScreen.main else { return nil }
        let workspace = NSWorkspace.shared
        if let url = workspace.desktopImageURL(for: screen), url.isFileURL,
           !url.path.contains("/SentryWallpaper.appex/"),
           let image = NSImage(contentsOf: url) { return image }
        let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        guard let directory = cache(), let image = fallback(display: display, in: directory) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // 保留原壁纸的方向、缩放选项与填充色，生成每屏的静态回退画面，喵~
    private static func desktopSnapshot(url: URL, screen: NSScreen,
                                        options: [NSWorkspace.DesktopImageOptionKey: Any]?) -> Data? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3840,
              ] as CFDictionary) else { return nil }
        let size = screen.frame.size
        let scale = min(screen.backingScaleFactor, 3840 / max(size.width, size.height))
        let width = max(1, Int(size.width * scale))
        let height = max(1, Int(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let color = (options?[.fillColor] as? NSColor)?.usingColorSpace(.deviceRGB) ?? .black
        context.setFillColor(color.cgColor)
        context.fill(bounds)
        let imageSize = CGSize(width: image.width, height: image.height)
        let scaling = (options?[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
        let rect: CGRect
        switch scaling {
        case .scaleAxesIndependently: rect = bounds
        case .scaleNone:
            let factor = scale / screen.backingScaleFactor
            rect = CGRect(x: bounds.midX - imageSize.width * factor / 2,
                          y: bounds.midY - imageSize.height * factor / 2,
                          width: imageSize.width * factor, height: imageSize.height * factor)
        default:
            rect = WallpaperLayout.image(imageSize, in: bounds, fill: options?[.allowClipping] as? Bool ?? true)
        }
        context.draw(image, in: rect)
        let data = NSMutableData()
        guard let snapshot = context.makeImage(),
              let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, snapshot, [kCGImageDestinationLossyCompressionQuality: 0.93] as CFDictionary)
        return CGImageDestinationFinalize(output) ? data as Data : nil
    }
}

final class NativeWallpaperBridge {
    private let queue = DispatchQueue(label: "com.waynegong.MacSentry.wallpaper.bridge")
    private let frameSlot = DispatchSemaphore(value: 1)
    private lazy var context = CIContext()
    private var directory: URL?
    private var session: WallpaperSession?
    private var connection: NWConnection?
    private var ready = false
    private var sending = false
    private var lastConnect = -Double.infinity
    private var lastFrame = -Double.infinity

    // 建立每次锁屏独立的素材副本和密钥，失败时保留原壁纸，喵~
    func begin(configuration: SentryConfiguration, media: SentryMedia) {
        guard NativeWallpaper.supported else { return }
        queue.async { [self] in
            stopSession()
            guard let directory = NativeWallpaper.cache(),
                  let fallback = NativeWallpaper.fallbackURL(display: 0, in: directory),
                  FileManager.default.fileExists(atPath: fallback.path) else { return }
            let id = UUID()
            let folder = directory.appendingPathComponent("session-\(id.uuidString)", isDirectory: true)
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
            catch {
                NativeWallpaper.log.error("[壁纸] 无法创建会话素材目录")
                return
            }
            self.directory = directory
            self.session = WallpaperSession(id: id,
                guardImage: stage(media.guardingImage, reference: configuration.sentryGuardingImage, name: "guard", in: folder),
                alarmImage: stage(media.alarmImage, reference: configuration.sentryAlarmImage, name: "alarm", in: folder),
                guardConfigured: configuration.sentryGuardingImage != nil, alarmConfigured: configuration.sentryAlarmImage != nil,
                port: UInt16.random(in: 49_152...65_535),
                cameraKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
                updatedAt: 0)
            publish(alarm: false, camera: false)
        }
    }

    // 交接当前真实告警状态并续约锁屏会话，喵~
    func update(alarm: Bool, camera: Bool) {
        guard NativeWallpaper.supported else { return }
        queue.async { [self] in publish(alarm: alarm, camera: camera) }
    }

    // 结束会话并清除交接状态及临时素材，喵~
    func end() {
        guard NativeWallpaper.supported else { return }
        queue.sync { stopSession() }
    }

    // 清理由进程意外退出留下的会话文件，喵~
    func cleanStaleSession() {
        guard NativeWallpaper.supported, let folder = NativeWallpaper.cache() else { return }
        queue.async {
            let files = FileManager.default
            try? files.removeItem(at: folder.appendingPathComponent("session.json"))
            for url in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                let name = url.lastPathComponent
                if name.hasPrefix("session-"), UUID(uuidString: String(name.dropFirst("session-".count))) != nil {
                    try? files.removeItem(at: url)
                }
            }
        }
    }

    // 从现有摄像头管道取样，慢连接时丢弃帧以免影响检测和录像，喵~
    func offer(_ sample: CMSampleBuffer) {
        guard NativeWallpaper.supported, frameSlot.wait(timeout: .now()) == .success else { return }
        queue.async { [self] in
            defer { frameSlot.signal() }
            let now = ProcessInfo.processInfo.systemUptime
            guard let session, session.camera, ready, !sending, let connection,
                  now - lastFrame >= 1.0 / 12, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            let image = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, 640 / max(image.extent.width, image.extent.height))
            guard let jpeg = context.jpegRepresentation(of: image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
                     colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.65]),
                  let packet = NativeWallpaper.packet(jpeg, key: session.cameraKey) else { return }
            lastFrame = now
            sending = true
            connection.send(content: packet, completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection, self.connection === connection else { return }
                self.sending = false
                if error != nil { self.disconnect() }
            })
        }
    }

    // 保留原始素材格式，让扩展复用同一 GIF 和 APNG 播放器，喵~
    private func stage(_ image: SentryImage?, reference: String?, name: String, in folder: URL) -> String? {
        guard image != nil, let reference, let source = try? SentryMediaStore.shared.storedURL(reference) else { return nil }
        let filename = "\(name).\(source.pathExtension.lowercased())"
        do {
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(filename))
            return filename
        } catch { return nil }
    }

    // 原子更新会话文件，告警停止或摄像头故障时断开视频流，喵~
    private func publish(alarm: Bool, camera: Bool) {
        guard let directory, var session else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let camera = alarm && camera
        if session.alarm == alarm, session.camera == camera, now - session.updatedAt < 0.5 { return }
        session.updatedAt = now
        session.alarm = alarm
        session.camera = camera
        do {
            try JSONEncoder().encode(session).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        } catch {
            stopSession()
            return
        }
        self.session = session
        if session.camera { connect(port: session.port, now: now) }
        else { disconnect() }
    }

    // 仅连接 IPv4 回环，失败后等下一次状态心跳重试，喵~
    private func connect(port: UInt16, now: TimeInterval) {
        guard connection == nil, now - lastConnect >= 0.5, let port = NWEndpoint.Port(rawValue: port) else { return }
        lastConnect = now
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready: self.ready = true
            case .waiting, .failed: self.disconnect()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    // 清理旧连接，防止待发送的帧跨告警会话复用，喵~
    private func disconnect() {
        connection?.cancel()
        connection = nil
        ready = false
        sending = false
    }

    // 删除会话令牌，再释放传输和已暂存的素材，喵~
    private func stopSession() {
        disconnect()
        if let directory, let session {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("session.json"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(session.assetDirectory))
        }
        directory = nil
        session = nil
        lastConnect = -.infinity
        lastFrame = -.infinity
    }
}
