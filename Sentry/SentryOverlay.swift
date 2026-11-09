import AppKit
import SwiftUI

final class SentryOverlay {
    private var panels: [PassiveSentryPanel] = []
    var isPresented: Bool { !panels.isEmpty }
    var isVisible: Bool { !panels.isEmpty && panels.allSatisfy(\.isVisible) }
    var windowNumbers: [Int] { panels.map(\.windowNumber) }
    var windowFrames: [CGRect] { panels.map(\.frame) }

    // 桌面回归自检为每屏建立被动窗口，实际锁屏由系统壁纸扩展负责，喵~
    func present<Content: View>(on screens: [NSScreen], content: () -> Content) {
        dismiss()
        for screen in screens {
            let window = PassiveSentryPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                           backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.title = "MacSentry 壁纸 · \(screen.localizedName)"
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.ignoresMouseEvents = true
            window.animationBehavior = .none
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = NSHostingView(rootView: content())
            panels.append(window)
            window.orderFrontRegardless()
        }
    }

    // 先隐藏全部画面，再拆除窗口及摄像头预览图层，喵~
    func dismiss() {
        for window in panels {
            window.alphaValue = 0
            window.orderOut(nil)
        }
        CATransaction.flush()
        for window in panels {
            window.contentView = nil
            window.close()
        }
        panels.removeAll()
    }
}
