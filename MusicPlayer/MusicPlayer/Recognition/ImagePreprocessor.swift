import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

/// AI 에 보내기 전에 악보 사진을 다듬습니다.
/// - 사진 속 종이를 찾아 기울어짐·원근을 펴고 (카메라 스캔처럼)
/// - 흑백으로 바꾸고 대비를 높여 그림자·누런 종이 색을 줄입니다.
enum ImagePreprocessor {
    private static let context = CIContext()

    static func prepare(_ image: UIImage) -> UIImage {
        guard let cg = image.normalizedOrientation().cgImage else { return image }
        var ci = CIImage(cgImage: cg)

        if let corrected = perspectiveCorrected(ci) { ci = corrected }

        // 흑백 + 대비
        let mono = CIFilter.colorControls()
        mono.inputImage = ci
        mono.saturation = 0
        mono.contrast = 1.25
        mono.brightness = 0.03
        ci = mono.outputImage ?? ci

        // 밝기 차이(그림자)를 조금 펴기
        let shadows = CIFilter.highlightShadowAdjust()
        shadows.inputImage = ci
        shadows.shadowAmount = 0.6
        shadows.highlightAmount = 1
        ci = shadows.outputImage ?? ci

        guard let out = context.createCGImage(ci, from: ci.extent) else { return image }
        return UIImage(cgImage: out)
    }

    /// 종이 네 귀퉁이를 찾아 바르게 폄. 이미 잘린 스캔 이미지(종이가 화면 대부분)는 그대로 둠.
    private static func perspectiveCorrected(_ ci: CIImage) -> CIImage? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: ci, options: [:])
        guard (try? handler.perform([request])) != nil,
              let doc = request.results?.first, doc.confidence > 0.7 else { return nil }

        let w = ci.extent.width, h = ci.extent.height
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }
        let tl = point(doc.topLeft), tr = point(doc.topRight)
        let bl = point(doc.bottomLeft), br = point(doc.bottomRight)

        // 종이가 이미 화면의 90% 이상이면 손댈 필요 없음
        let area = abs((tr.x - tl.x) * (tl.y - bl.y))
        guard area < w * h * 0.9, area > w * h * 0.2 else { return nil }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ci
        filter.topLeft = tl
        filter.topRight = tr
        filter.bottomLeft = bl
        filter.bottomRight = br
        return filter.outputImage
    }
}

private extension UIImage {
    /// 사진의 회전 정보(EXIF)를 실제 픽셀에 반영
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
