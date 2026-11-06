import Foundation

struct FaceCandidate {
    var boundingBox: CGRect
    var confidence: Float
}

enum FaceFilter {
    // 在完整视频帧的归一化坐标中筛选中央且足够大的人脸，再交给连续帧状态机确认，喵~
    static func confidence(in faces: [FaceCandidate]) -> Float {
        faces.filter { face in
            let box = face.boundingBox
            return face.confidence.isFinite
                && [box.origin.x, box.origin.y, box.width, box.height].allSatisfy(\.isFinite)
                && box.width >= 0.10 && box.height >= 0.10
                && box.minX >= 0 && box.minY >= 0 && box.maxX <= 1 && box.maxY <= 1
                && (0.15...0.85).contains(box.midX) && (0.15...0.85).contains(box.midY)
        }.map(\.confidence).max() ?? 0
    }
}
