import Foundation

public enum PreviewFocusMapping {
    /// Aspect-fit video, top-left origin. Clicks in letterboxing are not camera points.
    public static func point(x: Double, y: Double, viewWidth: Double, viewHeight: Double,
                             videoWidth: Double, videoHeight: Double) -> CGPoint? {
        guard [x, y, viewWidth, viewHeight, videoWidth, videoHeight].allSatisfy(\.isFinite),
              viewWidth > 0, viewHeight > 0, videoWidth > 0, videoHeight > 0 else { return nil }
        let scale = min(viewWidth / videoWidth, viewHeight / videoHeight)
        let width = videoWidth * scale, height = videoHeight * scale
        let px = (x - (viewWidth - width) / 2) / width
        let py = (y - (viewHeight - height) / 2) / height
        guard (-1e-12...1 + 1e-12).contains(px), (-1e-12...1 + 1e-12).contains(py) else { return nil }
        return CGPoint(x: min(1, max(0, px)), y: min(1, max(0, py)))
    }
}
