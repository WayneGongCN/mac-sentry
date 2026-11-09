import AppKit
import SwiftUI

struct OwnerFaceSettings: View {
    private enum Status { case empty, configured, unreadable }
    @State private var status = Status.empty
    @State private var importing = false
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("机主豁免（试验）")
                Button(status == .empty ? "选择机主照片" : "更换", action: selectPhoto)
                Button("移除", action: removePhoto).disabled(status == .empty)
            }
            .disabled(importing)
            Text(status == .configured ? "已录入。匹配的人脸可跳过告警触发。" : "选一张只有你的人脸照片。")
                .font(.caption).foregroundStyle(.secondary)
            if let issue {
                Text(issue).font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear {
            do { status = try OwnerFaceStore.shared.load() == nil ? .empty : .configured }
            catch {
                status = .unreadable
                issue = "机主特征无法读取，请更换照片。"
            }
        }
    }

    private func selectPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FacePrints.photoTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        issue = nil
        Task { @MainActor in
            defer { importing = false }
            do {
                try await Task.detached(priority: .userInitiated) { try OwnerFaceStore.shared.importPhoto(url) }.value
                status = .configured
            } catch { issue = error.localizedDescription }
        }
    }

    private func removePhoto() {
        do {
            try OwnerFaceStore.shared.remove()
            status = .empty
            issue = nil
        } catch { issue = error.localizedDescription }
    }
}
