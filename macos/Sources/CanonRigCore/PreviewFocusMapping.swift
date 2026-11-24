import Foundation

public enum PreviewFocusMapping {
    public static func videoRect(in view: CGSize, aspect: Double) -> CGRect? {
        guard aspect.isFinite, aspect > 0, view.width.isFinite, view.height.isFinite,
              view.width > 0, view.height > 0 else { return nil }
        let width = min(view.width, view.height * aspect)
        let height = width / aspect
        return CGRect(x: (view.width - width) / 2, y: (view.height - height) / 2, width: width, height: height)
    }

    /// Aspect-fit video, top-left origin. Clicks in letterboxing are not camera points.
    public static func point(x: Double, y: Double, viewWidth: Double, viewHeight: Double,
                             videoWidth: Double, videoHeight: Double) -> CGPoint? {
        guard [x, y, viewWidth, viewHeight, videoWidth, videoHeight].allSatisfy(\.isFinite),
              viewWidth > 0, viewHeight > 0, videoWidth > 0, videoHeight > 0 else { return nil }
        guard let rect = videoRect(in: CGSize(width: viewWidth, height: viewHeight),
                                   aspect: videoWidth / videoHeight) else { return nil }
        let px = (x - rect.minX) / rect.width
        let py = (y - rect.minY) / rect.height
        guard (-1e-12...1 + 1e-12).contains(px), (-1e-12...1 + 1e-12).contains(py) else { return nil }
        return CGPoint(x: min(1, max(0, px)), y: min(1, max(0, py)))
    }
}
