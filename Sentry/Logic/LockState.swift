import Foundation

struct LockState {
    private(set) var isLocked: Bool?
    private var pendingNotification: Bool?

    // 系统通知优先于可能滞后的会话快照，解锁后等待快照追平再接受轮询变化，喵~
    mutating func receive(locked: Bool) {
        isLocked = locked
        pendingNotification = locked
    }

    // 轮询作为启动和丢失通知时的补充，不让旧快照撤销刚收到的解锁通知，喵~
    @discardableResult
    mutating func update(probe: Bool?) -> Bool? {
        guard let probe else { return isLocked }
        if let pendingNotification {
            if probe == pendingNotification { self.pendingNotification = nil }
        } else { isLocked = probe }
        return isLocked
    }
}
