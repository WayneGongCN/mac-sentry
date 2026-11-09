import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import Network

struct WallpaperDestination: Equatable {
    let display: CGDirectDisplayID
    let size: CGSize
    let scale: CGFloat
    let preview: Bool
}

final class WallpaperSurface {
    let context: CAContext
    private let root = CALayer()
    private let video = AVSampleBufferDisplayLayer()
    private var pool: CVPixelBufferPool?
    private(set) var destination: WallpaperDestination
    private(set) var fallback: CGImage?
    private var previousBackground: CGImage?
    private var previousCamera: CGImage?
    private var previousState = ""

    // 让 WallpaperAgent 持有系统壁纸层的远程绘制上下文，喵~
    init?(destination: WallpaperDestination, directory: URL) {
        let options = ["displayId": destination.display]
        let remote = destination.display == 0 ? CAContext.remoteContext()
            : CAContext.perform(NSSelectorFromString("remoteContextWithOptions:"), with: options)?.takeUnretainedValue()
        guard let context = remote as? CAContext, context.contextId != 0 else { return nil }
        self.context = context
        self.destination = destination
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        video.videoGravity = .resize
        root.addSublayer(video)
        context.layer = root
        guard configure(destination, directory: directory) else { return nil }
    }

    // 显示器尺寸变化时更新合成缓冲区和该屏回退壁纸，保留系统持有的上下文，喵~
    @discardableResult
    func configure(_ destination: WallpaperDestination, directory: URL) -> Bool {
        let size = destination.size
        guard size.width.isFinite, size.height.isFinite, destination.scale.isFinite,
              size.width > 0, size.height > 0, destination.scale > 0 else { return false }
        let factor = min(destination.scale, 2560 / max(size.width, size.height))
        let width = max(4, Int(size.width * factor) / 2 * 2)
        let height = max(4, Int(size.height * factor) / 2 * 2)
        let attrs: [CFString: Any] = [
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var nextPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &nextPool) == kCVReturnSuccess,
              let nextPool,
              let fallback = NativeWallpaper.fallback(display: destination.display, in: directory)
                ?? NativeWallpaper.fallback(display: 0, in: directory) else { return false }
        clear()
        self.destination = destination
        self.pool = nextPool
        self.fallback = fallback
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = destination.scale
        video.frame = root.bounds
        video.contentsScale = destination.scale
        CATransaction.commit()
        return true
    }

    // 合成比例正确的壁纸与右上角视频，并在状态变化时记录可核对的几何数据，喵~
    func render(background: CGImage, camera: CGImage?, phase: String, source: String) {
        let state = "\(phase)/\(source)/\(camera != nil)"
        guard state != previousState || background !== previousBackground || camera !== previousCamera else { return }
        if previousCamera != nil && camera == nil { clear() }
        guard let sample = makeSample(background: background, camera: camera) else { return }
        video.sampleBufferRenderer.enqueue(sample)
        if state != previousState, !destination.preview {
            let box = WallpaperLayout.camera(in: destination.size)
            NativeWallpaper.log.notice("[壁纸] display=\(self.destination.display) phase=\(phase, privacy: .public) background=\(source, privacy: .public) pip=\(camera != nil) right=\(Int(self.destination.size.width - box.maxX)) top=\(Int(box.minY)) width=\(Int(box.width)) height=\(Int(box.height))")
        }
        previousBackground = background
        previousCamera = camera
        previousState = state
    }

    // 屏幕停用或解锁时清除图层上的上一帧摄像头画面，喵~
    func clear() {
        video.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        previousBackground = nil
        previousCamera = nil
        previousState = ""
    }

