import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
#if canImport(VisionKit)
import Vision
import VisionKit
#endif

struct TurboAddContactSheet: View {
    @Binding var draftReference: String
    let currentIdentityCode: String
    let currentShareLink: String
    let quickPeerHandles: [String]
    let isOpeningPeer: Bool
    let isResettingDevState: Bool
    let statusMessage: String?
    let onClose: () -> Void
    let onOpenReference: (String) -> Void

    @State private var copiedStatus: String?
    @State private var isShowingScanner: Bool = false

    private var isBusy: Bool {
        isOpeningPeer || isResettingDevState
    }

    private var trimmedDraftReference: String {
        draftReference.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shareURL: URL? {
        URL(string: currentShareLink)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    addByReferenceCard
                    scanQRCodeCard
                    shareIdentityCard
                }
                .padding()
            }
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
            .sheet(isPresented: $isShowingScanner) {
                TurboQRScannerSheet(
                    onClose: { isShowingScanner = false },
                    onCodeScanned: handleScannedCode(_:)
                )
            }
        }
    }

    private var addByReferenceCard: some View {
        TurboAddContactCard(
            title: "Add by code or link",
            subtitle: "Paste a BeepBeep code, share link, or DID."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Code, link, or DID", text: $draftReference)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        onOpenReference(trimmedDraftReference)
                    } label: {
                        Text(isOpeningPeer ? "Opening…" : "Open")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedDraftReference.isEmpty || isBusy)

                    Button("Paste") {
                        guard let pastedValue = UIPasteboard.general.string else { return }
                        draftReference = pastedValue
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }

                if let statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !quickPeerHandles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dev quick add")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(quickPeerHandles, id: \.self) { handle in
                                    Button(handle) {
                                        draftReference = handle
                                        onOpenReference(handle)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isBusy)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var scanQRCodeCard: some View {
        TurboAddContactCard(
            title: "Scan QR",
            subtitle: "Use the camera to add someone nearby."
        ) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Scan a BeepBeep QR code.")
                        .font(.subheadline.weight(.semibold))

                    Text("Use the camera to open the same BeepBeep share link shown below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button("Scan") {
                    isShowingScanner = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
    }

    private var shareIdentityCard: some View {
        TurboAddContactCard(
            title: "Share your BeepBeep",
            subtitle: "Let someone scan this or open your link."
        ) {
            VStack(alignment: .center, spacing: 14) {
                TurboQRCodeView(payload: currentShareLink)
                    .frame(width: 188, height: 188)

                VStack(spacing: 4) {
                    Text(currentIdentityCode)
                        .font(.title3.weight(.semibold))

                    Text(currentShareLink)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Button("Copy Code") {
                        UIPasteboard.general.string = currentIdentityCode
                        copiedStatus = "Copied code"
                    }
                    .buttonStyle(.bordered)

                    Button("Copy Link") {
                        UIPasteboard.general.string = currentShareLink
                        copiedStatus = "Copied link"
                    }
                    .buttonStyle(.bordered)

                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Text("Share")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let copiedStatus {
                    Text(copiedStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func handleScannedCode(_ code: String) {
        draftReference = code
        isShowingScanner = false
        onOpenReference(code)
    }
}

private struct TurboAddContactCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct TurboQRCodeView: View {
    let payload: String

    var body: some View {
        Group {
            if let image = qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .background(.white)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 72, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemBackground))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var qrImage: UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 12, y: 12)
        ) else {
            return nil
        }

        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

private struct TurboQRScannerSheet: View {
    let onClose: () -> Void
    let onCodeScanned: (String) -> Void

    @State private var cameraAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var isRequestingCameraAccess = false

    private var scannerSupported: Bool {
#if canImport(VisionKit)
        if #available(iOS 16.0, *) {
            return DataScannerViewController.isSupported
        }
#endif
        return false
    }

    var body: some View {
        NavigationStack {
            Group {
                if !scannerSupported {
                    scannerMessage(
                        title: "Scanning unavailable",
                        detail: "This device does not support live QR scanning. You can still paste a BeepBeep link or code."
                    )
                } else {
                    switch cameraAuthorizationStatus {
                    case .authorized:
                        scannerView
                    case .notDetermined:
                        permissionPrompt
                    case .denied, .restricted:
                        scannerMessage(
                            title: "Camera access needed",
                            detail: "Allow camera access in Settings to scan BeepBeep QR codes."
                        )
                    @unknown default:
                        scannerMessage(
                            title: "Camera unavailable",
                            detail: "The camera could not be prepared right now. You can still paste a BeepBeep link or code."
                        )
                    }
                }
            }
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    @ViewBuilder
    private var scannerView: some View {
#if canImport(VisionKit)
        if #available(iOS 16.0, *) {
            TurboLiveQRScannerView(onCodeScanned: onCodeScanned)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text("Point the camera at a BeepBeep QR code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 24)
                }
        }
#endif
    }

    private var permissionPrompt: some View {
        scannerMessage(
            title: "Allow camera access",
            detail: "BeepBeep needs the camera to scan QR codes in person."
        ) {
            Button {
                requestCameraAccess()
            } label: {
                Text(isRequestingCameraAccess ? "Requesting…" : "Allow Camera Access")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequestingCameraAccess)
        }
    }

    private func scannerMessage<Actions: View>(
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            actions()

            Spacer()
        }
        .padding(24)
    }

    private func scannerMessage(title: String, detail: String) -> some View {
        scannerMessage(title: title, detail: detail) {
            EmptyView()
        }
    }

    private func requestCameraAccess() {
        guard !isRequestingCameraAccess else { return }
        isRequestingCameraAccess = true
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                cameraAuthorizationStatus = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .video)
                isRequestingCameraAccess = false
            }
        }
    }
}

#if canImport(VisionKit)
@available(iOS 16.0, *)
private struct TurboLiveQRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCodeScanned: (String) -> Void
        private var hasDeliveredCode = false

        init(onCodeScanned: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasDeliveredCode else { return }
            guard let code = recognizedCode(in: addedItems) else { return }
            hasDeliveredCode = true
            onCodeScanned(code)
        }

        private func recognizedCode(in items: [RecognizedItem]) -> String? {
            for item in items {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue,
                   !payload.isEmpty {
                    return payload
                }
            }
            return nil
        }
    }
}
#endif
