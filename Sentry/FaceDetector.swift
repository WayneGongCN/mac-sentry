import AVFoundation
import CoreImage
import Vision

final class FaceDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var enabled = true
    var ownerReference: VNFeaturePrintObservation?
    var onFrame: ((CMSampleBuffer) -> Void)?
    var onResult: ((Float, TimeInterval) -> Void)?
    var onFailure: ((String) -> Void)?
    private var lastAnalysis: TimeInterval = 0
    private let visionQueue = DispatchQueue(label: "com.waynegong.MacSentry.vision", qos: .userInitiated)
    private let analysisSlot = DispatchSemaphore(value: 1)
    private let request = VNDetectFaceRectanglesRequest()
    private lazy var facePrints = FacePrints()

    // 串行抽取最新视频帧，识别工作不阻塞主线程和录像输出，喵~
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAnalysis >= 1.0 / 3.0,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard enabled else { lastAnalysis = now; onResult?(0, now); return }
        guard analysisSlot.wait(timeout: .now()) == .success else { return }
        lastAnalysis = now
        let owner = ownerReference
        visionQueue.async { [self] in
            defer { analysisSlot.signal() }
            do {
                try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
                let faces = request.results?.map { FaceCandidate(boundingBox: $0.boundingBox, confidence: $0.confidence) } ?? []
                let confidence = owner.map { facePrints.confidence(in: faces, image: CIImage(cvPixelBuffer: buffer), owner: $0) }
                    ?? FaceFilter.confidence(in: faces)
                onResult?(confidence, now)
            } catch { onFailure?("人脸检测暂不可用：\(error.localizedDescription)") }
        }
    }
}
