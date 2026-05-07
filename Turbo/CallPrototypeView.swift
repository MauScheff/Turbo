import SwiftUI
import UIKit

private struct HatTextureTuning: Equatable {
    var zoom: CGFloat = 1.81
    var opacity: Double = 0.98
    var lineWidth: CGFloat = 0.55
    var backgroundHue: Double = 0.24
    var backgroundSaturation: Double = 0.12
    var backgroundBrightness: Double = 0.003
}

struct TurboCallPrototypeView: View {
    let contact: Contact
    let selectedPeerState: SelectedPeerState
    let primaryAction: ConversationPrimaryAction
    let isTransmitPressActive: Bool
    let isPTTAudioSessionActive: Bool
    let mediaConnectionState: MediaConnectionState
    let mediaSessionContactID: UUID?
    let onClose: () -> Void
    let onLeave: () -> Void
    let onJoin: () -> Void
    let onBeginTransmit: () -> Void
    let onTransmitTouchReleased: () -> Void
    let onEndTransmit: () -> Void

    @State private var holdToTalkGestureState = HoldToTalkGestureState()
    @State private var transmitPressBeganAt: Date?

    @MainActor
    static func prewarmDefaultTexture() {
        let windowSize = UIApplication.shared.connectedScenes.compactMap { scene -> CGSize? in
            guard let windowScene = scene as? UIWindowScene else { return nil }
            return windowScene.windows.first(where: \.isKeyWindow)?.bounds.size
                ?? windowScene.windows.first?.bounds.size
        }.first
        HatTilingBackground.prewarmTexture(size: windowSize ?? CGSize(width: 393, height: 852), tuning: HatTextureTuning())
    }

    var body: some View {
        ZStack {
            Color(red: 0.18, green: 0.18, blue: 0.19)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                    .padding(.bottom, 74)

                identityRow

                Spacer(minLength: 0)

                actionButtons
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 58)
        }
        .onChange(of: isTransmitPressActive) { _, isActive in
            holdToTalkGestureState.handleMachinePressChanged(isActive: isActive)
            if isActive {
                transmitPressBeganAt = transmitPressBeganAt ?? Date()
            } else {
                transmitPressBeganAt = nil
            }
        }
        .onChange(of: contact.id) { _, _ in
            if holdToTalkGestureState.cancel() {
                onEndTransmit()
            }
            transmitPressBeganAt = nil
        }
        .onDisappear {
            if holdToTalkGestureState.cancel() {
                onEndTransmit()
            }
            transmitPressBeganAt = nil
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.14))
                    )
            }
            .buttonStyle(TurboCallControlButtonStyle())
            .accessibilityLabel("Minimize")

            Spacer()
        }
    }

    private var identityRow: some View {
        HStack(alignment: .center, spacing: 24) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.73, green: 0.80, blue: 0.98),
                            Color(red: 0.45, green: 0.49, blue: 0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 76, height: 76)
                .overlay(
                    Text(initials(for: contact.name))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text("Chat with \(contact.name)")
                    .font(.system(size: 34, weight: .regular, design: .default))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)

                HStack(spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 0.2)) { timeline in
                        Text(callStatusText(now: timeline.date))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 27, weight: .regular))
                        .offset(y: 1)
                }
                .font(.system(size: 28, weight: .regular, design: .default))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var actionButtons: some View {
        HStack(alignment: .top) {
            TurboCallActionButton(
                title: "Leave",
                symbolName: "xmark",
                tint: Color(red: 0.96, green: 0.28, blue: 0.24),
                isEnabled: true,
                action: onLeave
            )

            Spacer(minLength: 64)

            TurboCallActionButton(
                title: "Talk",
                symbolName: "waveform",
                tint: talkButtonTint,
                isEnabled: talkButtonIsEnabled,
                action: talkButtonTap
            )
            .simultaneousGesture(talkGesture)
        }
        .frame(maxWidth: .infinity)
    }

    private var talkButtonIsEnabled: Bool {
        primaryAction.isEnabled
    }

    private var talkButtonTint: Color {
        if isTransmitPressActive || selectedPeerState.phase == .transmitting {
            return Color(red: 0.96, green: 0.28, blue: 0.24)
        }
        return Color(red: 0.25, green: 0.52, blue: 0.93)
    }

    private func talkButtonTap() {
        guard primaryAction.kind == .connect else { return }
        onJoin()
    }

    private var talkGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard primaryAction.kind == .holdToTalk else { return }
                guard holdToTalkGestureState.beginIfAllowed(isEnabled: primaryAction.isEnabled) else { return }
                transmitPressBeganAt = Date()
                onBeginTransmit()
            }
            .onEnded { _ in
                guard primaryAction.kind == .holdToTalk else { return }
                onTransmitTouchReleased()
                guard holdToTalkGestureState.endTouch() else { return }
                transmitPressBeganAt = nil
                onEndTransmit()
            }
    }

    private func callStatusText(now: Date) -> String {
        switch selectedPeerState.detail {
        case .transmitting:
            return localTransmitAudioIsReady ? "Listening" : "Getting ready"
        case .receiving:
            return "Talking"
        case .ready:
            return "Ready"
        case .startingTransmit:
            return shouldShowTransmitWarmup(now: now) ? "Getting ready" : "Ready"
        case .wakeReady:
            return "Ready"
        case .waitingForPeer(let reason):
            switch reason {
            case .disconnecting:
                return "Disconnecting"
            case .releaseRequiredAfterInterruptedTransmit:
                return "Release to retry"
            case .pendingJoin, .backendSessionTransition, .localSessionTransition,
                 .peerReadyToConnect:
                return "Connecting"
            case .remoteWakeUnavailable:
                return "Waiting"
            case .systemWakeActivation, .wakePlaybackDeferredUntilForeground,
                 .localAudioPrewarm, .localTransportWarmup, .remoteAudioPrewarm:
                return "Getting ready"
            }
        case .peerReady:
            return "Ready"
        case .incomingRequest:
            return "Wants to talk"
        case .requested:
            return "Waiting"
        case .localJoinFailed:
            return "Could not connect"
        case .blockedByOtherSession:
            return "Busy"
        case .systemMismatch:
            return "Reconnecting"
        case .idle(let isOnline):
            return isOnline ? "Ready" : "Unavailable"
        }
    }

    private var localTransmitAudioIsReady: Bool {
        mediaSessionContactID == contact.id
            && isPTTAudioSessionActive
            && mediaConnectionState == .connected
    }

    private func shouldShowTransmitWarmup(now: Date) -> Bool {
        guard isTransmitPressActive else { return false }
        guard let transmitPressBeganAt else { return false }
        return now.timeIntervalSince(transmitPressBeganAt) >= 0.45
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        let initials = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        if initials.isEmpty, let first = name.first {
            return String(first).uppercased()
        }
        return initials.uppercased()
    }
}

