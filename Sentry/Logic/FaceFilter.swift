import Foundation

struct FaceCandidate {
    var boundingBox: CGRect
    var confidence: Float
}

enum FaceFilter {
    // 在完整视频帧中筛选足够大且未越界的人脸，喵~
    static func confidence(in faces: [FaceCandidate]) -> Float {
        faces.filter(isEligible).map(\.confidence).max() ?? 0
    }

    static func isEligible(_ face: FaceCandidate) -> Bool {
        let box = face.boundingBox
        return face.confidence.isFinite
            && [box.origin.x, box.origin.y, box.width, box.height].allSatisfy(\.isFinite)
            && box.width >= 0.10 && box.height >= 0.10
            && box.minX >= 0 && box.minY >= 0 && box.maxX <= 1 && box.maxY <= 1
    }
}
