#if os(iOS)
import AVFoundation
import BiblioCore
import SwiftUI
import VisionKit

/// Whether this device can scan a library card barcode.
@MainActor var canScanCard: Bool {
    DataScannerViewController.isSupported
}

/// A camera sheet that reads a library card's Codabar or Code 128 barcode and hands back
/// the card number, cleaned by the core.
struct CardScannerSheet: View {
    var onScan: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var denied = false

    var body: some View {
        NavigationStack {
            Group {
                if denied {
                    ContentUnavailableView {
                        Label("Camera Access Is Off", systemImage: "camera.fill")
                    } description: {
                        Text("Allow camera access for Biblio in Settings to scan your library card.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                } else {
                    ScannerRepresentable { code in
                        guard let card = Core.take(biblio_card_normalize(code)) else { return false }
                        onScan(card)
                        dismiss()
                        return true
                    }
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Text("Point the camera at the barcode on your library card.")
                            .font(.callout)
                            .padding(10)
                            .background(.regularMaterial, in: .capsule)
                            .padding()
                    }
                }
            }
            .navigationTitle("Scan Library Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied, .restricted: denied = true
            case .notDetermined: denied = !(await AVCaptureDevice.requestAccess(for: .video))
            default: break
            }
        }
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    /// Called with each recognized barcode; returns whether it was accepted.
    var onCode: (String) -> Bool

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.codabar, .code128])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Bool
        init(onCode: @escaping (String) -> Bool) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in items {
                if let value = barcode.payloadStringValue, onCode(value) {
                    scanner.stopScanning()
                    return
                }
            }
        }
    }
}
#endif
