import XCTest
@testable import SentryLogic

final class SentryLogicTests: XCTestCase {
    // 解锁通知必须立即覆盖旧锁定快照，并阻止轮询再次错误布防，喵~
    func testUnlockNotificationOverridesStaleProbe() {
        var state = LockState()
        state.update(probe: true)
        state.receive(locked: false)
        XCTAssertEqual(state.update(probe: true), false)
        XCTAssertEqual(state.update(probe: nil), false)
        XCTAssertEqual(state.update(probe: false), false)
        XCTAssertEqual(state.update(probe: true), true)
    }

    // 快速重复锁屏时，新通知应取代尚未追平的上一次状态，喵~
    func testRapidLockUnlockNotifications() {
        var state = LockState()
        state.receive(locked: true)
        XCTAssertEqual(state.update(probe: false), true)
        state.receive(locked: false)
        XCTAssertEqual(state.update(probe: true), false)
        state.receive(locked: true)
        XCTAssertEqual(state.update(probe: true), true)
        state.receive(locked: false)
        XCTAssertEqual(state.update(probe: false), false)
    }

    // 启动时没有锁定证据不能布防，丢失通知时仍可通过快照退出，喵~
    func testPollingFallbackAndUnknownStartup() {
        var state = LockState()
        XCTAssertNil(state.update(probe: nil))
        XCTAssertEqual(state.update(probe: true), true)
        XCTAssertEqual(state.update(probe: false), false)
    }

    // 单帧误检和不连续结果不应触发告警，喵~
    func testRequiresThreeConsecutiveFrames() {
        var state = FacePresence()
        state.ingest(confidence: 0.9, at: 0)
        state.ingest(confidence: 0.4, at: 0.34)
        state.ingest(confidence: 0.9, at: 0.68)
        state.ingest(confidence: 0.9, at: 1.02)
        XCTAssertFalse(state.isActive)
        state.ingest(confidence: 0.65, at: 1.36)
        XCTAssertTrue(state.isActive)
    }

    // 尾录期内再次看到合格人脸应延长同一事件，喵~
    func testTailExtendsAndRearms() {
        var state = FacePresence()
        for time in [0.0, 0.34, 0.68] { state.ingest(confidence: 0.9, at: time) }
        state.expire(at: 10.67)
        XCTAssertTrue(state.isActive)
        state.ingest(confidence: 0.9, at: 10.67)
        state.expire(at: 20.66)
        XCTAssertTrue(state.isActive)
        state.expire(at: 20.67)
        XCTAssertFalse(state.isActive)
        for time in [21.0, 21.34, 21.68] { state.ingest(confidence: 0.9, at: time) }
        XCTAssertTrue(state.isActive)
        state.reset()
        XCTAssertFalse(state.isActive)
        state.ingest(confidence: 0.9, at: 22)
        XCTAssertFalse(state.isActive)
    }

    // 摄像头长时间中断后不能沿用中断前的确认帧，喵~
    func testFrameGapBreaksConfirmation() {
        var state = FacePresence()
        state.ingest(confidence: 0.9, at: 0)
        state.ingest(confidence: 0.9, at: 0.34)
        state.ingest(confidence: 0.9, at: 3)
        XCTAssertFalse(state.isActive)
    }

    // 期限清理应保留正在写入的文件并保留未过期片段，喵~
    func testAgeCleanupProtectsPendingFiles() {
        let now = Date(timeIntervalSince1970: 100_000)
        let old = entry("old", age: 86_400, bytes: 100, now: now)
        let recent = entry("recent", age: 10, bytes: 100, now: now)
        let pending = entry("pending", age: 90_000, bytes: 100, now: now)
        let removed = RecordingRetention.removals(from: [recent, pending, old], protected: [pending.url], now: now)
        XCTAssertEqual(removed, [old.url])
    }

    // 超额清理按时间从旧到新进行，受保护片段仍计入总量，喵~
    func testSizeCleanupCountsProtectedFiles() {
        let now = Date()
        let a = entry("a", age: 30, bytes: 60, now: now)
        let b = entry("b", age: 20, bytes: 60, now: now)
        let c = entry("c", age: 10, bytes: 60, now: now)
        XCTAssertEqual(RecordingRetention.removals(from: [c, a, b], protected: [c.url], now: now, limit: 120), [a.url])
        XCTAssertEqual(RecordingRetention.removals(from: [a, b, c], protected: [a.url, c.url], now: now, limit: 100), [b.url])
    }

    // 恰好达到空间上限时不删除仍未过期的录像，喵~
    func testExactSizeBoundary() {
        let now = Date()
        let a = entry("a", age: 0, bytes: 100, now: now)
        XCTAssertTrue(RecordingRetention.removals(from: [a], protected: [], now: now, limit: 100).isEmpty)
    }

