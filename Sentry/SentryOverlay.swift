import AppKit
import SkyLightWindow
import SwiftUI

final class SentryOverlay {
    private var panel: PassiveSentryPanel?
    var isPresented: Bool { panel != nil }
    var isVisible: Bool { panel?.isVisible == true }
    var windowNumber: Int? { panel?.windowNumber }

    // 为当前守卫创建一个不抢焦点的窗口，并复用上游的专用显示空间，喵~
    func present(_ content: AnyView, on screen: NSScreen) {
        dismiss()
        let window = PassiveSentryPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        window.title = "MacSentry 哨兵界面"
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
        window.contentView = NSHostingView(rootView: content)
        let manager = SkyLightOperator.shared
        manager.delegateWindow(window)
        window.orderFrontRegardless()
        panel = window
    }

    // 先清空窗口画面，再拆除预览与窗口，重复调用也能清理残留画面，喵~
    func dismiss() {
        guard let window = panel else { return }
        window.alphaValue = 0
        window.orderOut(nil)
        CATransaction.flush()
        window.contentView = nil
        window.level = .normal
        window.close()
        panel = nil
    }

}