private struct TurboCallActionButton: View {
    let title: String
    let symbolName: String
    let tint: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Circle()
                    .fill(tint.opacity(isEnabled ? 1 : 0.45))
                    .frame(width: 92, height: 92)
                    .overlay(
                        Image(systemName: symbolName)
                            .font(.system(size: 36, weight: .regular))
                            .foregroundStyle(.white)
                    )

                Text(title)
                    .font(.system(size: 19, weight: .regular, design: .default))
                    .foregroundStyle(.white.opacity(isEnabled ? 0.92 : 0.48))
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(TurboCallControlButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

private struct TurboTuningSliderRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    let title: String
    let valueText: String
    @Binding var value: Value
    let range: ClosedRange<Value>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.48))
            }

            Slider(value: $value, in: range)
                .tint(.white.opacity(0.78))
        }
    }
}

private struct TurboCallControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

private struct HatTilingBackground: View {
    private struct RenderRequest: Equatable {
        let size: CGSize
        let tuning: HatTextureTuning
    }

    let tuning: HatTextureTuning
    @State private var renderedTexture: CGImage?

    private struct PolygonRecord {
        let points: [CGPoint]
        let bounds: CGRect
    }

    private static let fieldPolygons = HatTilingGenerator.patchPolygons(level: 5)
    private static let fieldRecords = fieldPolygons.map { polygon in
        PolygonRecord(
            points: polygon,
            bounds: HatTilingGenerator.boundingBox(for: [polygon])
        )
    }
    private static let fieldBounds = HatTilingGenerator.boundingBox(for: fieldPolygons)
    private static let fieldCenter = CGPoint(
        x: fieldBounds.midX,
        y: fieldBounds.midY
    )
    private static let referenceBounds = HatTilingGenerator.boundingBox(
        for: HatTilingGenerator.polygons(level: 1, tileIndex: 0)
    )
    @MainActor private static var renderedTextureCache: [String: CGImage] = [:]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let request = RenderRequest(size: size, tuning: tuning)

