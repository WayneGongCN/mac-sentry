import AppKit
import SkyLightWindow
import SwiftUI

final class SentryOverlay {
    private var panels: [PassiveSentryPanel] = []
    var isPresented: Bool { !panels.isEmpty }
    var isVisible: Bool { !panels.isEmpty && panels.allSatisfy(\.isVisible) }
    var windowNumbers: [Int] { panels.map(\.windowNumber) }
    var windowFrames: [CGRect] { panels.map(\.frame) }

    // 每屏建立独立的被动窗口，仅系统主显示器预留解锁区域，喵~
    func present(on screens: [NSScreen], content: (_ reservesUnlockArea: Bool) -> AnyView) {
        dismiss()
        for (index, screen) in screens.enumerated() {
            let window = PassiveSentryPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            window.title = "MacSentry 哨兵界面 · \(screen.localizedName)"
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.ignoresMouseEvents = true
            window.animationBehavior = .none
            window.canBecomeVisibleWithoutLogin = true
            window.level = NSWindow.Level(rawValue: Int(Int32.max - 2))
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: content(index == 0))
            SkyLightOperator.shared.delegateWindow(window)
            window.orderFrontRegardless()
            panels.append(window)
        }
    }

    // 先清空窗口画面，再拆除预览与窗口，重复调用也能清理残留画面，喵~
    func dismiss() {
        for window in panels {
            window.alphaValue = 0
            window.orderOut(nil)
        }
        CATransaction.flush()
        for window in panels {
            window.contentView = nil
            window.level = .normal
            window.close()
        }
        panels.removeAll()
    }

}
