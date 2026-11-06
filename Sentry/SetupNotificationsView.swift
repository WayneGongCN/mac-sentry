//
//  SetupNotificationsView.swift
//  Sentry
//
//  Created by 秋星桥 on 5/24/25.
//

import AVFAudio
import SwiftUI

struct SetupNotificationsView: View {
    @StateObject var vm = SentryConfigurationManager.shared
    @State private var previewPlayer: AVAudioPlayer?
    @State private var previewStop: DispatchWorkItem?
    @State private var previewError: String?

    var body: some View {
        FormView(title: "Setup Notifications") {
            VStack(alignment: .leading, spacing: 8) {
                Text("声音默认关闭，可单独调低告警音量。试听不会开启声音告警。")
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Toggle(isOn: $vm.cfg.sentryAlarmsSoundsEnabled) {
                    Text("Play Sound")
                }
                HStack {
                    Text("告警音量")
                    Spacer()
                    Text("\(Int((vm.cfg.sentryAlarmsSoundVolume * 100).rounded()))%")
                        .monospacedDigit()
                }
                Slider(value: $vm.cfg.sentryAlarmsSoundVolume, in: 0...1, step: 0.01)
                    .accessibilityLabel("告警音量")
                    .accessibilityValue("\(Int((vm.cfg.sentryAlarmsSoundVolume * 100).rounded()))%")
                HStack {
                    Button(previewPlayer == nil ? "试听 2 秒" : "停止试听") {
                        if previewPlayer == nil { previewSound() }
                        else { stopSoundPreview() }
                    }
                    Text("实际响度仍受系统音量影响。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let previewError {
                    Text(previewError).font(.caption).foregroundStyle(.orange)
                }
                Divider()
                Text("If you have Bark installed on your phone, connect to Bark here. For more information, please visit [https://bark.day.app/](https://bark.day.app/).")
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Toggle(isOn: .init(get: {
                    vm.cfg.sentryAlarmsNotificationType == .bark
                }, set: { newValue in
                    if newValue {
                        vm.cfg.sentryAlarmsNotificationType = .bark
                    } else {
                        vm.cfg.sentryAlarmsNotificationType = .none
                    }
                })) {
                    Text("Use Bark")
                }
                Divider()
                Grid(
                    alignment: .trailing,
                    horizontalSpacing: 8,
                    verticalSpacing: 4
                ) {
                    GridRow {
                        Text("Endpoint")
                        TextField("Server Endpoint", text: $vm.cfg.sentryNotificationConfigBark.endpoint)
                            .autocorrectionDisabled()
                            .onChange(of: vm.cfg.sentryNotificationConfigBark.endpoint) { newValue in
                                guard var url = URL(string: newValue) else { return }
                                while url.pathComponents.count > 2 {
                                    url = url.deletingLastPathComponent()
                                }
                                var text = url.absoluteString
                                if text.hasSuffix("/") { text.removeLast() }
                                guard text != newValue else { return }
                                vm.cfg.sentryNotificationConfigBark.endpoint = text
                            }
                    }
                }
                .disabled(vm.cfg.sentryAlarmsNotificationType != .bark)
            }
        }
        .onChange(of: vm.cfg.sentryAlarmsSoundVolume) { volume in
            previewPlayer?.volume = Float(volume)
        }
        .onDisappear(perform: stopSoundPreview)
    }

    // 使用当前独立音量短暂试听，避免修改系统音量或启用告警开关，喵~
    private func previewSound() {
        stopSoundPreview()
        previewError = nil
        guard let url = Bundle.main.url(forResource: "alarm", withExtension: "mp3") else {
            previewError = "找不到告警声音文件"
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = Float(vm.cfg.sentryAlarmsSoundVolume)
            guard player.play() else {
                previewError = "无法播放告警声音，请检查音频输出设备"
                return
            }
            previewPlayer = player
            let stop = DispatchWorkItem { stopSoundPreview() }
            previewStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: stop)
        } catch {
            previewError = "试听失败：\(error.localizedDescription)"
        }
    }

    // 试听结束、用户停止或关闭设置时释放播放器和延时任务，喵~
    private func stopSoundPreview() {
        previewStop?.cancel()
        previewStop = nil
        previewPlayer?.stop()
        previewPlayer = nil
    }
}

#Preview {
    SetupNotificationsView()
}
