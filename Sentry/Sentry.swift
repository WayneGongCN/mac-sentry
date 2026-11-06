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
    @Published private(set) var lastEvent = "等待下一次锁屏"
    @Published private(set) var alarmReason = "检测到人员靠近"
    @Published var automaticEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automaticEnabled, forKey: "automaticEnabled")
            if !automaticEnabled { stop(reason: "已关闭自动守卫") }
        }
    }
    var configuration = SentryConfiguration()
    private var presence = HumanPresence()
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
                logger.notice("人员事件结束，恢复守卫")
                capture.endEvent()
            }
        }
        checkDeviceTriggers()
        refreshAlarm()
    }

    // 每次锁屏以当前配置创建被动展示窗口和摄像头会话，喵~
    private func run() {
        configuration = SentryConfigurationManager.shared.cfg
        isMonitoring = true
        logger.notice("守卫开始")
        cameraIssue = "正在启动摄像头"
        lastFrame = ProcessInfo.processInfo.systemUptime
        startedAt = lastFrame
        lastLid = DeviceCheck.isMacLidClosed()
        lastNetwork = DeviceCheck.isConnectedToWirelessNetwork()
        lastPower = DeviceCheck.isConnectedToPower()
        lastEvent = "本次守卫开始于 \(Date().formatted(date: .omitted, time: .standard))"
        if let screen = NSScreen.main {
            overlay.present(AnyView(SentryView(sentry: self)), on: screen)
        }
        setPowerHold(DeviceCheck.isConnectedToPower())
        capture.start(detectionEnabled: configuration.sentryTriggersHumanEnabled)
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

    // 在桌面模拟告警与重复解锁清理，验证窗口服务器中没有残留顶层画面，喵~
    func verifyStopOnDesktop(completion: @escaping ([String: Any]) -> Void) {
        guard !isMonitoring, let screen = NSScreen.main else { completion(["passed": false]); return }
        isMonitoring = true
        isAlrming = true
        alarmReason = "界面退出自检（不采集摄像头）"
        overlay.present(AnyView(SentryView(sentry: self)), on: screen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            let number = overlay.windowNumber ?? 0
            let before = windowIsOnscreen(number)
            let appKitBefore = overlay.isVisible
            lockState.receive(locked: false)
            stop(reason: "解锁回归自检")
            stop(reason: "重复停止回归自检")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                let after = windowIsOnscreen(number)
                completion(["shownBefore": before, "visibleAfter": after,
                            "windowNumber": number, "appKitVisibleBefore": appKitBefore,
                            "windowReferenceReleased": !overlay.isPresented,
                            "monitoringAfter": isMonitoring, "sessionRunningAfter": capture.session.isRunning,
                            "passed": before && !after && !isMonitoring && !capture.session.isRunning])
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

    // 在主线程确认连续帧结果，人员事件结束时只停止文件写入，喵~
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
            logger.notice("人形已确认，开始人员事件")
            alarmReason = "检测到人员靠近"
            lastEvent = "人员事件 · \(Date().formatted(date: .omitted, time: .standard))"
            if configuration.sentryRecordingEnabled { capture.beginEvent() }
        } else if previous && !presence.isActive {
            logger.notice("人员事件结束，恢复守卫")
            capture.endEvent()
        }
        refreshAlarm()
    }

    // 人员离开后恢复守卫，设备触发告警保持到解锁，喵~
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
        if configuration.sentryAlarmsSoundsEnabled, let url = Bundle.main.url(forResource: "alarm", withExtension: "mp3") {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.volume = Float(configuration.sentryAlarmsSoundVolume)
            player?.numberOfLoops = -1
            player?.play()
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
