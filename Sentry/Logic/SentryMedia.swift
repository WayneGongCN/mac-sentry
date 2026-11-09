import AppKit
import AVFAudio
import UniformTypeIdentifiers

enum SentryMediaKind {
    case image, sound

    static let apng = UTType(filenameExtension: "apng")

    var contentTypes: [UTType] {
        switch self {
        case .image: return [.png, .jpeg, .heic, .gif] + [Self.apng].compactMap { $0 }
        case .sound: return [.mp3, .mpeg4Audio, .wav]
        }
    }
}

struct SentryMedia {
    var guardingImage: SentryImage?
    var alarmImage: SentryImage?
    var alarmSound = Bundle.main.url(forResource: "alarm", withExtension: "mp3")
    var issues: [String] = []

    // 同一轮守卫内避免重复堆叠相同的素材或播放故障提示，喵~
    mutating func reportIssue(_ message: String) {
        if !issues.contains(message) { issues.append(message) }
    }
}

struct SentryMediaStore {
    static let shared = SentryMediaStore(directory: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("MacSentry/Media", isDirectory: true))
    let directory: URL

    // 在用户选择的文件访问范围内导入独立副本，解码失败时不留下无效素材，喵~
    func importFile(_ source: URL, kind: SentryMediaKind) throws -> String {
        let ext = source.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        guard let type, kind.contentTypes.contains(where: { type.conforms(to: $0) }) else {
            throw MediaError.unsupportedFormat
        }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + "." + ext
        let destination = directory.appendingPathComponent(name)
        do {
            try Data(contentsOf: source, options: .mappedIfSafe).write(to: destination, options: .atomic)
            switch kind {
            case .image: _ = try SentryImage(contentsOf: destination)
            case .sound: try validateSound(at: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return name
    }

    // 为一次守卫或预览解析素材，失效选项独立回退且不影响其他有效选项，喵~
    func load(_ configuration: SentryConfiguration) -> SentryMedia {
        var media = SentryMedia()
        if let reference = configuration.sentryGuardingImage {
            do { media.guardingImage = try SentryImage(contentsOf: storedURL(reference)) }
            catch { media.reportIssue("守卫图片不可用，已使用系统锁屏壁纸。") }
        }
        if let reference = configuration.sentryAlarmImage {
            do { media.alarmImage = try SentryImage(contentsOf: storedURL(reference)) }
            catch { media.reportIssue("告警图片不可用，已使用系统锁屏壁纸。") }
        }
        if let reference = configuration.sentryAlarmSound {
            do {
                let url = try storedURL(reference)
                try validateSound(at: url)
                media.alarmSound = url
            } catch { media.reportIssue("告警声音不可用，已使用内置告警音。") }
        }
        return media
    }

    // 仅在应用启动且尚未守卫时清理旧副本，避免替换设置影响正在使用的素材，喵~
    func removeUnusedFiles(keeping references: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where !references.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // 配置只能引用素材目录内的文件名，防止错误路径逃离应用管理范围，喵~
    func storedURL(_ reference: String) throws -> URL {
        guard !reference.isEmpty, reference != ".", reference != "..",
              (reference as NSString).lastPathComponent == reference else { throw MediaError.invalidResource }
        return directory.appendingPathComponent(reference)
    }

    // 检查支持的音频是否能解码且包含有效时长，校验过程不播放声音，喵~
    private func validateSound(at url: URL) throws {
        guard let type = UTType(filenameExtension: url.pathExtension),
              SentryMediaKind.sound.contentTypes.contains(where: { type.conforms(to: $0) }) else {
            throw MediaError.unsupportedFormat
        }
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.duration.isFinite, player.duration > 0, player.numberOfChannels > 0 else { throw MediaError.invalidSound }
    }
}

private enum MediaError: LocalizedError {
    case unsupportedFormat, invalidResource, invalidSound

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "请选择 PNG、JPEG、HEIC、GIF、APNG 图片或 MP3、M4A、WAV 声音文件。"
        case .invalidResource: return "素材引用无效，请重新选择文件。"
        case .invalidSound: return "声音文件没有可播放的音频。"
        }
    }
}
