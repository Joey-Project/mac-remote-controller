import AVFoundation
import AppleCore
import Foundation
import SwiftUI
import UIKit

struct PairingScanner: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraStatus: CameraStatus = .checking
    let onInvitation: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("Scan the pairing code shown in Sofa Remote on your Mac.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)

                switch cameraStatus {
                case .checking:
                    ProgressView("Checking camera access…")
                        .frame(maxWidth: .infinity, minHeight: 300)
                case .ready:
                    QRCodeCameraPreview(
                        onCode: onInvitation,
                        onSetupFailure: { cameraStatus = .failed }
                    )
                    .frame(maxWidth: 520)
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(.white.opacity(0.65), lineWidth: 2)
                            .padding(36)
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("Camera QR code scanner")
                case .denied:
                    cameraMessage(
                        title: "Camera access is off",
                        message: "Allow camera access in Settings to scan a code. You can also "
                            + "close this sheet and paste the invitation code instead.",
                        symbol: "camera.fill"
                    )
                    Button("Open Settings", systemImage: "gearshape") {
                        guard let settingsURL = URL(string: UIApplication.openSettingsURLString)
                        else { return }
                        UIApplication.shared.open(settingsURL)
                    }
                    .buttonStyle(.borderedProminent)
                case .unavailable:
                    cameraMessage(
                        title: "Camera unavailable",
                        message: "This device cannot scan a pairing code. Close this sheet "
                            + "and paste the invitation code instead.",
                        symbol: "camera.metering.unknown"
                    )
                case .failed:
                    cameraMessage(
                        title: "Scanner could not start",
                        message:
                            "Try again or close this sheet and paste the invitation code instead.",
                        symbol: "exclamationmark.triangle"
                    )
                }

                if cameraStatus != .ready && cameraStatus != .checking {
                    Button("Use invitation code instead") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Pair with QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            await checkCameraAccess()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, cameraStatus == .denied else { return }
            Task {
                await checkCameraAccess()
            }
        }
    }

    private func cameraMessage(title: String, message: String, symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: 480, minHeight: 260)
    }

    @MainActor
    private func checkCameraAccess() async {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            cameraStatus = .unavailable
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraStatus = .ready
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraStatus = granted ? .ready : .denied
        case .denied, .restricted:
            cameraStatus = .denied
        @unknown default:
            cameraStatus = .failed
        }
    }
}

private enum CameraStatus: Equatable {
    case checking
    case ready
    case denied
    case unavailable
    case failed
}

private struct QRCodeCameraPreview: UIViewRepresentable {
    let onCode: (String) -> Void
    let onSetupFailure: @MainActor () -> Void

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        context.coordinator.onCode = onCode
        context.coordinator.onSetupFailure = onSetupFailure
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.onSetupFailure = onSetupFailure
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "com.joeyteng.sofaremote.ios.qr-camera")
        private let resultLock = NSLock()
        private var configured = false
        private var didReadCode = false
        var onCode: ((String) -> Void)?
        var onSetupFailure: (@MainActor () -> Void)?

        @MainActor
        func attach(to view: CameraPreviewView) {
            view.previewLayer.session = session
            sessionQueue.async { [weak self] in
                self?.configureAndStart()
            }
        }

        func stop() {
            sessionQueue.async { [weak self] in
                guard let self, self.session.isRunning else { return }
                self.session.stopRunning()
            }
        }

        private func configureAndStart() {
            guard !configured else {
                if !session.isRunning { session.startRunning() }
                return
            }
            guard let camera = AVCaptureDevice.default(for: .video) else {
                reportSetupFailure()
                return
            }

            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: camera)
            } catch {
                reportSetupFailure()
                return
            }
            guard session.canAddInput(input) else {
                reportSetupFailure()
                return
            }

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                reportSetupFailure()
                return
            }

            session.beginConfiguration()
            session.sessionPreset = .high
            session.addInput(input)
            session.addOutput(output)
            guard output.availableMetadataObjectTypes.contains(.qr) else {
                session.commitConfiguration()
                reportSetupFailure()
                return
            }
            output.setMetadataObjectsDelegate(self, queue: sessionQueue)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            configured = true
            session.startRunning()
        }

        private func reportSetupFailure() {
            Task { @MainActor [weak self] in
                self?.onSetupFailure?()
            }
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            let invitation =
                metadataObjects
                .compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
                .compactMap { value -> String? in
                    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty, (try? PairingInvitation.parse(value)) != nil else {
                        return nil
                    }
                    return value
                }
                .first
            guard let invitation else { return }

            resultLock.lock()
            let shouldDeliver = !didReadCode
            didReadCode = true
            resultLock.unlock()
            guard shouldDeliver else { return }

            Task { @MainActor [weak self] in
                self?.onCode?(invitation)
            }
            sessionQueue.async { [weak self] in
                guard let self, self.session.isRunning else { return }
                self.session.stopRunning()
            }
        }
    }
}

private final class CameraPreviewView: UIView {
    override static var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("Camera preview requires AVCaptureVideoPreviewLayer")
        }
        layer.videoGravity = .resizeAspectFill
        return layer
    }
}
