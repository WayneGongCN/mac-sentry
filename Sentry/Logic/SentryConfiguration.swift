import Foundation

struct SentryConfiguration: Codable, Equatable, Hashable {
    // 沿用旧人形开关的存储键，保留用户明确关闭检测的选择，喵~
    var sentryTriggersHumanEnabled = true
    var sentryTriggersLidEnabled = false
    var sentryTriggersInternetEnabled = false
    var sentryTriggersPowerEnabled = false
    var sentryAlarmsSoundsEnabled = false
    var sentryAlarmsSoundVolume = 0.1
    var sentryAlarmsNotificationType: NotificationType = .none
    var sentryNotificationConfigBark = NotificationConfiguration_Bark()
    var sentryRecordingEnabled = true
    var sentryGuardingImage: String?
    var sentryAlarmImage: String?
    var sentryAlarmSound: String?

    var mediaReferences: Set<String> {
        Set([sentryGuardingImage, sentryAlarmImage, sentryAlarmSound].compactMap { $0 })
    }

    enum NotificationType: String, Codable { case none, bark }
    struct NotificationConfiguration_Bark: Codable, Equatable, Hashable { var endpoint = "https://" }
    enum CodingKeys: String, CodingKey {
        case sentryTriggersHumanEnabled, sentryTriggersLidEnabled, sentryTriggersInternetEnabled
        case sentryTriggersPowerEnabled, sentryAlarmsSoundsEnabled, sentryAlarmsSoundVolume, sentryAlarmsNotificationType
        case sentryNotificationConfigBark, sentryRecordingEnabled
        case sentryGuardingImage, sentryAlarmImage, sentryAlarmSound
    }

    // 创建保持现有视觉效果且默认静音的配置，喵~
    init() {}

    // 新增字段缺失时使用默认值，保留旧配置中的设备触发与通知选项，喵~
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sentryTriggersHumanEnabled = try c.decodeIfPresent(Bool.self, forKey: .sentryTriggersHumanEnabled) ?? true
        sentryTriggersLidEnabled = try c.decodeIfPresent(Bool.self, forKey: .sentryTriggersLidEnabled) ?? false
        sentryTriggersInternetEnabled = try c.decodeIfPresent(Bool.self, forKey: .sentryTriggersInternetEnabled) ?? false
        sentryTriggersPowerEnabled = try c.decodeIfPresent(Bool.self, forKey: .sentryTriggersPowerEnabled) ?? false
        sentryAlarmsSoundsEnabled = try c.decodeIfPresent(Bool.self, forKey: .sentryAlarmsSoundsEnabled) ?? false
        sentryAlarmsSoundVolume = min(1, max(0, try c.decodeIfPresent(Double.self, forKey: .sentryAlarmsSoundVolume) ?? 0.1))
        sentryAlarmsNotificationType = try c.decodeIfPresent(NotificationType.self, forKey: .sentryAlarmsNotificationType) ?? .none
        sentryNotificationConfigBark = try c.decodeIfPresent(NotificationConfiguration_Bark.self, forKey: .sentryNotificationConfigBark) ?? .init()
        sentryRecordingEnabled = try c.decodeIfPresent(Bool.self, forKey: .sentryRecordingEnabled) ?? true
        sentryGuardingImage = try c.decodeIfPresent(String.self, forKey: .sentryGuardingImage)
        sentryAlarmImage = try c.decodeIfPresent(String.self, forKey: .sentryAlarmImage)
        sentryAlarmSound = try c.decodeIfPresent(String.self, forKey: .sentryAlarmSound)
    }
}
