import SwiftUI

struct SetupAlarmsView: View {
    @StateObject var vm = SentryConfigurationManager.shared
    var body: some View {
        FormView(title: "Setup Alarm Triggers", leftBottom: {}) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("检测人脸", isOn: $vm.cfg.sentryTriggersHumanEnabled)
                Toggle("Closing Lid", isOn: $vm.cfg.sentryTriggersLidEnabled)
                Toggle("Disconnected from Internet", isOn: $vm.cfg.sentryTriggersInternetEnabled)
                Toggle("Disconnected from Power Adapter", isOn: $vm.cfg.sentryTriggersPowerEnabled)
                Text("接电时保持亮屏，电池供电遵循系统休眠。合盖或主动睡眠时暂停。")
            }
        }
    }
}
