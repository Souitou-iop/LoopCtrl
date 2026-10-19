import AVFoundation
import SwiftUI
import UIKit
import Vision
import VisionKit

/// The camera, reading QR codes: VisionKit's DataScanner where the device has
/// it (A12 and later), AVFoundation's metadata output otherwise. Calls
/// `onScan` with each QR payload it sees; the caller decides when to stop.
struct QRCodeScannerView: View {
    let onScan: (String) -> Void

    var body: some View {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            DataScannerRepresentable(onScan: onScan)
        } else if AVCaptureDevice.default(for: .video) != nil {
            CaptureScannerRepresentable(onScan: onScan)
        } else {
            Text(L10n.rs(.cameraUnavailable))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Whether any camera scanner can run here (none in the Simulator).
    static var isAvailable: Bool {
        (DataScannerViewController.isSupported && DataScannerViewController.isAvailable)
            || AVCaptureDevice.default(for: .video) != nil
    }
}

// MARK: - VisionKit

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                if let payload = code.payloadStringValue { onScan(payload) }
            }
        }
    }
}

// MARK: - AVFoundation

private struct CaptureScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> CaptureScannerController {
        let vc = CaptureScannerController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ vc: CaptureScannerController, context: Context) {}
}

final class CaptureScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

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
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for case let code as AVMetadataMachineReadableCodeObject in objects {
            if let payload = code.stringValue { onScan?(payload) }
        }
    }
}

// MARK: - Photos

enum QRImageDecoder {
    /// Every QR payload Vision finds in an image (a screenshot of the invite).
    static func payloads(in data: Data) async -> [String] {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            return (request.results ?? []).compactMap(\.payloadStringValue)
        }.value
    }
}
