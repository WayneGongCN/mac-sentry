import Foundation
import Vision

struct OwnerFaceStore {
    static let shared = OwnerFaceStore(file: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("MacSentry/OwnerFace.feature"))

    let file: URL

    func load() throws -> VNFeaturePrintObservation? {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        guard let feature = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data),
              feature.requestRevision == VNGenerateImageFeaturePrintRequestRevision1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return feature
    }

    func importPhoto(_ url: URL) throws {
        let feature = try FacePrints().enrollment(at: url)
        let data = try NSKeyedArchiver.archivedData(withRootObject: feature, requiringSecureCoding: true)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    func remove() throws {
        do { try FileManager.default.removeItem(at: file) }
        catch CocoaError.fileNoSuchFile {}
    }
}
