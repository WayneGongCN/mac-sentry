import AppKit
import ExtensionFoundation
import IOSurface
import Security

// 为系统扩展接口记录不含素材和视频内容的状态，喵~
func extensionLog(_ message: String) {
    NativeWallpaper.log.notice("[壁纸] \(message, privacy: .public)")
}

enum CallerValidation {
    // 原生壁纸上下文只交给通过 Apple 代码签名验证的宿主，喵~
    static func isAcceptable(_ connection: NSXPCConnection) -> Bool {
        guard connection.responds(to: NSSelectorFromString("auditToken")) else { return false }
        var token = connection.auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }
}

@main
final class SentryWallpaperExtension: NSObject, AppExtension {
    required override init() {
        super.init()
        guard NativeWallpaper.supported else { return }
        let path = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if dlopen(path, RTLD_NOW) == nil { extensionLog("无法加载 WallpaperExtensionKit") }
    }

    var configuration: some AppExtensionConfiguration {
        return WallpaperConfiguration()
    }
}

// 只有已准备好原系统壁纸时，才在系统设置提供 Mac 哨兵选项，喵~
func buildWallpaperCatalog() -> Any? {
    guard NativeWallpaper.supported, let cache = NativeWallpaper.cache(),
          NativeWallpaper.fallback(display: 0, in: cache) != nil,
          let thumbnail = Bundle.main.url(forResource: "icon-256", withExtension: "png") else { return nil }
    let provider = ChoiceProviderID(rawValue: NativeWallpaper.provider)
    let choice = "sentry-lock-screen"
    let title = "Mac 哨兵锁屏壁纸"
    let id = ChoiceID(id: choice, descriptor: ChoiceIDDescriptor(
        provider: provider, identifier: choice, files: [thumbnail], configuration: Data(choice.utf8)))
    let preview: Thumbnail = .image(url: thumbnail)
    let descriptor = ChoiceDescriptor(id: id, provider: provider, identifier: choice,
        name: title, localizedDescription: "守卫与告警画面显示在原生登录控件下方", thumbnail: preview,
        isDownloaded: true, options: [])
    let item = SettingsItem(id: id, localizedName: title, thumbnail: preview, choice: descriptor,
        contentBadge: .video, showInTopLevel: true, sortOrder: 0, disposability: .none, contextMenu: nil)
    let group = SettingsGroup(id: GroupID(id: "sentry-lock-screen"), items: [item], localizedName: "Mac 哨兵",
        disposability: .none, sortOrder: -100, sortID: GroupSortID(id: "com.apple.wallpaper.aerials"), allChoiceID: nil,
        shouldHideItemLabels: false, contextMenu: nil, thumbnail: nil)
    let model = SettingsViewModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false)
    let shim = ShimViewModelsXPC(value: SettingsViewModels(desktop: model, screenSaver: nil))
    guard let cls = objc_getClass("WallpaperSettingsViewModelsXPC") as? AnyClass,
          let data = try? NSKeyedArchiver.archivedData(withRootObject: shim, requiringSecureCoding: false),
          let decoder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    decoder.requiresSecureCoding = false
    decoder.decodingFailurePolicy = .setErrorAndReturn
    decoder.setClass(cls, forClassName: "ShimViewModelsXPC")
    let result = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    if let error = decoder.error { extensionLog("壁纸选项编码失败 \(error as NSError)") }
    decoder.finishDecoding()
    return result
}

