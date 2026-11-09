import AVFoundation
import CoreImage
import Vision

private struct TrialError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct Sample {
    let time: TimeInterval
    let owner: [Float]
    let other: [Float]
}

private struct Clip {
    enum Kind: String { case owner, other, mixed }
    let kind: Kind
    let samples: [Sample]

    func wouldAlert(including faces: KeyPath<Sample, [Float]>, above threshold: Float = -.infinity) -> Bool {
        var presence = FacePresence()
        for sample in samples {
            let remaining = sample[keyPath: faces].contains { $0 > threshold }
            presence.ingest(confidence: remaining ? presence.threshold : 0, at: sample.time)
            if presence.isActive { return true }
        }
        return false
    }
}

private struct Results: Encodable {
    let ownerClips: Int
    let ownerClipsSuppressed: Int
    let otherClips: Int
    let mixedClips: Int
    let otherFacesSuppressed: Int

    var passed: Bool { ownerClipsSuppressed * 5 >= ownerClips * 4 && otherFacesSuppressed == 0 }

    init(clips: [Clip], threshold: Float?) {
        let ownerClips = clips.filter { $0.kind == .owner }
        self.ownerClips = ownerClips.count
        self.otherClips = clips.filter { $0.kind == .other }.count
        self.mixedClips = clips.filter { $0.kind == .mixed }.count
        if let threshold {
            ownerClipsSuppressed = ownerClips.filter { !$0.wouldAlert(including: \.owner, above: threshold) }.count
            otherFacesSuppressed = clips.flatMap(\.samples).flatMap(\.other).filter { $0 <= threshold }.count
        } else {
            ownerClipsSuppressed = 0
            otherFacesSuppressed = 0
        }
    }
}

private struct Report: Encodable {
    let passed: Bool
    let threshold: Float?
    let calibration: Results
    let holdout: Results
}

private extension FacePrints {
    func measure(_ url: URL, kind: Clip.Kind, reference: VNFeaturePrintObservation) async throws -> Clip {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 3, duration <= 15 else { throw TrialError("短片须为 3 至 15 秒") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(value: 1, timescale: 8)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let confidenceThreshold = FacePresence().threshold

        var samples: [Sample] = []
        for time in stride(from: 0.0, to: duration, by: 1.0 / 3.0) {
            let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let faces = try detect(in: result.image).filter { FaceFilter.isEligible($0) && $0.confidence >= confidenceThreshold }
            let image = CIImage(cgImage: result.image)
            var owner: [Float] = []
            var other: [Float] = []
            for face in faces {
                let distance = try distance(to: reference, in: image, box: face.boundingBox)
                if kind == .owner || (kind == .mixed && face.boundingBox.midX < 0.5) {
                    owner.append(distance)
                } else {
                    other.append(distance)
                }
            }
            guard owner.count <= 1, other.count <= 1 else { throw TrialError("同一侧检测到多张合格人脸") }
            samples.append(Sample(time: result.actualTime.seconds, owner: owner, other: other))
        }
        let clip = Clip(kind: kind, samples: samples)
        if kind != .other, !clip.wouldAlert(including: \.owner) { throw TrialError("机主未达到连续确认条件") }
        if kind != .owner, !clip.wouldAlert(including: \.other) { throw TrialError("其他人未达到连续确认条件") }
        if kind == .mixed, !samples.contains(where: { !$0.owner.isEmpty && !$0.other.isEmpty }) {
            throw TrialError("两张合格人脸须同时出现在画面里")
        }
        return clip
    }
}

@main
private enum OwnerFaceTrial {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 3 else { throw TrialError("用法：verify-owner-face <机主照片> <样本目录>") }
            let root = URL(fileURLWithPath: args[2], isDirectory: true)
            let prints = FacePrints()
            let reference = try prints.enrollment(at: URL(fileURLWithPath: args[1]))
            let calibration = try await load("calibration", from: root, prints: prints, reference: reference)
            let holdout = try await load("holdout", from: root, prints: prints, reference: reference)
            let closestOther = calibration.flatMap(\.samples).flatMap(\.other).min() ?? .infinity
            let ownerDistances = calibration.filter { $0.kind == .owner }.flatMap(\.samples).flatMap(\.owner)
            let threshold = Set(ownerDistances).sorted().lazy
                .filter { $0 < closestOther }
                .first { Results(clips: calibration, threshold: $0).passed }
            let training = Results(clips: calibration, threshold: threshold)
            let verification = Results(clips: holdout, threshold: threshold)
            let report = Report(passed: training.passed && verification.passed, threshold: threshold,
                                calibration: training, holdout: verification)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            if !report.passed { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    private static func load(_ group: String, from root: URL, prints: FacePrints,
                             reference: VNFeaturePrintObservation) async throws -> [Clip] {
        let directory = root.appendingPathComponent(group, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var clips: [Clip] = []
        var otherPeople: Set<String> = []
        for file in files {
            let parts = file.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count >= 2, let kind = Clip.Kind(rawValue: String(parts[0])),
                  kind != .other || parts.count >= 3 else {
                throw TrialError("\(group) 短片命名须为 owner-编号、other-人物编号-片段编号或 mixed-编号")
            }
            if kind == .other { otherPeople.insert(String(parts[1])) }
            do { clips.append(try await prints.measure(file, kind: kind, reference: reference)) }
            catch { throw TrialError("\(group)/\(file.lastPathComponent) · \(error.localizedDescription)") }
        }
        guard clips.filter({ $0.kind == .owner }).count >= 5, otherPeople.count >= 3,
              clips.contains(where: { $0.kind == .mixed }) else {
            throw TrialError("\(group) 至少需要 5 段机主、3 位不同的其他人和 1 段同框短片")
        }
        return clips
    }
}
