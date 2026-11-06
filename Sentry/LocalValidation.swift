import AppKit
import AVFoundation
import SwiftUI

enum LocalValidation {
    // 重复运行真实顶层窗口的解锁清理路径，并导出不含画面的检查结果，喵~
    static func verifyOverlay() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var results: [[String: Any]] = []
        var next: (() -> Void)?
        next = {
            Sentry.shared.verifyStopOnDesktop { report in
                results.append(report)
                if results.count < 3 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next?() } }
                else {
                    if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: documentDir.appendingPathComponent("overlay-verification.json"))
                    }
                    next = nil
                    app.terminate(nil)
                }
            }
        }
        DispatchQueue.main.async { next?() }
        app.run()
    }

    // 从真实原生视图导出两种状态的静态预览，不访问摄像头，喵~
    static func exportPreviews() {
        let output = documentDir.appendingPathComponent("Previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var windows: [NSWindow] = []
        for warning in [false, true] {
            let view = NSHostingView(rootView: ZStack(alignment: .bottom) {
                Color(white: 0.13)
                Text("macOS 原生解锁区域").font(.system(size: 18)).foregroundStyle(.gray).padding(.bottom, 110)
                SentryHUD(warning: warning, session: AVCaptureSession(), isPreview: true, previewCamera: false)
            })
            view.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            window.orderFront(nil)
            windows.append(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for (index, window) in windows.enumerated() {
                guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let name = index == 0 ? "guarding.png" : "warning.png"
                try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name))
                window.orderOut(nil)
            }
            app.terminate(nil)
        }
        app.run()
    }

    // 在用户已授权后检查真实摄像头、检测和文件输出协同运行，只写本地摘要，喵~
    static func verifyCapture(forceRecording: Bool = false) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let pipeline = CapturePipeline(segmentInterval: 3)
        var frames = 0
        var human = HumanPresence()
        var began = false
        var humanConfirmed = false
        var recordingStarted = false
        var maxConfidence: Float = 0
        var errors: [String] = []
        var startedAt = Date()
        pipeline.onDetection = { confidence, time in
            frames += 1
            maxConfidence = max(maxConfidence, confidence)
            human.ingest(confidence: confidence, at: time)
            if human.isActive { humanConfirmed = true }
            if human.isActive && !began { began = true; pipeline.beginEvent() }
        }
        pipeline.onCameraIssue = { if let text = $0 { errors.append(text) } }
        pipeline.onRecordingState = { state in
            if state == .recording { recordingStarted = true }
            if case let .failed(text) = state { errors.append(text) }
        }
        let finish = {
            pipeline.stop()
            pipeline.waitForFinished {
                let report: [String: Any] = ["sampledFrames": frames, "humanConfirmed": humanConfirmed,
                    "recordingStarted": recordingStarted, "issues": errors, "maxConfidence": maxConfidence,
                    "forcedRecordingCheck": forceRecording,
                    "testSegmentSeconds": 3,
                    "elapsedSeconds": Date().timeIntervalSince(startedAt), "cameraAuthorized": AVCaptureDevice.authorizationStatus(for: .video) == .authorized]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: documentDir.appendingPathComponent("capture-verification.json"))
                }
                app.terminate(nil)
            }
        }
        let start = {
            startedAt = Date()
            pipeline.start(detectionEnabled: true)
            if forceRecording {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if !began { began = true; pipeline.beginEvent() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: finish)
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async(execute: start) }
        } else { DispatchQueue.main.async(execute: start) }
        app.run()
    }
}