    // 用有界缓冲池生成系统壁纸能够直接合成的 IOSurface 视频帧，喵~
    private func makeSample(background: CGImage, camera: CGImage?) -> CMSampleBuffer? {
        guard let pool, video.sampleBufferRenderer.isReadyForMoreMediaData else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let painted = paint(pixelBuffer, background: background, camera: camera)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard painted else { return nil }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                            formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           let entry = CFArrayGetValueAtIndex(attachments, 0) {
            CFDictionarySetValue(unsafeBitCast(entry, to: CFMutableDictionary.self),
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    // 将预览共用的左上原点布局转换到 Core Graphics 的左下坐标系，喵~
    private func paint(_ buffer: CVPixelBuffer, background: CGImage, camera: CGImage?) -> Bool {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let canvas = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        let size = destination.size
        canvas.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        let bounds = CGRect(origin: .zero, size: size)
        canvas.setFillColor(CGColor(gray: 0, alpha: 1))
        canvas.fill(bounds)
        canvas.draw(background, in: WallpaperLayout.image(
            CGSize(width: background.width, height: background.height), in: bounds, fill: true))
        if let camera {
            let top = WallpaperLayout.camera(in: size)
            let rect = CGRect(x: top.minX, y: bounds.maxY - top.maxY, width: top.width, height: top.height)
            canvas.addPath(CGPath(roundedRect: rect, cornerWidth: WallpaperLayout.cornerRadius,
                                  cornerHeight: WallpaperLayout.cornerRadius, transform: nil))
            canvas.clip()
            canvas.fill(rect)
            canvas.draw(camera, in: WallpaperLayout.image(CGSize(width: camera.width, height: camera.height), in: rect, fill: false))
        }
        return true
    }
}

final class WallpaperRenderer {
    static let shared = WallpaperRenderer()
    private let playback = WallpaperPlayback()
    private let camera = WallpaperCameraReceiver()
    private var surfaces: [UUID: WallpaperSurface] = [:]
    private var timer: Timer?
    private var selection: String?
    private var previousFrame: NSImage?
    private var frame: CGImage?

    // 在系统创建展示表面时开始共用播放循环，喵~
    func acquire(_ id: UUID, destination: WallpaperDestination) -> WallpaperSurface? {
        guard let directory = NativeWallpaper.cache(),
              let surface = WallpaperSurface(destination: destination, directory: directory) else { return nil }
        surfaces[id] = surface
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.render() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        render()
        return surface
    }

    // 系统更新有效几何时重配该屏壁纸图层，喵~
    func resize(_ id: UUID, destination: WallpaperDestination) {
        guard let surface = surfaces[id], let directory = NativeWallpaper.cache() else { return }
        let size = WallpaperDestination(display: destination.display == 0 ? surface.destination.display : destination.display,
                                        size: destination.size, scale: destination.scale, preview: surface.destination.preview)
        guard surface.destination != size else { return }
        surface.configure(size, directory: directory)
        render()
    }

    // 最后一个系统展示表面撤销后停止播放和连接，喵~
    func release(_ id: UUID) {
        surfaces.removeValue(forKey: id)?.clear()
        if surfaces.isEmpty {
            timer?.invalidate()
            timer = nil
            camera.update(nil)
            selection = nil
            playback.show(nil)
            previousFrame = nil
            frame = nil
        }
    }

    // 壁纸快照始终来自保存的原系统壁纸，喵~
    func snapshot(_ id: UUID?) -> CGImage? {
        if let id, let fallback = surfaces[id]?.fallback { return fallback }
        guard let directory = NativeWallpaper.cache() else { return nil }
        return NativeWallpaper.fallback(display: 0, in: directory)
    }

    // 每一轮读取相同的背景和摄像头帧，内外屏共享动画进度，喵~
    private func render() {
        let now = ProcessInfo.processInfo.systemUptime
        let visible = surfaces.values.contains { !$0.destination.preview && CGDisplayIsAsleep($0.destination.display) == 0 }
        let directory = NativeWallpaper.cache()
        let session = visible && NativeWallpaper.isLocked()
            ? directory.flatMap { WallpaperSession.current(in: $0, now: now) } : nil
        let next = session.map { "\($0.id)-\($0.phase)" }
        if selection != next {
            selection = next
            let url = directory.flatMap { session?.imageURL(in: $0) }
            playback.show(url.flatMap { try? SentryImage(contentsOf: $0) })
        }
        if playback.frame !== previousFrame {
            previousFrame = playback.frame
            frame = playback.frame?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        camera.update(session)
        let inset = session?.camera == true ? camera.image(at: now) : nil
        for surface in surfaces.values {
            guard let fallback = surface.fallback else { continue }
            if surface.destination.preview {
                surface.render(background: fallback, camera: nil, phase: "preview", source: "system")
            } else if CGDisplayIsAsleep(surface.destination.display) != 0 {
                surface.clear()
            } else {
                let source = frame != nil ? "custom" : (session?.hasConfiguredImage == true ? "invalid" : "system")
                surface.render(background: frame ?? fallback, camera: inset, phase: session?.phase ?? "desktop", source: source)
            }
        }
    }
}

private final class WallpaperCameraReceiver {
    private var listener: NWListener?
    private var connection: NWConnection?
    private var session: WallpaperSession?
    private var latest: (CGImage, TimeInterval)?

    // 仅在有效锁屏会话中接收本机相机帧，告警解除即丢弃上一帧，喵~
    func update(_ state: WallpaperSession?) {
        if state?.id != session?.id {
            listener?.cancel()
            listener = nil
            disconnect()
        } else if state?.camera != true, session?.camera == true {
            disconnect()
        }
        session = state
        guard listener == nil, let state, let port = NWEndpoint.Port(rawValue: state.port) else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] candidate in
                guard let self, self.session?.camera == true, self.connection == nil else {
                    candidate.cancel()
                    return
                }
                self.connection = candidate
                candidate.start(queue: .main)
                self.read(candidate)
            }
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    NativeWallpaper.log.error("[壁纸] 回环接收端启动失败 \(String(describing: error), privacy: .public)")
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch { NativeWallpaper.log.error("[壁纸] 无法创建回环接收端") }
    }

    // 摄像头断帧后自动隐藏画中画，喵~
    func image(at now: TimeInterval) -> CGImage? {
        guard let (image, time) = latest, now - time < 1 else { return nil }
        return image
    }

    // 校验消息大小、会话密钥与 JPEG 内容后再更新显示帧，喵~
    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self, self.connection === connection else { return }
            guard error == nil, let header, header.count == 4 else { self.disconnect(); return }
            let length = header.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= NativeWallpaper.maximumPacketSize else { self.disconnect(); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] bytes, _, _, error in
                guard let self, self.connection === connection else { return }
                guard error == nil, let bytes, bytes.count == length,
                      let state = self.session, state.camera, NativeWallpaper.isLocked(),
                      let jpeg = NativeWallpaper.openPacket(bytes, key: state.cameraKey),
                      let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    self.disconnect()
                    return
                }
                self.latest = (image, ProcessInfo.processInfo.systemUptime)
                self.read(connection)
            }
        }
    }

    // 关闭当前会话的相机通道并释放缓存画面，喵~
    private func disconnect() {
        connection?.cancel()
        connection = nil
        latest = nil
    }
}
