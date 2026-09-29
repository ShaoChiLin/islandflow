import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins

struct QRCodeView: View {
    var text: String

    var body: some View {
        Image(uiImage: Self.image(for: text))
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .padding(12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("二維碼")
    }

    static func image(for text: String) -> UIImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return UIImage() }
        return UIImage(cgImage: cg)
    }
}

/// 相機掃碼。模擬器沒有相機，會顯示提示，改用下方的展示按鈕。
struct QRScannerView: View {
    var onCode: (String) -> Void
    @State private var authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized

    static var hasCamera: Bool { AVCaptureDevice.default(for: .video) != nil }

    var body: some View {
        Group {
            if !Self.hasCamera {
                placeholder("這台裝置沒有相機（模擬器）", "請使用下方的展示用模擬掃描")
            } else if authorized {
                ScannerRepresentable(onCode: onCode)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.8), lineWidth: 2).padding(40))
            } else {
                placeholder("需要相機權限", "到「設定」允許旅綠使用相機")
                    .task {
                        authorized = await AVCaptureDevice.requestAccess(for: .video)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func placeholder(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 44))
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondary.opacity(0.12))
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {
        vc.onCode = onCode
    }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastCode: String?
    private var lastTime = Date.distantPast

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { if !s.isRunning { s.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { if s.isRunning { s.stopRunning() } }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        // 同一個碼 3 秒內只回報一次，避免鏡頭停在碼上連續觸發
        if code == lastCode && Date().timeIntervalSince(lastTime) < 3 { return }
        lastCode = code
        lastTime = Date()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode?(code)
    }
}
