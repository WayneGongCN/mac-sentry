import AVFoundation
import Foundation
import OSLog

enum RecordingState: Equatable {
    case idle, starting, recording, finishing
    case failed(String)
    var label: String {
        switch self {
        case .idle: return "未在录像"
        case .starting: return "正在准备录像"
        case .recording: return "正在录像 · 本地保存"
        case .finishing: return "正在保存录像"
        case let .failed(message): return message
        }
    }
}

final class CapturePipeline: NSObject {
    let session = AVCaptureSession()
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onDetection: ((Float, TimeInterval) -> Void)?
    var onCameraIssue: ((String?) -> Void)?
    var onRecordingState: ((RecordingState) -> Void)?
    private let queue = DispatchQueue(label: "com.waynegong.MacSentry.capture")
    private let sampleQueue = DispatchQueue(label: "com.waynegong.MacSentry.samples", qos: .userInitiated)
    private let frameSlots = DispatchSemaphore(value: 2)
    private let detector = FaceDetector()
    private let segmentInterval: TimeInterval
    private let logger = Logger(subsystem: "com.waynegong.MacSentry", category: "capture")
    private var configured = false
    private var monitoring = false
    private var wantsRecording = false
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var currentURL: URL?
    private var segmentStart: CMTime?
    private var lastFrameTime: CMTime?
    private var announcedRecording = false
    private var pendingWriters: [URL: AVAssetWriter] = [:]
    private var eventID = ""
    private var segment = 0
    private var observers: [NSObjectProtocol] = []
    private var finishCallback: (() -> Void)?