            ZStack {
                Color.white
                    .ignoresSafeArea()

                if let renderedTexture {
                    Image(decorative: renderedTexture, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                }

                Color(
                    hue: tuning.backgroundHue,
                    saturation: tuning.backgroundSaturation,
                    brightness: tuning.backgroundBrightness
                )
                    .opacity(tuning.opacity)
                    .ignoresSafeArea()
            }
            .task(id: request) {
                guard size.width > 0, size.height > 0 else { return }
                renderedTexture = Self.cachedTexture(size: size, tuning: tuning)
            }
        }
    }

    @MainActor
    static func prewarmTexture(size: CGSize, tuning: HatTextureTuning) {
        guard size.width > 0, size.height > 0 else { return }
        _ = cachedTexture(size: size, tuning: tuning)
    }

    @MainActor
    private static func cachedTexture(size: CGSize, tuning: HatTextureTuning) -> CGImage? {
        let cacheKey = textureCacheKey(size: size, tuning: tuning)
        if let cachedTexture = renderedTextureCache[cacheKey] {
            return cachedTexture
        }

        guard let renderedTexture = renderTexture(size: size, tuning: tuning) else {
            return nil
        }

        renderedTextureCache[cacheKey] = renderedTexture
        return renderedTexture
    }

    private static func textureCacheKey(size: CGSize, tuning: HatTextureTuning) -> String {
        [
            "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))",
            String(format: "z%.3f", tuning.zoom),
            String(format: "o%.3f", tuning.opacity),
            String(format: "l%.3f", tuning.lineWidth),
            String(format: "h%.3f", tuning.backgroundHue),
            String(format: "s%.3f", tuning.backgroundSaturation),
            String(format: "b%.3f", tuning.backgroundBrightness)
        ].joined(separator: "|")
    }

    private static func renderTexture(size: CGSize, tuning: HatTextureTuning) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { rendererContext in
            let cgContext = rendererContext.cgContext
            cgContext.setAllowsAntialiasing(true)
            cgContext.setShouldAntialias(true)
            Self.drawField(context: cgContext, size: size, tuning: tuning)
        }
        return image.cgImage
    }

    private static func drawField(
        context: CGContext,
        size: CGSize,
        tuning: HatTextureTuning
    ) {
        let targetWidth = min(size.width, size.height) * 0.42 * tuning.zoom
        let scale = targetWidth / max(Self.referenceBounds.width, 1)
        let viewport = CGRect(
            x: -80,
            y: -80,
            width: size.width + 160,
            height: size.height + 160
        )

        Self.drawTexture(
            context: context,
            polygons: Self.fieldRecords,
            sourceCenter: Self.fieldCenter,
            destinationCenter: CGPoint(
                x: size.width * 0.5,
                y: size.height * 0.54
            ),
            scale: scale,
            viewport: viewport,
            lineWidth: tuning.lineWidth
        )
    }

    private static func drawTexture(
        context: CGContext,
        polygons: [PolygonRecord],
        sourceCenter: CGPoint,
        destinationCenter: CGPoint,
        scale: CGFloat,
        viewport: CGRect,
        lineWidth: CGFloat
    ) {
        for polygon in polygons {
            let transformedBounds = CGRect(
                x: destinationCenter.x + (polygon.bounds.minX - sourceCenter.x) * scale,
                y: destinationCenter.y + (polygon.bounds.minY - sourceCenter.y) * scale,
                width: polygon.bounds.width * scale,
                height: polygon.bounds.height * scale
            )

            guard transformedBounds.intersects(viewport) else { continue }

            let path = CGMutablePath()

            for (index, point) in polygon.points.enumerated() {
                let transformed = Self.transform(
                    point: point,
                    sourceCenter: sourceCenter,
                    destinationCenter: destinationCenter,
                    scale: scale
                )

                if index == 0 {
                    path.move(to: transformed)
                } else {
                    path.addLine(to: transformed)
                }
            }

            path.closeSubpath()
            context.addPath(path)
            context.setStrokeColor(UIColor.black.cgColor)
            context.setLineWidth(max(0.65, scale * 0.138 * lineWidth))
            context.strokePath()
        }
    }

    private static func transform(
        point: CGPoint,
        sourceCenter: CGPoint,
        destinationCenter: CGPoint,
        scale: CGFloat
    ) -> CGPoint {
        let translatedX = (point.x - sourceCenter.x) * scale
        let translatedY = (point.y - sourceCenter.y) * scale

        return CGPoint(
            x: destinationCenter.x + translatedX,
            y: destinationCenter.y + translatedY
        )
    }
}

#Preview("Call Prototype") {
    TurboCallPrototypeView(
        contact: Contact(id: UUID(), name: "Mellow Claude", handle: "@mellow", isOnline: true, channelId: UUID()),
        selectedPeerState: SelectedPeerState(
            relationship: .none,
            detail: .ready,
            statusMessage: "Connected",
            canTransmitNow: true
        ),
        primaryAction: ConversationPrimaryAction(
            kind: .holdToTalk,
            label: "Hold To Talk",
            isEnabled: true,
            style: .accent
        ),
        isTransmitPressActive: false,
        isPTTAudioSessionActive: true,
        mediaConnectionState: .connected,
        mediaSessionContactID: nil,
        onClose: {},
        onLeave: {},
        onJoin: {},
        onBeginTransmit: {},
        onTransmitTouchReleased: {},
        onEndTransmit: {}
    )
}
