import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

struct SentryImage {
    let poster: NSImage
    let animationURL: URL?

    // 验证图片及每帧容器状态，并生成已校正方向的首帧，喵~
    init(contentsOf url: URL) throws {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png, .jpeg, .heic, .gif].contains(where: { $0.identifier == type }),
              CGImageSourceGetStatus(source) == .statusComplete else { throw WallpaperImageError.invalid }
        let count = CGImageSourceGetCount(source)
        let animated = count > 1
        guard count > 0, !animated || type == UTType.gif.identifier || type == UTType.png.identifier,
              !animated || (0..<count).allSatisfy({ CGImageSourceGetStatusAtIndex(source, $0) == .statusComplete }),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary) else { throw WallpaperImageError.invalid }
        poster = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        animationURL = animated ? url : nil
    }

    // 为静态预览保留调用方传入的首帧，喵~
    init(poster: NSImage, animationURL: URL?) {
        self.poster = poster
        self.animationURL = animationURL
    }
}

final class WallpaperPlayback: ObservableObject {
    @Published private(set) var frame: NSImage?
    private var generation = 0

    // 播放所选素材的帧序列，状态变化后使旧回调停止，喵~
    func show(_ image: SentryImage?) {
        generation += 1
        let current = generation
        frame = image?.poster
        guard let url = image?.animationURL else { return }
        let options = [kCGImageAnimationLoopCount: Double.infinity] as CFDictionary
        let status = CGAnimateImageAtURLWithBlock(url as CFURL, options) { [weak self] _, image, stop in
            guard let self, self.generation == current else {
                stop.pointee = true
                return
            }
            self.frame = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        if status != noErr { frame = nil }
    }
}

enum WallpaperLayout {
    static let cornerRadius: CGFloat = 12

    // 以左上角为原点计算画中画，布局只取决于视口尺寸，喵~
    static func camera(in size: CGSize) -> CGRect {
        let side = min(size.width, size.height)
        let inset = min(24, side / 12)
        let width = min(320, side * 0.35)
        return CGRect(x: size.width - inset - width, y: inset, width: width, height: width * 9 / 16)
    }

    // 使原图保持比例，按背景铺满或摄像头完整可见的规则居中，喵~
    static func image(_ size: CGSize, in bounds: CGRect, fill: Bool) -> CGRect {
        let x = bounds.width / size.width
        let y = bounds.height / size.height
        let scale = fill ? max(x, y) : min(x, y)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
}

private enum WallpaperImageError: LocalizedError {
    case invalid
    var errorDescription: String? { "无法解码图片，请选择有效的 PNG、JPEG、HEIC、GIF 或 APNG 文件。" }
}
