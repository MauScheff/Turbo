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
    let transportPathState: MediaTransportPathState?
    let localTelemetry: CallPeerTelemetry?
    let peerTelemetry: CallPeerTelemetry?
    var requestSubject: String? = nil
    let onClose: () -> Void
    let onLeave: () -> Void
    let onJoin: () -> Void
    let onBeginTransmit: () -> Void
    let onTransmitTouchReleased: () -> Void
    let onEndTransmit: () -> Void

    @State private var holdToTalkGestureState = HoldToTalkGestureState()
    @State private var transmitPressBeganAt: Date?
    @State private var pendingHoldToTalkTask: Task<Void, Never>?
    @State private var holdToTalkDidBeginTransmit = false

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
        GeometryReader { proxy in
            let usesWideLayout = proxy.size.width >= 700

            ZStack {
                Color(red: 48.0 / 255.0, green: 48.0 / 255.0, blue: 46.0 / 255.0)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .padding(.bottom, usesWideLayout ? 52 : 44)

                    identityRow(usesWideLayout: usesWideLayout)

                    Spacer(minLength: 0)

                    actionButtons
                        .frame(maxWidth: usesWideLayout ? 520 : .infinity)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, usesWideLayout ? 44 : 28)
                .padding(.top, 18)
                .padding(.bottom, 58)
            }
        }
        .onChange(of: isTransmitPressActive) { _, isActive in
            holdToTalkGestureState.handleMachinePressChanged(isActive: isActive)
            if isActive {
                transmitPressBeganAt = transmitPressBeganAt ?? Date()
            } else {
                pendingHoldToTalkTask?.cancel()
                pendingHoldToTalkTask = nil
                holdToTalkDidBeginTransmit = false
                transmitPressBeganAt = nil
            }
        }
        .onChange(of: contact.id) { _, _ in
            let didBeginTransmit = cancelPendingHoldToTalk()
            if didBeginTransmit {
                onEndTransmit()
            }
            transmitPressBeganAt = nil
        }
        .onDisappear {
            let didBeginTransmit = cancelPendingHoldToTalk()
            if didBeginTransmit {
                onEndTransmit()
            }
            transmitPressBeganAt = nil
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()

            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TurboCallControlButtonStyle())
            .accessibilityLabel("Minimize")
        }
    }

    @ViewBuilder
    private func identityRow(usesWideLayout: Bool) -> some View {
        HStack(alignment: .center, spacing: usesWideLayout ? 22 : 18) {
            identityText
                .frame(maxWidth: .infinity, alignment: .leading)

            callAvatar
                .frame(width: usesWideLayout ? 84 : 76, height: usesWideLayout ? 84 : 76)
        }
        .frame(maxWidth: 360, alignment: .center)
        .padding(.top, usesWideLayout ? 6 : 8)
    }

    private var callAvatar: some View {
        Circle()
            .fill(callAvatarColor)
            .overlay(
                Text(initials(for: contact.name))
                    .font(.system(size: 26, weight: .medium, design: .default))
                    .foregroundStyle(Color(red: 0.96, green: 0.95, blue: 0.91))
                    .tracking(0.8)
            )
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }

    private var callAvatarColor: Color {
        let palette = [
            Color(red: 0.45, green: 0.49, blue: 0.41),
            Color(red: 0.50, green: 0.42, blue: 0.38),
            Color(red: 0.42, green: 0.48, blue: 0.52),
            Color(red: 0.52, green: 0.47, blue: 0.36),
            Color(red: 0.44, green: 0.42, blue: 0.50)
        ]
        let hash = contact.id.uuidString.unicodeScalars.reduce(UInt32(2_166_136_261)) { partial, scalar in
            (partial ^ UInt32(scalar.value)) &* 16_777_619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }

    private var identityText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(contact.name)
                .font(.system(size: 31, weight: .medium, design: .default))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .multilineTextAlignment(.leading)

            let status = callStatusText(now: Date())
            Text(status)
                .font(.system(size: 20, weight: .regular, design: .default))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .multilineTextAlignment(.leading)
                .animation(.easeInOut(duration: 0.18), value: status)

            if hasVisibleCallContext {
                callContextRows
                    .padding(.top, 14)
            }

            if let requestSubjectText {
                Text(requestSubjectText)
                    .font(.system(size: 16, weight: .medium, design: .default))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 14)
            }
        }
    }

    private var requestSubjectText: String? {
        guard let subject = requestSubject?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subject.isEmpty,
              !isGenericRequestSubject(subject) else {
            return nil
        }
        return subject
    }

    private func isGenericRequestSubject(_ subject: String) -> Bool {
        let normalized = subject
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))

        return [
            "generic",
            "talk",
            "talk request",
            "want to talk",
            "wants to talk",
            "want to talk?",
            "wants to talk?",
            "someone wants to talk",
            "someone wants to talk with you",
            "someone wants to talk to you"
        ].contains(normalized)
    }

    private var callContextRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let localVolumeWarningText {
                Text(localVolumeWarningText)
                    .font(.system(size: 15, weight: .medium, design: .default))
                    .foregroundStyle(localVolumeWarningColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .accessibilityLabel(localVolumeWarningAccessibilityLabel)
            }

            if let audio = peerTelemetry?.audio {
                Text(peerAudioStatusText(for: audio))
                    .font(.system(size: 15, weight: .regular, design: .default))
                    .foregroundStyle(peerAudioStatusColor(for: audio))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .accessibilityLabel(peerAudioStatusAccessibilityLabel(for: audio))
            }

            if let peerConnectionStatusText {
                Text(peerConnectionStatusText)
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundStyle(callContextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .accessibilityLabel(peerConnectionStatusAccessibilityLabel)
            }
        }
    }

    private var hasVisibleCallContext: Bool {
        localVolumeWarningText != nil
            || peerTelemetry?.hasVisibleContext == true
            || transportPathLabel != nil
    }

    private var peerConnectionStatusText: String? {
        let parts = [
            peerTelemetry?.connection?.displayName,
            transportPathLabel
        ].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "\(contactShortName)’s connection · \(parts.joined(separator: " · "))"
    }

    private var peerConnectionStatusAccessibilityLabel: String {
        let parts = [
            peerTelemetry?.connection?.displayName,
            transportPathAccessibilityLabel
        ].compactMap { $0 }
        guard !parts.isEmpty else { return "\(contact.name)'s connection" }
        return "\(contact.name)'s connection, \(parts.joined(separator: ", "))"
    }

    private var transportPathLabel: String? {
        switch transportPathState {
        case .direct:
            return "Direct"
        case .fastRelay:
            return "Fast Relay"
        case .relay:
            return "Relayed"
        case .promoting, .recovering, .none:
            return nil
        }
    }

    private var transportPathAccessibilityLabel: String? {
        switch transportPathState {
        case .direct:
            return "direct"
        case .fastRelay:
            return "fast relay"
        case .relay:
            return "relayed"
        case .promoting, .recovering, .none:
            return nil
        }
    }

    private var callContextColor: Color {
        .white.opacity(0.52)
    }

    private var lowVolumeAttentionColor: Color {
        Color(red: 0.92, green: 0.67, blue: 0.42)
    }

    private var localVolumeWarningColor: Color {
        guard let percent = localTelemetry?.audio?.volumePercent else {
            return callContextColor
        }
        return isVolumeOff(percent) ? lowVolumeAttentionColor : .white.opacity(0.68)
    }

    private var localVolumeWarningText: String? {
        guard let percent = localTelemetry?.audio?.volumePercent else { return nil }
        if isVolumeOff(percent) {
            return "Turn up volume to hear \(contactShortName)"
        }
        if isVolumeVeryLow(percent) {
            return "Volume is very low"
        }
        return nil
    }

    private var localVolumeWarningAccessibilityLabel: String {
        guard let percent = localTelemetry?.audio?.volumePercent else {
            return ""
        }
        if isVolumeOff(percent) {
            return "Your volume is off. Turn up volume to hear \(contact.name)."
        }
        return "Your volume is very low. You may not hear \(contact.name)."
    }

    private func peerAudioStatusText(for audio: CallPeerTelemetry.Audio) -> String {
        if isVolumeOff(audio.volumePercent) {
            return "\(contactShortName)’s volume is off"
        }
        if isVolumeVeryLow(audio.volumePercent) {
            return "\(contactShortName)’s volume is very low"
        }
        return "\(contactShortName)’s audio · \(audio.routeName) · \(audio.volumePercent)%"
    }

    private func peerAudioStatusColor(for audio: CallPeerTelemetry.Audio) -> Color {
        isVolumeVeryLow(audio.volumePercent) ? lowVolumeAttentionColor.opacity(0.9) : callContextColor
    }

    private func peerAudioStatusAccessibilityLabel(for audio: CallPeerTelemetry.Audio) -> String {
        if isVolumeOff(audio.volumePercent) {
            return "\(contact.name)'s volume is off. They may not hear you."
        }
        if isVolumeVeryLow(audio.volumePercent) {
            return "\(contact.name)'s volume is very low. They may not hear you."
        }
        return "\(contactShortName)’s audio, \(audio.routeName), volume \(audio.volumePercent) percent"
    }

    private func isVolumeOff(_ percent: Int) -> Bool {
        percent <= 1
    }

    private func isVolumeVeryLow(_ percent: Int) -> Bool {
        percent <= 5
    }

    private var contactShortName: String {
        contact.name.split(separator: " ").first.map(String.init) ?? contact.name
    }

    private var actionButtons: some View {
        HStack(alignment: .top) {
            TurboCallActionButton(
                title: "End",
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
                isActive: isTalkButtonActive,
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
        return Color(red: 0.25, green: 0.52, blue: 0.93)
    }

    private var isTalkButtonActive: Bool {
        isTransmitPressActive || selectedPeerState.phase == .transmitting
    }

    private func talkButtonTap() {
        guard primaryAction.kind == .connect else { return }
        onJoin()
    }

    private func cancelPendingHoldToTalk() -> Bool {
        pendingHoldToTalkTask?.cancel()
        pendingHoldToTalkTask = nil
        let didBeginTransmit = holdToTalkDidBeginTransmit
        holdToTalkDidBeginTransmit = false
        _ = holdToTalkGestureState.cancel()
        return didBeginTransmit
    }

    private var talkGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard primaryAction.kind == .holdToTalk else { return }
                guard holdToTalkGestureState.beginIfAllowed(isEnabled: primaryAction.isEnabled) else { return }
                transmitPressBeganAt = Date()
                holdToTalkDidBeginTransmit = false
                pendingHoldToTalkTask?.cancel()
                pendingHoldToTalkTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard !Task.isCancelled else { return }
                    guard holdToTalkGestureState.isTrackingTouch else { return }
                    guard primaryAction.kind == .holdToTalk, primaryAction.isEnabled else { return }
                    holdToTalkDidBeginTransmit = true
                    onBeginTransmit()
                }
            }
            .onEnded { _ in
                guard primaryAction.kind == .holdToTalk else { return }
                pendingHoldToTalkTask?.cancel()
                pendingHoldToTalkTask = nil
                let didBeginTransmit = holdToTalkDidBeginTransmit
                holdToTalkDidBeginTransmit = false
                _ = holdToTalkGestureState.endTouch()
                transmitPressBeganAt = nil
                guard didBeginTransmit else { return }
                onTransmitTouchReleased()
                onEndTransmit()
            }
    }

    private func callStatusText(now: Date) -> String {
        if isTransmitPressActive, primaryAction.kind == .holdToTalk {
            if localTransmitAudioIsReady || selectedPeerState.detail == .transmitting {
                return transmitReadyStatusText(now: now)
            }
            return transmitStartupStatusText(now: now)
        }

        switch selectedPeerState.detail {
        case .transmitting:
            return readyStatusText
        case .receiving:
            return "Talking"
        case .ready:
            return readyStatusText
        case .startingTransmit:
            return readyStatusText
        case .wakeReady:
            return readyStatusText
        case .waitingForPeer(let reason):
            switch reason {
            case .disconnecting:
                return "Disconnecting..."
            case .releaseRequiredAfterInterruptedTransmit:
                return "Release to retry"
            case .pendingJoin, .backendSessionTransition, .localSessionTransition,
                 .peerReadyToConnect:
                return selectedPeerState.statusMessage
            case .remoteWakeUnavailable:
                return "Waiting"
            case .systemWakeActivation, .wakePlaybackDeferredUntilForeground,
                 .localAudioPrewarm, .localTransportWarmup, .remoteAudioPrewarm:
                return passiveWarmupStatusText(now: now)
            }
        case .peerReady:
            return readyStatusText
        case .incomingRequest:
            if primaryAction.kind == .connect {
                return "Connecting..."
            }
            return "Wants to talk"
        case .requested:
            return "Waiting"
        case .localJoinFailed:
            return selectedPeerState.statusMessage
        case .blockedByOtherSession:
            return "Busy"
        case .systemMismatch:
            return "Reconnecting..."
        case .idle(let isOnline):
            return isOnline ? readyStatusText : "Unavailable"
        }
    }

    private var readyStatusText: String {
        guard primaryAction.kind == .holdToTalk else {
            return selectedPeerState.statusMessage
        }
        return talkButtonIsEnabled ? "Ready" : "Connecting..."
    }

    private func transmitStartupStatusText(now: Date) -> String {
        return "Starting..."
    }

    private func transmitReadyStatusText(now: Date) -> String {
        return "Listening"
    }

    private func passiveWarmupStatusText(now: Date) -> String {
        guard isTransmitPressActive else {
            return "Connecting..."
        }
        return transmitStartupStatusText(now: now)
    }

    private var localTransmitAudioIsReady: Bool {
        mediaSessionContactID == contact.id
            && isPTTAudioSessionActive
            && mediaConnectionState == .connected
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
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Circle()
                    .fill(isEnabled ? tint : Color.white.opacity(0.13))
                    .frame(width: 82, height: 82)
                    .scaleEffect(isActive ? 1.08 : 1)
                    .overlay(
                        Image(systemName: symbolName)
                            .font(.system(size: 32, weight: .regular))
                            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.28))
                    )

                Text(title)
                    .font(.system(size: 17, weight: .regular, design: .default))
                    .foregroundStyle(.white.opacity(isEnabled ? 0.92 : 0.34))
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(TurboCallControlButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .animation(.interactiveSpring(response: 0.34, dampingFraction: 0.82, blendDuration: 0.08), value: isActive)
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
        transportPathState: .direct,
        localTelemetry: CallPeerTelemetry(
            audio: .init(routeName: "Speaker", volumePercent: 45),
            connection: .init(interface: .wifi)
        ),
        peerTelemetry: CallPeerTelemetry(
            audio: .init(routeName: "Speaker", volumePercent: 70),
            connection: .init(interface: .cellular)
        ),
        onClose: {},
        onLeave: {},
        onJoin: {},
        onBeginTransmit: {},
        onTransmitTouchReleased: {},
        onEndTransmit: {}
    )
}