// 递归读取系统 XPC 包装中的几何、展示模式和 UUID，喵~
private func lookup(_ label: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 6 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == label { return child.value }
        if let found = lookup(label, in: child.value, depth: depth + 1) { return found }
    }
    return nil
}
// 取得系统为该壁纸上下文分配的稳定 UUID，喵~
private func findID(_ value: Any?, depth: Int = 0) -> UUID? {
    guard depth < 8, let value else { return nil }
    if let uuid = value as? UUID { return uuid }
    return Mirror(reflecting: value).children.lazy.compactMap { findID($0.value, depth: depth + 1) }.first
}
// 系统请求快照时只返回该屏启用前的原壁纸，喵~
private func wallpaperSnapshot(_ frame: CGImage) -> Any? {
    guard let surface = IOSurface(properties: [.width: frame.width, .height: frame.height,
                                               .bytesPerElement: 4, .pixelFormat: 0x42475241]) else { return nil }
    surface.lock(options: [], seed: nil)
    defer { surface.unlock(options: [], seed: nil) }
    guard let ctx = CGContext(data: surface.baseAddress, width: frame.width, height: frame.height,
                              bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
    return createSnapshotXPC(surface: surface)
}

// 解包 WallpaperAgent 的显示器与缩放信息，喵~
private func destination(from request: Any?, preview: Bool = false) -> WallpaperDestination? {
    guard let request, let target = lookup("destination", in: request),
          let size = lookup("size", in: target) as? CGSize else { return nil }
    return WallpaperDestination(display: lookup("directDisplayID", in: target) as? UInt32 ?? 0,
                                size: size, scale: lookup("scaleFactor", in: target) as? CGFloat ?? 1,
                                preview: lookup("isPreview", in: request) as? Bool ?? preview)
}

final class WallpaperXPCHandler: NSObject, WallpaperExtensionXPCProtocol {
    // 交给系统合成的远程壁纸上下文只包含该屏背景和画中画，喵~
    func acquire(withId id: Any?, request: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void) {
        guard let id = findID(id), let target = destination(from: request) else {
            reply(nil, NSError(domain: NativeWallpaper.provider, code: 1))
            return
        }
        DispatchQueue.main.async {
            let renderer = WallpaperRenderer.shared
            guard let surface = renderer.acquire(id, destination: target),
                  let context = createRemoteContextXPC(contextId: surface.context.contextId) else {
                renderer.release(id)
                reply(nil, NSError(domain: NativeWallpaper.provider, code: 2))
                return
            }
            CATransaction.flush()
            extensionLog("acquire display=\(target.display) size=\(Int(target.size.width))x\(Int(target.size.height)) preview=\(target.preview)")
            reply(context, nil)
        }
    }

    // 响应系统几何变化，锁屏状态仍由真实会话判定，喵~
    func update(withId id: Any?, request: Any?, reply: @escaping @Sendable (Error?) -> Void) {
        let id = findID(id)
        let target = destination(from: request)
        DispatchQueue.main.async {
            if let id, let target { WallpaperRenderer.shared.resize(id, destination: target) }
            reply(nil)
        }
    }

    // WallpaperAgent 撤销某屏壁纸时立即释放对应图层，喵~
    func invalidate(withId id: Any?, reply: @escaping @Sendable (Error?) -> Void) {
        let id = findID(id)
        DispatchQueue.main.async {
            if let id { WallpaperRenderer.shared.release(id) }
            reply(nil)
        }
    }

    // 切换场景时的静态快照只使用系统壁纸副本，喵~
    func snapshot(withId id: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void) {
        let id = findID(id)
        DispatchQueue.main.async { reply(WallpaperRenderer.shared.snapshot(id).flatMap(wallpaperSnapshot), nil) }
    }

    // 由系统设置主动读取选择项，喵~
    func provideSettingsViewModels(withContentTypes _: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void) {
        reply(buildWallpaperCatalog(), nil)
    }

    // 固定的本机选项没有下载、迁移或自定义菜单操作，喵~
    func addChoiceRequest(withChoiceRequest _: Any?, onBehalfOfProcess _: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void) { reply(nil, nil) }
    func removeChoiceRequest(withChoiceRequest _: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func selectedChoicesDidChange(for _: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func invokeContextMenuAction(withMenuItemID _: Any?, groupItemID _: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func isChoiceDownloaded(with _: Any?, reply: @escaping @Sendable (NSNumber?, Error?) -> Void) { reply(NSNumber(value: true), nil) }
    func download(withChoiceID _: Any?, reply: (Error?) -> Void) -> Any? { reply(nil); return nil }
    func pauseDownload(for _: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func cancelDownload(for _: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func resumeDownload(for _: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func removeDownload(for _: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func migrateSelectedChoice(for _: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void) { reply(nil, nil) }
    func migrate(from _: Any?, to _: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func skipShuffledContent(withId _: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
    func canSkipShuffledContent(withId _: Any?, reply: @escaping @Sendable (Bool, Error?) -> Void) { reply(false, nil) }
    func handleDebugRequest(for _: Any?, reply: @escaping @Sendable (Any?, Error?) -> Void) { reply(nil, nil) }
    func handleNotification(withNamed _: Any?, reply: @escaping @Sendable (Error?) -> Void) { reply(nil) }
}
