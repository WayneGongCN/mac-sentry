import Foundation

struct FacePresence {
    var threshold: Float = 0.65
    var requiredFrames = 3
    var tailDuration: TimeInterval = 10
    private(set) var isActive = false
    private var consecutiveFrames = 0
    private var lastFrame: TimeInterval?
    private var lastSeen: TimeInterval?

    // 连续有效帧确认人脸出现，短暂丢帧不结束正在进行的事件，喵~
    mutating func ingest(confidence: Float, at time: TimeInterval) {
        expire(at: time)
        if let lastFrame, time - lastFrame > 1 { consecutiveFrames = 0 }
        lastFrame = time
        if confidence >= threshold {
            consecutiveFrames += 1
            if isActive || consecutiveFrames >= requiredFrames {
                isActive = true
                lastSeen = time
            }
        } else { consecutiveFrames = 0 }
        expire(at: time)
    }

    // 合格人脸消失达到尾录时间后解除事件，喵~
    mutating func expire(at time: TimeInterval) {
        if let lastSeen, time - lastSeen >= tailDuration {
            isActive = false
            consecutiveFrames = 0
            self.lastSeen = nil
        }
    }

    // 解锁或摄像头中断时清除确认历史，喵~
    mutating func reset() { self = FacePresence() }
}
