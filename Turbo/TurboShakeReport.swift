import SwiftUI
import UIKit

struct ShakeReportResult: Equatable {
    let incidentID: String
    let deviceID: String
    let uploadedAt: String
    let diagnosticsLatestURL: String?
}

struct ShakeReportPresentation: Equatable {
    enum State: Equatable {
        case sending
        case sent(ShakeReportResult)
        case failed(String)
    }

    let incidentID: String
    var state: State
}

struct TurboShakeReportSheet: View {
    let presentation: ShakeReportPresentation
    let onDone: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            statusIcon

            VStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actionArea
        }
        .padding(.horizontal, TurboLayout.horizontalPadding)
        .padding(.vertical, 28)
        .frame(maxWidth: TurboLayout.contentMaxWidth)
        .presentationDetents([.height(240)])
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch presentation.state {
        case .sending:
            ProgressView()
                .controlSize(.large)
        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.orange)
        }
    }

    private var title: String {
        switch presentation.state {
        case .sending:
            return "Sending report..."
        case .sent:
            return "Report sent"
        case .failed:
            return "Couldn't send report"
        }
    }

    private var message: String {
        switch presentation.state {
        case .sending:
            return "Thanks. We're collecting recent diagnostics."
        case .sent:
            return "Thanks. We'll take a look."
        case .failed(let message):
            return message
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch presentation.state {
        case .sending:
            EmptyView()
        case .sent:
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
        case .failed:
            HStack(spacing: 12) {
                Button("Done", action: onDone)
                    .buttonStyle(.bordered)
                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct ShakeReportDetector: UIViewRepresentable {
    let onShake: () -> Void

    func makeUIView(context: Context) -> ShakeReportDetectorView {
        let view = ShakeReportDetectorView()
        view.onShake = onShake
        return view
    }

    func updateUIView(_ uiView: ShakeReportDetectorView, context: Context) {
        uiView.onShake = onShake
    }
}

final class ShakeReportDetectorView: UIView {
    var onShake: (() -> Void)?

    override var canBecomeFirstResponder: Bool {
        true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            _ = self?.becomeFirstResponder()
        }
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else { return }
        onShake?()
    }
}
