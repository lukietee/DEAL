import SwiftUI

/// Sheet wrapper around the camera scanner (camera usage string is in project.yml).
struct QRScannerSheet: View {
    var onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                #if os(iOS)
                QRScannerView(onScan: onScan).ignoresSafeArea()
                #else
                Text("Camera scanning is only available on iPhone.").padding()
                #endif
                VStack(spacing: 28) {
                    ViewfinderCorners(radius: 24)
                        .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                        .frame(width: 240, height: 240)
                    Text("Point at the QR code on the buyer's phone")
                        .font(DealFont.jakarta(15, .bold))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(Capsule().fill(Palette.surface))
                }
                .allowsHitTesting(false)
            }
            .background(Palette.dark.ignoresSafeArea())
            .navigationTitle("Scan join code")
            .dealInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

#if os(iOS)
@preconcurrency import AVFoundation
import UIKit

/// AVFoundation QR scanner. Calls `onScan` once with the first QR payload found.
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((String) -> Void)?
        private let captureSession = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var didScan = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configure() } else { self?.showMessage("Camera access denied. Type the code instead.") }
                }
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  captureSession.canAddInput(input) else {
                showMessage("No camera available. Type the code instead.")
                return
            }
            captureSession.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else { return }
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: captureSession)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            previewLayer = layer

            // Delegate callbacks are delivered on .main (see setMetadataObjectsDelegate above).
            nonisolated(unsafe) let session = captureSession
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if captureSession.isRunning { captureSession.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !didScan,
                  let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            didScan = true
            captureSession.stopRunning()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onScan?(value)
        }

        private func showMessage(_ text: String) {
            let label = UILabel()
            label.text = text
            label.textColor = .white
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            ])
        }
    }
}
#endif
