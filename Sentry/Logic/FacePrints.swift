import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

private struct FacePrintError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct FacePrints {
    // 使用第 1 版特征在本机校准得到的距离阈值。
    static let ownerDistanceThreshold: Float = 15.235132
    static let photoTypes: [UTType] = [.jpeg, .png, .heic]

    private let context = CIContext()

    func detect(in image: CGImage) throws -> [FaceCandidate] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return (request.results ?? []).map { FaceCandidate(boundingBox: $0.boundingBox, confidence: $0.confidence) }
    }

    func feature(in input: CIImage, box: CGRect) throws -> VNFeaturePrintObservation {
        let bounds = input.extent
        let crop = VNImageRectForNormalizedRect(box, Int(bounds.width), Int(bounds.height))
            .offsetBy(dx: bounds.minX, dy: bounds.minY).integral.intersection(bounds)
        guard !crop.isEmpty, let face = context.createCGImage(input, from: crop) else {
            throw FacePrintError("无法裁切人脸")
        }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision1
        request.imageCropAndScaleOption = .scaleFit
        try VNImageRequestHandler(cgImage: face, orientation: .up).perform([request])
        guard let observation = request.results?.first else { throw FacePrintError("无法生成人脸图像特征") }
        return observation
    }

    func enrollment(at url: URL) throws -> VNFeaturePrintObservation {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              Self.photoTypes.contains(where: { $0.identifier == type }),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1920,
              ] as CFDictionary) else { throw FacePrintError("请选择单张 JPEG、PNG 或 HEIC 照片") }
        let faces = try detect(in: image)
        guard faces.count == 1 else { throw FacePrintError("机主照片须恰好有一张可检测的人脸") }
        return try feature(in: CIImage(cgImage: image), box: faces[0].boundingBox)
    }

    func distance(to reference: VNFeaturePrintObservation, in image: CIImage, box: CGRect) throws -> Float {
        let observation = try feature(in: image, box: box)
        var distance: Float = 0
        try reference.computeDistance(&distance, to: observation)
        guard distance.isFinite, distance >= 0 else { throw FacePrintError("人脸比对距离无效") }
        return distance
    }

    func confidence(in faces: [FaceCandidate], image: CIImage, owner: VNFeaturePrintObservation) -> Float {
        let threshold = FacePresence().threshold
        let unmatched = faces.filter { face in
            guard FaceFilter.isEligible(face), face.confidence >= threshold,
                  let distance = try? distance(to: owner, in: image, box: face.boundingBox) else { return true }
            return distance > Self.ownerDistanceThreshold
        }
        return FaceFilter.confidence(in: unmatched)
    }
}
