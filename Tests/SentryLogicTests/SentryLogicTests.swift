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
        var state = HumanPresence()
        state.ingest(confidence: 0.9, at: 0)
        state.ingest(confidence: 0.4, at: 0.34)
        state.ingest(confidence: 0.9, at: 0.68)
        state.ingest(confidence: 0.9, at: 1.02)
        XCTAssertFalse(state.isActive)
        state.ingest(confidence: 0.65, at: 1.36)
        XCTAssertTrue(state.isActive)
    }

    // 尾录期内再次看到人员应延长同一事件，喵~
    func testTailExtendsAndRearms() {
        var state = HumanPresence()
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
        var state = HumanPresence()
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

    // 读取旧版本配置时补齐人形开关且保留用户明确关闭的录像选项，喵~
    func testConfigurationMigrationAndRoundTrip() throws {
        let old = Data(#"{"sentryTriggersLidEnabled":true,"sentryRecordingEnabled":false}"#.utf8)
        var config = try JSONDecoder().decode(SentryConfiguration.self, from: old)
        XCTAssertTrue(config.sentryTriggersHumanEnabled)
        XCTAssertTrue(config.sentryTriggersLidEnabled)
        XCTAssertFalse(config.sentryRecordingEnabled)
        XCTAssertEqual(SentryConfiguration().sentryAlarmsSoundVolume, 0.1)
        XCTAssertEqual(config.sentryAlarmsSoundVolume, 0.1)
        config.sentryAlarmsSoundVolume = 0.35
        XCTAssertEqual(try JSONDecoder().decode(SentryConfiguration.self, from: JSONEncoder().encode(config)), config)
    }

    // 为清理策略构造无真实文件副作用的片段描述，喵~
    private func entry(_ name: String, age: TimeInterval, bytes: Int64, now: Date) -> RecordingEntry {
        RecordingEntry(url: URL(fileURLWithPath: "/clips/\(name).mov"), modified: now.addingTimeInterval(-age), bytes: bytes)
    }
}
