import AppKit
import AVFAudio
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SentryLogic

final class SentryMediaTests: XCTestCase {
    // 导入后删除原文件并重新读取配置，图片和声音仍应从容器副本恢复，喵~
    func testImportedMediaSurvivesOriginalRemovalAndRestart() throws {
        let root = try temporaryDirectory()
        let store = SentryMediaStore(directory: root.appendingPathComponent("Media"))
        let source = try writeImage(in: root, type: .png)
        let sound = root.appendingPathComponent("source.wav")
        try waveData().write(to: sound)
        var config = SentryConfiguration()
        config.sentryGuardingImage = try store.importFile(source, kind: .image)
        config.sentryAlarmImage = try store.importFile(source, kind: .image)
        config.sentryAlarmSound = try store.importFile(sound, kind: .sound)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: sound)
        let restored = try JSONDecoder().decode(SentryConfiguration.self, from: JSONEncoder().encode(config))
        let media = SentryMediaStore(directory: store.directory).load(restored)
        XCTAssertEqual(media.guardingImage?.poster.size, NSSize(width: 8, height: 4))
        XCTAssertNil(media.guardingImage?.animationURL)
        XCTAssertNotNil(media.alarmImage)
        XCTAssertEqual(media.alarmSound?.lastPathComponent, config.sentryAlarmSound)
        XCTAssertTrue(media.issues.isEmpty)
    }

    // 支持的三种静态图片必须实际解码，不仅依赖文件扩展名，喵~
    func testSupportedImageFormats() throws {
        let root = try temporaryDirectory()
        let store = SentryMediaStore(directory: root.appendingPathComponent("Media"))
        for type in [UTType.png, .jpeg, .heic, .gif] {
            let source = try writeImage(in: root, type: type)
            var config = SentryConfiguration()
            config.sentryGuardingImage = try store.importFile(source, kind: .image)
            XCTAssertNotNil(store.load(config).guardingImage, type.identifier)
            XCTAssertTrue(store.load(config).issues.isEmpty, type.identifier)
        }
    }

    // GIF 与 APNG 保留多帧，导入副本可播放并循环到首帧，喵~
    func testImportedAnimatedImagesLoop() throws {
        let root = try temporaryDirectory()
        let store = SentryMediaStore(directory: root.appendingPathComponent("Media"))
        for type in [UTType.gif, .png] {
            let url = try writeAnimation(in: root, type: type)
            var config = SentryConfiguration()
            config.sentryAlarmImage = try store.importFile(url, kind: .image)
            try FileManager.default.removeItem(at: url)
            let media = store.load(config)
            XCTAssertTrue(media.issues.isEmpty, type.identifier)
            let imported = try XCTUnwrap(media.alarmImage?.animationURL)
            let looped = expectation(description: "\(type.identifier) 播放到下一轮")
            var frames: [Int] = []
            let status = CGAnimateImageAtURLWithBlock(imported as CFURL,
                [kCGImageAnimationLoopCount: Double.infinity] as CFDictionary) { index, _, stop in
                frames.append(index)
                if frames.count == 6 {
                    stop.pointee = true
                    looped.fulfill()
                }
            }
            XCTAssertEqual(status, noErr)
            wait(for: [looped], timeout: 3)
            XCTAssertEqual(frames, [0, 1, 0, 1, 0, 1])
        }
    }

    // WAV、内置 MP3 与系统编码的 M4A 均应通过音频导入并可重新解码，喵~
    func testSupportedSoundFormats() throws {
        let root = try temporaryDirectory()
        let store = SentryMediaStore(directory: root.appendingPathComponent("Media"))
        let wave = root.appendingPathComponent("source.wav")
        try waveData().write(to: wave)
        let mp3 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sentry/alarm.mp3")
        let m4a = try writeM4A(in: root)
        for source in [wave, mp3, m4a] {
            var config = SentryConfiguration()
            config.sentryAlarmSound = try store.importFile(source, kind: .sound)
            let media = store.load(config)
            XCTAssertEqual(media.alarmSound?.lastPathComponent, config.sentryAlarmSound)
            XCTAssertTrue(media.issues.isEmpty)
        }
    }

    // 无效素材必须清除临时副本，同时保留已导入的有效资源，喵~
    func testInvalidImportsPreserveExistingMedia() throws {
        let root = try temporaryDirectory()
        let store = SentryMediaStore(directory: root.appendingPathComponent("Media"))
        let source = try writeImage(in: root, type: .png)
        let reference = try store.importFile(source, kind: .image)
        for (name, kind) in [("bad.png", SentryMediaKind.image), ("bad.gif", .image), ("bad.apng", .image),
                             ("bad.wav", .sound), ("unsupported.txt", .image)] {
            let bad = root.appendingPathComponent(name)
            try Data("invalid media".utf8).write(to: bad)
            XCTAssertThrowsError(try store.importFile(bad, kind: kind))
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertEqual(remaining, [reference])
    }

    // 缺失、损坏和越界引用均独立回退，默认配置不应产生故障提示，喵~
    func testMissingAndCorruptMediaFallBackIndependently() throws {
        let root = try temporaryDirectory()
        let store = SentryMediaStore(directory: root.appendingPathComponent("Media"))
        let source = try writeImage(in: root, type: .png)
        var config = SentryConfiguration()
        let defaults = store.load(config)
        XCTAssertNil(defaults.guardingImage)
        XCTAssertNil(defaults.alarmImage)
        XCTAssertTrue(defaults.issues.isEmpty)
        config.sentryGuardingImage = try store.importFile(source, kind: .image)
        config.sentryAlarmImage = "missing.png"
        config.sentryAlarmSound = "broken.wav"
        try Data("corrupt".utf8).write(to: store.directory.appendingPathComponent("broken.wav"))
        let partial = store.load(config)
        XCTAssertNotNil(partial.guardingImage)
        XCTAssertNil(partial.alarmImage)
        XCTAssertEqual(partial.alarmSound, defaults.alarmSound)
        XCTAssertEqual(partial.issues.count, 2)
        for reference in ["../source.png", source.path, "", ".", ".."] {
            config.sentryGuardingImage = reference
            let invalid = store.load(config)
            XCTAssertNil(invalid.guardingImage)
            XCTAssertEqual(invalid.issues.count, 3)
        }
        config.sentryGuardingImage = nil
        config.sentryAlarmImage = nil
        config.sentryAlarmSound = nil
        XCTAssertTrue(store.load(config).issues.isEmpty)
    }

    // 启动清理只能移除未被当前配置引用的旧副本，喵~
    func testCleanupKeepsConfiguredMedia() throws {
        let root = try temporaryDirectory()
        let store = SentryMediaStore(directory: root.appendingPathComponent("Media"))
        let source = try writeImage(in: root, type: .png)
        let kept = try store.importFile(source, kind: .image)
        _ = try store.importFile(source, kind: .image)
        store.removeUnusedFiles(keeping: [kept])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [kept])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    // 横屏与竖屏共用右上角布局，画中画完整保留不同摄像头比例，喵~
    func testWallpaperCameraUsesSharedInsetsAndAspectFit() {
        for size in [CGSize(width: 1800, height: 1169), CGSize(width: 1440, height: 2560)] {
            let box = WallpaperLayout.camera(in: size)
            XCTAssertEqual(size.width - box.maxX, 24)
            XCTAssertEqual(box.minY, 24)
            XCTAssertEqual(box.size, CGSize(width: 320, height: 180))
            let frame = WallpaperLayout.image(CGSize(width: 640, height: 480), in: box, fill: false)
            XCTAssertEqual(frame.size, CGSize(width: 240, height: 180))
            XCTAssertEqual(frame.midX, box.midX)
            XCTAssertEqual(frame.midY, box.midY)
        }
    }

    // 每项测试使用独立目录，结束后删除生成的非个人素材，喵~
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    // 用系统编码器生成小幅静态图片以验证真实格式导入，喵~
    private func writeImage(in directory: URL, type: UTType) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        let source = directory.appendingPathComponent("source." + (type.preferredFilenameExtension ?? "png"))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return source
    }

    // 生成带帧延时的双色动图，覆盖 APNG 文件扩展名与两种容器的真实解码，喵~
    private func writeAnimation(in directory: URL, type: UTType) throws -> URL {
        let gif = type == .gif
        let url = directory.appendingPathComponent(gif ? "source.gif" : "source.apng")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 2, nil))
        let dictionary = gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
        let loopCount = gif ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
        let delay = gif ? kCGImagePropertyGIFDelayTime : kCGImagePropertyAPNGDelayTime
        CGImageDestinationSetProperties(destination, [dictionary: [loopCount: 1]] as CFDictionary)
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for color in [NSColor.red, .blue] {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [dictionary: [delay: 0.06]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    // 生成短暂的无声音频以覆盖 M4A 解码路径，喵~
    private func writeM4A(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source.m4a")
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 16000])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 800))
        buffer.frameLength = 800
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 800)
        try file.write(from: buffer)
        return url
    }

    // 构造一段无声的单声道 PCM WAV，校验解码时不会播放音频，喵~
    private func waveData() -> Data {
        var data = Data([82, 73, 70, 70, 100, 6, 0, 0, 87, 65, 86, 69,
                         102, 109, 116, 32, 16, 0, 0, 0, 1, 0, 1, 0,
                         64, 31, 0, 0, 128, 62, 0, 0, 2, 0, 16, 0,
                         100, 97, 116, 97, 64, 6, 0, 0])
        data.append(Data(repeating: 0, count: 1600))
        return data
    }
}
