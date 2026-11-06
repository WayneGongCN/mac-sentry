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
    @State private var importError: String?
    @State private var media = SentryMedia()
    @State private var imagePreview: PreviewMode?

    var body: some View {
        FormView(title: "画面、声音与通知") {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("图片与声音从下一次锁屏生效，预览使用当前选择。守卫状态不播放声音。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    imageOption("守卫图片", reference: $vm.cfg.sentryGuardingImage, image: media.guardingImage,
                                mode: .guarding, defaultName: "内置机械眼")
                    Divider()
                    imageOption("告警图片", reference: $vm.cfg.sentryAlarmImage, image: media.alarmImage,
                                mode: .warning, defaultName: "实时摄像头画面")
                    ForEach(media.issues, id: \.self) { message in
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                    if let importError { Text(importError).font(.caption).foregroundStyle(.orange) }
                    Divider()
                    Text("告警声音").font(.headline)
                    HStack {
                        Text(vm.cfg.sentryAlarmSound == nil ? "内置告警音" : "自定义告警音")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("选择声音") { selectMedia(kind: .sound, reference: $vm.cfg.sentryAlarmSound) }
                        Button("恢复默认") { vm.cfg.sentryAlarmSound = nil }
                            .disabled(vm.cfg.sentryAlarmSound == nil)
                    }
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
                }.padding(.trailing, 8)
            }.frame(height: 540)
        }
        .onAppear(perform: refreshMedia)
        .onChange(of: vm.cfg.sentryGuardingImage) { _ in refreshMedia() }
        .onChange(of: vm.cfg.sentryAlarmImage) { _ in refreshMedia() }
        .onChange(of: vm.cfg.sentryAlarmSound) { _ in
            stopSoundPreview()
            previewError = nil
            refreshMedia()
        }
        .onChange(of: vm.cfg.sentryAlarmsSoundVolume) { volume in
            previewPlayer?.volume = Float(volume)
        }
        .onDisappear(perform: stopSoundPreview)
        .sheet(item: $imagePreview) { mode in DesktopPreview(mode: mode, configuration: vm.cfg) }
    }

    // 显示每种状态的素材缩略图、独立导入和恢复入口，喵~
    private func imageOption(_ title: String, reference: Binding<String?>, image: NSImage?,
                             mode: PreviewMode, defaultName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 64, height: 48)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(reference.wrappedValue == nil ? defaultName : "自定义图片")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("选择图片") { selectMedia(kind: .image, reference: reference) }
                Button("预览") { imagePreview = mode }
                Button("恢复默认") { reference.wrappedValue = nil }
                    .disabled(reference.wrappedValue == nil)
            }
        }.padding(.vertical, 4)
    }

    // 只有用户确认选择且素材导入成功后才替换原配置，喵~
    private func selectMedia(kind: SentryMediaKind, reference: Binding<String?>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = kind.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try SentryMediaStore.shared.importFile(url, kind: kind)
            reference.wrappedValue = imported
            importError = nil
        } catch { importError = "导入失败：\(error.localizedDescription)" }
    }

    // 重新解析当前选择并展示独立回退提示，喵~
    private func refreshMedia() { media = SentryMediaStore.shared.load(vm.cfg) }

    // 使用当前独立音量短暂试听，避免修改系统音量或启用告警开关，喵~
    private func previewSound() {
        stopSoundPreview()
        previewError = nil
        refreshMedia()
        guard let url = media.alarmSound else {
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
