import AppKit
import Foundation

let documentDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
let videoClipDir = documentDir.appendingPathComponent("VideoClip", isDirectory: true)

if CommandLine.arguments.contains("--export-previews") { LocalValidation.exportPreviews() }
else if CommandLine.arguments.contains("--verify-overlay") { LocalValidation.verifyOverlay() }
else if CommandLine.arguments.contains("--verify-recording") { LocalValidation.verifyCapture(forceRecording: true) }
else if CommandLine.arguments.contains("--verify-capture") { LocalValidation.verifyCapture() }
else {
    let identifier = Bundle.main.bundleIdentifier ?? "com.waynegong.MacSentry"
    if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
        existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    } else { App.main() }
}
