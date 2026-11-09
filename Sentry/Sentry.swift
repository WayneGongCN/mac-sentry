import AppKit
import AVFoundation
import AVFAudio
import IOKit.pwr_mgt
import OSLog
import SwiftUI

final class Sentry: NSObject, ObservableObject {
    static let shared = Sentry()
    let capture = CapturePipeline()
    @Published private(set) var isMonitoring = false
    @Published private(set) var isAlrming = false
    @Published private(set) var cameraIssue: String?
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var media = SentryMedia()
    @Published private(set) var lastEvent = "等待下一次锁屏"
    @Published private(set) var alarmReason = "检测到人脸"
    @Published var automaticEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticEnabled, forKey: "automaticEnabled")
            if !automaticEnabled { stop(reason: "已关闭自动守卫") }
        }
    }
    var configuration = SentryConfiguration()
    private var presence = FacePresence()
    private let overlay = SentryOverlay()
    private var lockState = LockState()
    private var powerAssertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isSleeping = false
    private var isTerminating = false
    private var isDisplaySleeping = false
    private var deviceAlarm = false
    private var lastFrame: TimeInterval = 0
    private var startedAt: TimeInterval = 0
    private var lastRecovery: TimeInterval = 0
    private var lastLid: Bool?
    private var lastNetwork: Bool?
    private var lastPower: Bool?
    private var lastCleanup = Date.distantPast
    private var player: AVAudioPlayer?
    private let logger = Logger(subsystem: "com.waynegong.MacSentry", category: "sentry")

    // 让守卫控制器独立于窗口生命周期常驻，喵~
    override init() {
        automaticEnabled = UserDefaults.standard.object(forKey: "automaticEnabled") as? Bool ?? true
        super.init()
        capture.onDetection = { [weak self] confidence, time in self?.accept(confidence: confidence, at: time) }
        capture.onCameraIssue = { [weak self] message in
            guard let self, self.isMonitoring else { return }
            self.cameraIssue = message
            self.presence.reset()
            self.capture.endEvent()
            self.refreshAlarm()
        }
        capture.onRecordingState = { [weak self] state in self?.recordingState = state }
    }

    // 注册睡眠恢复通知和锁屏轮询，应用关窗后仍可再次布防，喵~
    func launch() {
        guard timer == nil else { return }
        SentryMediaStore.shared.removeUnusedFiles(keeping: SentryConfigurationManager.shared.cfg.mediaReferences)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.refreshOverlay()
        })
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isSleeping = true
            self?.stop(reason: "系统即将睡眠")
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isSleeping = false
            self?.tick()
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isDisplaySleeping = true
            self?.stop(reason: "屏幕已熄灭")
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isDisplaySleeping = false
            self?.tick()
        })
        let notifications = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(notifications.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.lockState.receive(locked: locked)
                if locked { self.tick() }
                else { self.stop(reason: "收到系统解锁通知") }
            })
        }
        let watcher = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(watcher, forMode: .common)
        timer = watcher
        capture.clean()
        tick()
    }

    // 根据实际锁定状态启停守卫，并处理尾录、采集故障和电源变化，喵~
    private func tick() {
        guard !isTerminating, !isSleeping, !isDisplaySleeping else { return }
        if let locked = lockState.update(probe: DeviceCheck.isMacLocked()) {
            if locked && automaticEnabled && !isMonitoring && SentryConfigurationManager.shared.canActivate { run() }
            if !locked && (isMonitoring || overlay.isPresented) { stop(reason: "会话轮询已解锁") }
        }
        if Date().timeIntervalSince(lastCleanup) >= 60 {
            lastCleanup = Date()
            capture.clean()
        }
        guard isMonitoring else { return }
        setPowerHold(DeviceCheck.isConnectedToPower())
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastFrame > 3 {
            cameraIssue = "摄像头未返回画面，检测暂停"
            presence.reset()
            capture.endEvent()
            if now - lastRecovery >= 10 {
                lastRecovery = now
                capture.recover()
            }
        } else {
            let wasActive = presence.isActive
            presence.expire(at: now)
            if wasActive && !presence.isActive {
                logger.notice("人脸事件结束，恢复守卫")
                capture.endEvent()
            }
        }
        checkDeviceTriggers()
        refreshAlarm()
    }

    // 每次锁屏以当前配置创建被动展示窗口和摄像头会话，喵~
    private func run() {
        configuration = SentryConfigurationManager.shared.cfg
        media = SentryMediaStore.shared.load(configuration)
        isMonitoring = true
        logger.notice("守卫开始")
        cameraIssue = "正在启动摄像头"
        lastFrame = ProcessInfo.processInfo.systemUptime
        startedAt = lastFrame
        lastLid = DeviceCheck.isMacLidClosed()
        lastNetwork = DeviceCheck.isConnectedToWirelessNetwork()
        lastPower = DeviceCheck.isConnectedToPower()
        lastEvent = "本次守卫开始于 \(Date().formatted(date: .omitted, time: .standard))"
        refreshOverlay()
        setPowerHold(DeviceCheck.isConnectedToPower())
        capture.start(detectionEnabled: configuration.sentryTriggersHumanEnabled, useOwnerReference: true)
    }

    // 显示器变化时只重建展示窗口，检测、告警、播放器与录像继续运行，喵~
    private func refreshOverlay() {
        guard isMonitoring, !isSleeping, !isDisplaySleeping, !isTerminating else { return }
        overlay.present(on: NSScreen.screens) { reservesUnlockArea in
            AnyView(SentryView(sentry: self, reservesUnlockArea: reservesUnlockArea))
        }
    }

    // 成功解锁或暂停时释放窗口和电源占用，并等待录像自行收尾，喵~
    func stop(reason: String = "手动停止") {
        let hadSession = isMonitoring || overlay.isPresented
        overlay.dismiss()
        capture.stop()
        setPowerHold(false)
        isMonitoring = false
        if hadSession { logger.notice("守卫结束：\(reason, privacy: .public)，顶层窗口已拆除") }
        isAlrming = false
        deviceAlarm = false
        presence.reset()
        player?.stop()
        player = nil
        media = SentryMedia()
        cameraIssue = nil
        lastEvent = "上次守卫已结束，等待下一次锁屏"
    }

    // 退出进程前停止后续布防，避免文件收尾期间再次创建顶层窗口，喵~
    func shutdown() {
        isTerminating = true
        timer?.invalidate()
        timer = nil
        stop(reason: "退出应用")
    }

    // 桌面模拟告警与解除，以零音量验证循环和停止，并检查所有窗口无残留，喵~
    func verifyStopOnDesktop(warning: Bool, completion: @escaping ([String: Any]) -> Void) {
        let screens = NSScreen.screens
        guard !isMonitoring, !screens.isEmpty else { completion(["passed": false]); return }
        isMonitoring = true
        configuration = SentryConfigurationManager.shared.cfg
        configuration.sentryAlarmsSoundsEnabled = true
        configuration.sentryAlarmsSoundVolume = 0
        configuration.sentryAlarmsNotificationType = .none
        alarmReason = "界面退出自检（不采集摄像头）"
        media = SentryMediaStore.shared.load(configuration)
        if warning {
            for time in [0.0, 0.34, 0.68] { presence.ingest(confidence: 0.9, at: time) }
        }
        refreshAlarm()
        refreshOverlay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            let numbers = overlay.windowNumbers
            let frames = overlay.windowFrames
            let before = numbers.map { windowIsOnscreen($0) }
            let appKitBefore = overlay.isVisible
            let soundMatchesState = warning ? player?.isPlaying == true && player?.numberOfLoops == -1 : player == nil
            let framesMatch = frames == screens.map(\.frame)
            let displays: [[String: Any]] = screens.enumerated().map { index, screen in
                ["display": screen.localizedName, "x": screen.frame.minX, "y": screen.frame.minY,
                 "width": screen.frame.width, "height": screen.frame.height,
                 "unlockAreaFraction": index == 0 ? 0.30 : 0,
                 "windowNumber": numbers.indices.contains(index) ? numbers[index] : 0]
            }
            presence.reset()
            refreshAlarm()
            let soundStoppedAfterAlarm = player == nil && !isAlrming
            lockState.receive(locked: false)
            stop(reason: "解锁回归自检")
            stop(reason: "重复停止回归自检")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                let after = numbers.map { windowIsOnscreen($0) }
                completion(["shownBefore": before, "visibleAfter": after, "warning": warning,
                            "displays": displays, "framesMatch": framesMatch, "appKitVisibleBefore": appKitBefore,
                            "soundMatchesState": soundMatchesState, "soundStoppedAfterAlarm": soundStoppedAfterAlarm,
                            "windowReferenceReleased": !overlay.isPresented,
                            "monitoringAfter": isMonitoring, "sessionRunningAfter": capture.session.isRunning,
                            "passed": numbers.count == screens.count && framesMatch && appKitBefore
                                && soundMatchesState && soundStoppedAfterAlarm && player == nil
                                && before.allSatisfy { $0 } && after.allSatisfy { !$0 }
                                && !overlay.isPresented && !isMonitoring && !capture.session.isRunning])
            }
        }
    }

    // 只读取本应用已知窗口的可见性元数据，不截取屏幕内容，喵~
    private func windowIsOnscreen(_ number: Int) -> Bool {
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
        return windows?.contains(where: {
            ($0[kCGWindowNumber as String] as? Int) == number && ($0[kCGWindowIsOnscreen as String] as? Bool) == true
        }) == true
    }

    // 在主线程确认连续帧结果，人脸事件结束时只停止文件写入，喵~
    private func accept(confidence: Float, at time: TimeInterval) {
        guard isMonitoring, !isSleeping, time >= startedAt else { return }
        guard lockState.update(probe: DeviceCheck.isMacLocked()) == true else {
            stop(reason: "视频帧回调确认已解锁")
            return
        }
        lastFrame = time
        cameraIssue = nil
        let previous = presence.isActive
        if configuration.sentryTriggersHumanEnabled { presence.ingest(confidence: confidence, at: time) }
        if presence.isActive && !previous {
            logger.notice("人脸已确认，开始人脸事件")
            if !deviceAlarm { alarmReason = "检测到人脸" }
            lastEvent = "人脸事件 · \(Date().formatted(date: .omitted, time: .standard))"
            if configuration.sentryRecordingEnabled { capture.beginEvent() }
        } else if previous && !presence.isActive {
            logger.notice("人脸事件结束，恢复守卫")
            capture.endEvent()
        }
        refreshAlarm()
    }

    // 合格人脸消失后恢复守卫，设备触发告警保持到解锁，喵~
    private func refreshAlarm() {
        let active = deviceAlarm || presence.isActive
        if active && !isAlrming { fireOptionalActions() }
        if !active && isAlrming {
            player?.stop()
            player = nil
            capture.endEvent()
        }
        isAlrming = active
    }

    // 保留上游的合盖、断网、拔电源三个可选触发条件，喵~
    private func checkDeviceTriggers() {
        let lid = DeviceCheck.isMacLidClosed()
        let network = DeviceCheck.isConnectedToWirelessNetwork()
        let power = DeviceCheck.isConnectedToPower()
        if configuration.sentryTriggersLidEnabled && lastLid == false && lid == true {
            deviceAlarm = true; alarmReason = "检测到合盖操作"
        }
        if configuration.sentryTriggersInternetEnabled && lastNetwork == true && !network {
            deviceAlarm = true; alarmReason = "检测到网络断开"
        }
        if configuration.sentryTriggersPowerEnabled && lastPower == true && !power {
            deviceAlarm = true; alarmReason = "检测到电源断开"
        }
        lastLid = lid; lastNetwork = network; lastPower = power
    }

    // 仅执行用户主动开启的声音或推送选项，默认仅展示视觉警告，喵~
    private func fireOptionalActions() {
        if configuration.sentryAlarmsSoundsEnabled {
            if let url = media.alarmSound { player = try? AVAudioPlayer(contentsOf: url) }
            if player == nil, let fallback = Bundle.main.url(forResource: "alarm", withExtension: "mp3") {
                player = try? AVAudioPlayer(contentsOf: fallback)
                media.reportIssue("告警声音不可用，已使用内置告警音。")
            }
            player?.volume = Float(configuration.sentryAlarmsSoundVolume)
            player?.numberOfLoops = -1
            if player?.play() != true { media.reportIssue("无法播放告警声音，请检查音频输出设备。") }
        }
        if configuration.sentryAlarmsNotificationType == .bark,
           let endpoint = URL(string: configuration.sentryNotificationConfigBark.endpoint), endpoint.scheme == "https" {
            let url = endpoint.appendingPathComponent("Mac 哨兵").appendingPathComponent(alarmReason)
            URLSession.shared.dataTask(with: url).resume()
        }
    }

    // 仅在接电守卫期间持有应用级亮屏断言，不改全局睡眠设置，喵~
    private func setPowerHold(_ enabled: Bool) {
        if enabled && powerAssertion == 0 {
            let status = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Mac 哨兵正在接电守卫" as CFString, &powerAssertion)
            if status != kIOReturnSuccess { powerAssertion = 0 }
        } else if !enabled && powerAssertion != 0 {
            IOPMAssertionRelease(powerAssertion)
            powerAssertion = 0
        }
    }
}

final class PassiveSentryPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
