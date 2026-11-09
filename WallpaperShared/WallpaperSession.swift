import ColorSync
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import OSLog

enum NativeWallpaper {
    static let provider = "com.waynegong.MacSentry.wallpaper"
    static let log = Logger(subsystem: "com.waynegong.MacSentry", category: "wallpaper")
    static let maximumPacketSize = 128 * 1024
    static let supported: Bool = {
        var build = [CChar](repeating: 0, count: 64)
        var size = build.count
        guard sysctlbyname("kern.osversion", &build, &size, nil, 0) == 0 else { return false }
        return ["26B123"].contains(String(cString: build))
    }()

    // 通过真实用户主目录定位应用专用壁纸缓存，扩展只读此目录，喵~
    static let directory: URL? = {
        guard let user = getpwuid(getuid()), let home = user.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Library/Application Support/com.waynegong.MacSentry.Wallpaper", isDirectory: true)
    }()

    // 只有本人独占的缓存目录才可用于交换会话密钥与壁纸素材，喵~
    static func cache(create: Bool = false) -> URL? {
        guard let directory else { return nil }
        let files = FileManager.default
        if create && !files.fileExists(atPath: directory.path) {
            try? files.createDirectory(at: directory, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
        }
        guard let attrs = try? files.attributesOfItem(atPath: directory.path),
              attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue,
              mode & 0o077 == 0 else { return nil }
        return directory
    }

    // 用物理显示器的 UUID 查找启用前保存的壁纸，热插拔后不依赖临时显示器编号，喵~
    static func fallbackURL(display: CGDirectDisplayID, in directory: URL) -> URL? {
        let display = display == 0 ? CGMainDisplayID() : display
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
              let name = CFUUIDCreateString(nil, uuid) else { return nil }
        return directory.appendingPathComponent("desktop-\(name).jpg")
    }

    // 读取当前显示器的系统壁纸副本，喵~
    static func fallback(display: CGDirectDisplayID, in directory: URL) -> CGImage? {
        guard let url = fallbackURL(display: display, in: directory),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // 锁定与否由系统会话状态独立确认，喵~
    static func isLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool != false else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
    }

    // 每个 TCP 消息使用大端长度与本次锁屏密钥加密，视频只在内存中转发，喵~
    static func packet(_ frame: Data, key: Data) -> Data? {
        guard key.count == 32,
              let message = try? ChaChaPoly.seal(frame, using: SymmetricKey(data: key)).combined,
              !message.isEmpty, message.count <= maximumPacketSize else { return nil }
        var length = UInt32(message.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + message
    }

    // 在解码前校验完整性和本次会话密钥，喵~
    static func openPacket(_ message: Data, key: Data) -> Data? {
        guard key.count == 32, message.count <= maximumPacketSize,
              let box = try? ChaChaPoly.SealedBox(combined: message) else { return nil }
        return try? ChaChaPoly.open(box, using: SymmetricKey(data: key))
    }
}

struct WallpaperSession: Codable {
    let id: UUID
    let guardImage: String?
    let alarmImage: String?
    let guardConfigured: Bool
    let alarmConfigured: Bool
    let port: UInt16
    let cameraKey: Data
    var updatedAt: TimeInterval
    var alarm = false
    var camera = false

    var assetName: String? { alarm ? alarmImage : guardImage }
    var hasConfiguredImage: Bool { alarm ? alarmConfigured : guardConfigured }
    var phase: String { alarm ? "alarm" : "guard" }
    var assetDirectory: String { "session-\(id.uuidString)" }

    // 限定素材文件名和路径，避免配置指向缓存以外的文件，喵~
    func imageURL(in directory: URL) -> URL? {
        guard let assetName, ["guard", "alarm"].contains((assetName as NSString).deletingPathExtension),
              ["png", "jpeg", "jpg", "heic", "gif", "apng"].contains((assetName as NSString).pathExtension) else { return nil }
        return directory.appendingPathComponent(assetDirectory, isDirectory: true).appendingPathComponent(assetName)
    }

    // 已退出或失去心跳的守卫会话回退到桌面壁纸，喵~
    static func current(in directory: URL, now: TimeInterval) -> WallpaperSession? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("session.json")), data.count < 4096,
              let session = try? JSONDecoder().decode(Self.self, from: data),
              now >= session.updatedAt, now - session.updatedAt < 3,
              session.port >= 49_152, session.cameraKey.count == 32 else { return nil }
        return session
    }
}