    // 让原始视频帧同时供给检测和独立文件写入器，文件收尾不依赖摄像头继续运行，喵~
    init(segmentInterval: TimeInterval = 60) {
        self.segmentInterval = segmentInterval
        super.init()
        detector.onFrame = { [weak self] sample in
            self?.onFrame?(sample)
            self?.enqueue(sample)
        }
        detector.onResult = { [weak self] confidence, time in
            DispatchQueue.main.async { self?.onDetection?(confidence, time) }
        }
        detector.onFailure = { [weak self] text in self?.cameraIssue(text) }
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.cameraIssue("摄像头已中断，等待恢复")
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                                                object: session, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.monitoring else { return }
                self.session.startRunning()
                try? self.configureFrameRate()
            }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // 锁屏时启动共享采集会话，权限不足时仅提示故障，喵~
    func start(detectionEnabled: Bool, useOwnerReference: Bool = false) {
        queue.async { [self] in
            guard !monitoring else { return }
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
                cameraIssue("摄像头未授权，请解锁后在设置中授权")
                return
            }
            do { try cleanRecordings() }
            catch { recordingState(.failed("录像目录暂不可用：\(error.localizedDescription)")) }
            do {
                if !configured { try configure() }
                let owner = detectionEnabled && useOwnerReference ? try? OwnerFaceStore.shared.load() : nil
                sampleQueue.sync {
                    detector.enabled = detectionEnabled
                    detector.ownerReference = owner
                }
                monitoring = true
                session.startRunning()
                try configureFrameRate()
                if !session.isRunning { cameraIssue("摄像头启动失败") }
            } catch { cameraIssue(error.localizedDescription) }
        }
    }

    // 停止采集后仍持有写入器，使文件能够独立完成收尾，喵~
    func stop() {
        queue.async { [self] in
            monitoring = false
            finishEvent()
            session.stopRunning()
            sampleQueue.sync { detector.ownerReference = nil }
        }
    }

    // 采集服务恢复时重建运行状态，喵~
    func recover() {
        queue.async { [self] in
            guard monitoring else { return }
            session.stopRunning()
            session.startRunning()
            try? configureFrameRate()
        }
    }

    // 确认人脸后等待下一帧创建事件文件，避免空文件和重复事件，喵~
    func beginEvent() {
        queue.async { [self] in
            guard monitoring, !wantsRecording else { return }
            wantsRecording = true
            eventID = "Sentry_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8))"
            segment = 0
            recordingState(.starting)
        }
    }

    // 合格人脸消失后结束文件写入，采集会话继续供下一次检测使用，喵~
    func endEvent() { queue.async { [self] in finishEvent() } }

    // 文件清理与写入状态共用串行队列，喵~
    func clean() {
        queue.async { [self] in
            do { try cleanRecordings() }
            catch { recordingState(.failed("录像清理失败：\(error.localizedDescription)")) }
        }
    }

    // 退出应用前等待所有收尾中的文件完成，喵~
    func waitForFinished(_ completion: @escaping () -> Void) {
        queue.async { [self] in
            if pendingWriters.isEmpty { DispatchQueue.main.async(execute: completion) }
            else { finishCallback = completion }
        }
    }

    // 配置单个原始帧输出，预览和检测均复用该摄像头，喵~
    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
            throw pipelineError("未找到内置摄像头")
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let input = try AVCaptureDeviceInput(device: device)
        let data = AVCaptureVideoDataOutput()
        data.alwaysDiscardsLateVideoFrames = true
        data.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        data.setSampleBufferDelegate(detector, queue: sampleQueue)
        guard session.canAddInput(input) else { throw pipelineError("无法添加摄像头输入") }
        session.addInput(input)
        try device.lockForConfiguration()
        if let format = device.formats.first(where: {
            let dimensions = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dimensions.width == 1280 && dimensions.height == 720
                && $0.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 })
        }) { device.activeFormat = format }
        device.unlockForConfiguration()
        guard session.canAddOutput(data) else { throw pipelineError("无法添加摄像头视频输出") }
        session.addOutput(data)
        configured = true
    }

    // 会话启动后设置设备帧率，不向文件压缩节点发送不兼容的连接属性，喵~
    private func configureFrameRate() throws {
        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
        }
    }

    // 有界缓存避免慢磁盘让摄像头帧无限堆积，喵~
    private func enqueue(_ sample: CMSampleBuffer) {
        guard frameSlots.wait(timeout: .now()) == .success else { return }
        queue.async { [self] in
            defer { frameSlots.signal() }
            guard monitoring, wantsRecording else { return }
            write(sample)
        }
    }

    // 以源视频时间戳切换片段并写入，最后一帧与首帧各自只归属一个文件，喵~
    private func write(_ sample: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isValid, time.isNumeric else { return }
        do {
            if let segmentStart, CMTimeGetSeconds(CMTimeSubtract(time, segmentStart)) >= segmentInterval {
                finishSegment()
            }
            if writer == nil { try startSegment(sample: sample, at: time) }
            guard let writer, let input = writerInput else { return }
            guard writer.status == .writing else { throw writer.error ?? pipelineError("录像写入器已停止") }
            guard input.isReadyForMoreMediaData else { return }
            guard input.append(sample) else { throw writer.error ?? pipelineError("无法写入视频帧") }
            lastFrameTime = time
            if !announcedRecording {
                announcedRecording = true
                logger.notice("录像文件已开始写入")
                recordingState(.recording)
            }
        } catch {
            finishEvent()
            recordingState(.failed("录像保存失败：\(error.localizedDescription)"))
        }
    }

    // 由事件第一帧建立独立的文件时间轴，喵~
    private func startSegment(sample: CMSampleBuffer, at time: CMTime) throws {
        try cleanRecordings()
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: videoClipDir.path)
        guard ((attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0) > 250_000_000 else {
            throw pipelineError("磁盘空间不足，已停止录像")
        }
        segment += 1
        let url = videoClipDir.appendingPathComponent("\(eventID)_\(String(format: "%04d", segment)).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000,
                AVVideoExpectedSourceFrameRateKey: 15, AVVideoAllowFrameReorderingKey: false]]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw pipelineError("不支持当前录像编码配置") }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings,
                                      sourceFormatHint: CMSampleBufferGetFormatDescription(sample))
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw pipelineError("无法建立录像写入器") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? pipelineError("无法创建录像文件") }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        writerInput = input
        currentURL = url
        segmentStart = time
        lastFrameTime = nil
        pendingWriters[url] = writer
        announcedRecording = false
    }

    // 标记当前片段结束，编码器独立完成收尾，不持有摄像头运行状态，喵~
    private func finishSegment() {
        guard let writer, let input = writerInput, let url = currentURL else { return }
        if writer.status == .writing {
            if let lastFrameTime { writer.endSession(atSourceTime: CMTimeAdd(lastFrameTime, CMTime(value: 1, timescale: 15))) }
            input.markAsFinished()
        }
        self.writer = nil
        writerInput = nil
        currentURL = nil
        segmentStart = nil
        lastFrameTime = nil
        announcedRecording = false
        let completed = { [self] in
            queue.async { [self] in
                pendingWriters.removeValue(forKey: url)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                if writer.status == .completed {
                    logger.notice("录像文件已保存")
                    if !wantsRecording && pendingWriters.isEmpty { recordingState(.idle) }
                } else {
                    logger.error("录像文件收尾失败")
                    if url.lastPathComponent.hasPrefix(eventID + "_") {
                        finishEvent()
                        recordingState(.failed("录像保存失败：\(writer.error?.localizedDescription ?? "未知错误")"))
                    }
                }
                do { try cleanRecordings() }
                catch { recordingState(.failed("录像清理失败：\(error.localizedDescription)")) }
                if pendingWriters.isEmpty, let callback = finishCallback {
                    finishCallback = nil
                    DispatchQueue.main.async(execute: callback)
                }
            }
        }
        if writer.status == .writing { writer.finishWriting(completionHandler: completed) }
        else { completed() }
    }

    // 尾录结束后停止接受新录像帧，原始帧仍可继续用于识别，喵~
    private func finishEvent() {
        wantsRecording = false
        if writer != nil { recordingState(.finishing); finishSegment() }
        else if pendingWriters.isEmpty { recordingState(.idle) }
    }

    // 清理仅针对本应用的普通录像文件，所有未完成文件保持受保护状态，喵~
    private func cleanRecordings() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: videoClipDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        let entries = try fm.contentsOfDirectory(at: videoClipDir, includingPropertiesForKeys: Array(keys))
            .filter { $0.lastPathComponent.hasPrefix("Sentry_") && $0.pathExtension == "mov" }
            .compactMap { url -> RecordingEntry? in
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                      values.isSymbolicLink != true else { return nil }
                return RecordingEntry(url: url, modified: values.contentModificationDate ?? .distantPast,
                                      bytes: Int64(values.fileSize ?? 0))
            }
        for url in RecordingRetention.removals(from: entries, protected: Set(pendingWriters.keys), now: Date()) { try fm.removeItem(at: url) }
    }

    // 在主线程更新采集故障提示，喵~
    private func cameraIssue(_ text: String?) { DispatchQueue.main.async { [weak self] in self?.onCameraIssue?(text) } }
    // 在主线程更新实际文件写入状态，喵~
    private func recordingState(_ state: RecordingState) { DispatchQueue.main.async { [weak self] in self?.onRecordingState?(state) } }
    // 构造面向用户的采集或存储错误说明，喵~
    private func pipelineError(_ text: String) -> NSError { NSError(domain: "MacSentry", code: 2, userInfo: [NSLocalizedDescriptionKey: text]) }
}
