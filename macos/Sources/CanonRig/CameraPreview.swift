@preconcurrency import AVFoundation
import AppKit
import SwiftUI
import CanonRigCore

final class CameraPreviewController: NSObject, ObservableObject, @unchecked Sendable {
    let session = AVCaptureSession()
    @Published private(set) var status = "Превью выключено"

    private let queue = DispatchQueue(label: "canonrig.capture", qos: .userInitiated)
    // Accessed only on the capture queue. A late permission reply must not reopen the input.
    private var requestID: UUID?

    func start() {
        queue.async {
            let id = UUID()
            self.requestID = id
            self.publish(status: "Ищу Cam Link…")
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.configureAndStart()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { allowed in
                    self.queue.async {
                        guard self.requestID == id else { return }
                        if allowed { self.configureAndStart() }
                        else { self.publish(status: "Разрешите доступ к камере в настройках macOS") }
                    }
                }
            case .denied, .restricted:
                self.publish(status: "Разрешите доступ к камере в настройках macOS")
            @unknown default:
                self.publish(status: "Камера недоступна")
            }
        }
    }

    func stop() {
        queue.async {
            self.requestID = nil
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            self.session.commitConfiguration()
            self.publish(status: "Превью выключено")
        }
    }

    private func configureAndStart() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external], mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains("Cam Link")
        }) else {
            publish(status: "Cam Link не найден")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                publish(status: "Не удалось открыть видеовход")
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .high
            session.addInput(input)
            session.commitConfiguration()
            session.startRunning()
            publish(status: session.isRunning ? "" : "Не удалось запустить превью")
        } catch {
            publish(status: "Не удалось открыть Cam Link")
        }
    }

    private func publish(status: String) {
        DispatchQueue.main.async { self.status = status }
    }
}

private final class PreviewSurface: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    var onFocus: ((CGPoint, Double) -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let input = previewLayer.session?.inputs.first as? AVCaptureDeviceInput,
              previewLayer.session?.isRunning == true else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(input.device.activeFormat.formatDescription)
        let location = convert(event.locationInWindow, from: nil)
        guard let point = PreviewFocusMapping.point(x: location.x, y: location.y,
            viewWidth: bounds.width, viewHeight: bounds.height,
            videoWidth: Double(dimensions.width), videoHeight: Double(dimensions.height)) else { return }
        onFocus?(point, Double(dimensions.width) / Double(dimensions.height))
    }

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

struct CameraPreview: View {
    @ObservedObject var controller: CameraPreviewController
    var onFocus: ((CGPoint, Double) -> Bool)? = nil
    private struct FocusMarker {
        let id = UUID()
        let point: CGPoint
        let aspect: Double
        let requested: Bool
    }
    @State private var marker: FocusMarker?

    var body: some View {
        PreviewLayerView(session: controller.session) { point, aspect in
            guard let onFocus else { return }
            marker = FocusMarker(point: point, aspect: aspect, requested: onFocus(point, aspect))
        }
            .overlay {
                GeometryReader { geometry in
                    if controller.status.isEmpty, let marker,
                       let rect = PreviewFocusMapping.videoRect(in: geometry.size, aspect: marker.aspect) {
                        Image(systemName: marker.requested ? "viewfinder" : "xmark")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(marker.requested ? Color.white : Color.orange)
                            .shadow(color: .black.opacity(0.9), radius: 1.5)
                            .position(x: rect.minX + marker.point.x * rect.width,
                                      y: rect.minY + marker.point.y * rect.height)
                    }
                }
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .task(id: marker?.id) {
                guard let id = marker?.id else { return }
                do { try await Task.sleep(for: .milliseconds(1400)) } catch { return }
                if marker?.id == id { marker = nil }
            }
            .overlay {
                if !controller.status.isEmpty {
                    Text(controller.status)
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(14)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                }
            }
    }
}

private struct PreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    var onFocus: ((CGPoint, Double) -> Void)?

    func makeNSView(context: Context) -> PreviewSurface { PreviewSurface(session: session) }
    func updateNSView(_ nsView: PreviewSurface, context: Context) { nsView.onFocus = onFocus }
}
