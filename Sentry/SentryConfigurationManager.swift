import Foundation
import SwiftUI

class SentryConfigurationManager: ObservableObject {
    static let shared = SentryConfigurationManager()
    private init() {}

    @PublishedPersist(key: "sentry.config", defaultValue: .init())
    var cfg: SentryConfiguration

    var hasTriggerEnabled: Bool {
        cfg.sentryTriggersHumanEnabled || cfg.sentryTriggersLidEnabled
            || cfg.sentryTriggersInternetEnabled || cfg.sentryTriggersPowerEnabled
    }
    var hasNotificationEnabled: Bool { true }
    var hasRecordingEnabled: Bool { cfg.sentryRecordingEnabled }
    var canActivate: Bool { hasTriggerEnabled }
}