    // 读取旧版本配置时补齐人脸开关且保留用户明确关闭的录像选项，喵~
    func testConfigurationMigrationAndRoundTrip() throws {
        let old = Data(#"{"sentryTriggersLidEnabled":true,"sentryRecordingEnabled":false}"#.utf8)
        var config = try JSONDecoder().decode(SentryConfiguration.self, from: old)
        XCTAssertTrue(config.sentryTriggersHumanEnabled)
        XCTAssertTrue(config.sentryTriggersLidEnabled)
        XCTAssertFalse(config.sentryRecordingEnabled)
        XCTAssertEqual(SentryConfiguration().sentryAlarmsSoundVolume, 0.1)
        XCTAssertEqual(config.sentryAlarmsSoundVolume, 0.1)
        XCTAssertNil(config.sentryGuardingImage)
        XCTAssertNil(config.sentryAlarmImage)
        XCTAssertNil(config.sentryAlarmSound)
        config.sentryAlarmsSoundVolume = 0.35
        config.sentryGuardingImage = "guarding.png"
        config.sentryAlarmImage = "warning.heic"
        config.sentryAlarmSound = "alarm.wav"
        XCTAssertEqual(try JSONDecoder().decode(SentryConfiguration.self, from: JSONEncoder().encode(config)), config)
    }

    // 关闭检测与声音的旧配置在迁移后必须继续保持关闭，喵~
    func testMigrationPreservesDisabledDetectionAndSound() throws {
        let data = Data(#"{"sentryTriggersHumanEnabled":false,"sentryAlarmsSoundsEnabled":false,"sentryAlarmsSoundVolume":0.24}"#.utf8)
        let config = try JSONDecoder().decode(SentryConfiguration.self, from: data)
        XCTAssertFalse(config.sentryTriggersHumanEnabled)
        XCTAssertFalse(config.sentryAlarmsSoundsEnabled)
        XCTAssertEqual(config.sentryAlarmsSoundVolume, 0.24)
        XCTAssertTrue(config.mediaReferences.isEmpty)
    }

    // 中央区域包含边界，边带中的高置信度人脸不能触发或遮蔽中央有效结果，喵~
    func testFaceCentersAndMultipleFaces() {
        for center in [CGPoint(x: 0.15, y: 0.5), CGPoint(x: 0.85, y: 0.5),
                       CGPoint(x: 0.5, y: 0.15), CGPoint(x: 0.5, y: 0.85)] {
            XCTAssertEqual(FaceFilter.confidence(in: [face(center: center)]), 0.9)
        }
        for center in [CGPoint(x: 0.149, y: 0.5), CGPoint(x: 0.851, y: 0.5),
                       CGPoint(x: 0.5, y: 0.149), CGPoint(x: 0.5, y: 0.851)] {
            let edge = face(center: center, confidence: 0.99)
            XCTAssertEqual(FaceFilter.confidence(in: [edge]), 0)
            XCTAssertEqual(FaceFilter.confidence(in: [edge, face(confidence: 0.7)]), 0.7)
        }
        XCTAssertEqual(FaceFilter.confidence(in: []), 0)
        XCTAssertEqual(FaceFilter.confidence(in: [face(confidence: 0.7), face(confidence: 0.95)]), 0.95)
    }

    // 尺寸门槛包含边界，越界、过小及非有限坐标不能成为有效检测结果，喵~
    func testFaceSizeAndFrameBounds() {
        XCTAssertEqual(FaceFilter.confidence(in: [face(size: CGSize(width: 0.10, height: 0.10))]), 0.9)
        for size in [CGSize(width: 0.099, height: 0.2), CGSize(width: 0.2, height: 0.099)] {
            XCTAssertEqual(FaceFilter.confidence(in: [face(size: size)]), 0)
        }
        for box in [CGRect(x: -0.01, y: 0.3, width: 0.4, height: 0.4),
                    CGRect(x: 0.3, y: -0.01, width: 0.4, height: 0.4),
                    CGRect(x: 0.61, y: 0.3, width: 0.4, height: 0.4),
                    CGRect(x: 0.3, y: 0.61, width: 0.4, height: 0.4),
                    CGRect(x: CGFloat.nan, y: 0.3, width: 0.4, height: 0.4)] {
            XCTAssertEqual(FaceFilter.confidence(in: [FaceCandidate(boundingBox: box, confidence: 0.99)]), 0)
        }
        XCTAssertEqual(FaceFilter.confidence(in: [face(confidence: .nan)]), 0)
        XCTAssertEqual(FaceFilter.confidence(in: [FaceCandidate(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 0.9)]), 0.9)
    }

    // 几何条件通过仍需要达到置信度门槛并连续确认，喵~
    func testFaceFilterFeedsTemporalConfirmation() {
        var presence = FacePresence()
        for time in [0.0, 0.34, 0.68] {
            presence.ingest(confidence: FaceFilter.confidence(in: [face(confidence: 0.64)]), at: time)
        }
        XCTAssertFalse(presence.isActive)
        for time in [1.02, 1.36, 1.70] {
            presence.ingest(confidence: FaceFilter.confidence(in: [face(confidence: 0.65)]), at: time)
        }
        XCTAssertTrue(presence.isActive)
        presence.ingest(confidence: FaceFilter.confidence(in: [face(center: CGPoint(x: 0.1, y: 0.5))]), at: 11.69)
        XCTAssertTrue(presence.isActive)
        presence.expire(at: 11.70)
        XCTAssertFalse(presence.isActive)
    }

    // 生成归一化人脸框以验证过滤策略，不依赖摄像头或 Vision 模型，喵~
    private func face(center: CGPoint = CGPoint(x: 0.5, y: 0.5), size: CGSize = CGSize(width: 0.2, height: 0.2),
                      confidence: Float = 0.9) -> FaceCandidate {
        FaceCandidate(boundingBox: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                         width: size.width, height: size.height), confidence: confidence)
    }

    // 为清理策略构造无真实文件副作用的片段描述，喵~
    private func entry(_ name: String, age: TimeInterval, bytes: Int64, now: Date) -> RecordingEntry {
        RecordingEntry(url: URL(fileURLWithPath: "/clips/\(name).mov"), modified: now.addingTimeInterval(-age), bytes: bytes)
    }
}
