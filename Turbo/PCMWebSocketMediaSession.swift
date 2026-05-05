import Foundation
import AVFAudio
import CryptoKit

enum PlaybackBufferReceivePlan: Equatable {
    case deferUntilIOCycle
    case scheduleAndStartNode
    case scheduleOnly
}

actor AudioChunkSender {
    private var sendChunk: (@Sendable (String) async throws -> Void)?
    private let reportFailure: @Sendable (String) async -> Void
    private let reportEvent: (@Sendable (String, [String: String]) async -> Void)?
    // Keep sender-side live audio bounded; receiver-side wake buffering happens
    // after transport delivery, so stale outbound chunks are worse than drops.
    private let maximumPendingPayloads: Int
    private let maximumPayloadsPerMessage: Int
    private let payloadBatchCollectionNanoseconds: UInt64
    private let payloadBatchCollectionPollNanoseconds: UInt64 = 10_000_000
    private let transportAvailabilityPollNanoseconds: UInt64
    private let transportAvailabilityMaxAttempts: Int
    private var pendingPayloads: [String] = []
    private var isDraining = false
    private var flushPendingImmediately = false
    private var outboundTransportDispatchReportBudget = 64
    private var outboundTransportSuccessReportBudget = 64
    private var outboundTransportDropReportBudget = 16

    init(
        sendChunk: (@Sendable (String) async throws -> Void)?,
        reportFailure: @escaping @Sendable (String) async -> Void,
        reportEvent: (@Sendable (String, [String: String]) async -> Void)? = nil,
        maximumPendingPayloads: Int = 16,
        maximumPayloadsPerMessage: Int = 4,
        payloadBatchCollectionNanoseconds: UInt64 = 0,
        transportAvailabilityPollNanoseconds: UInt64 = 50_000_000,
        transportAvailabilityMaxAttempts: Int = 80
    ) {
        self.sendChunk = sendChunk
        self.reportFailure = reportFailure
        self.reportEvent = reportEvent
        self.maximumPendingPayloads = maximumPendingPayloads
        self.maximumPayloadsPerMessage = maximumPayloadsPerMessage
        self.payloadBatchCollectionNanoseconds = payloadBatchCollectionNanoseconds
        self.transportAvailabilityPollNanoseconds = transportAvailabilityPollNanoseconds
        self.transportAvailabilityMaxAttempts = transportAvailabilityMaxAttempts
    }

    func updateSendChunk(_ handler: (@Sendable (String) async throws -> Void)?) {
        sendChunk = handler
    }

    func enqueue(_ payload: String) async {
        pendingPayloads.append(payload)
        if pendingPayloads.count > maximumPendingPayloads {
            let droppedPayloadCount = pendingPayloads.count - maximumPendingPayloads
            pendingPayloads.removeFirst(droppedPayloadCount)
            reportTransportDropIfNeeded(
                droppedPayloadCount: droppedPayloadCount,
                pendingPayloadCount: pendingPayloads.count
            )
        }
        guard !isDraining else { return }
        isDraining = true
        await drain()
    }

    func reset() {
        pendingPayloads.removeAll(keepingCapacity: false)
        isDraining = false
        flushPendingImmediately = false
        resetReportingBudgets()
    }

    func resetReportingBudgets() {
        outboundTransportDispatchReportBudget = 64
        outboundTransportSuccessReportBudget = 64
        outboundTransportDropReportBudget = 16
    }

    func finishDraining(pollNanoseconds: UInt64 = 10_000_000) async {
        flushPendingImmediately = true
        while isDraining || !pendingPayloads.isEmpty {
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }

    private func drain() async {
        while !pendingPayloads.isEmpty {
            let payload = await nextTransportPayload()
            guard let sendChunk = await waitForTransportIfNeeded() else {
                await reportFailure("audio send failed: websocket transport is not configured")
                pendingPayloads.removeAll(keepingCapacity: false)
                break
            }
            do {
                reportTransportDispatchIfNeeded(
                    payload: payload,
                    pendingPayloadCount: pendingPayloads.count
                )
                try await sendChunk(payload)
                reportTransportSendSucceededIfNeeded(
                    payload: payload,
                    pendingPayloadCount: pendingPayloads.count
                )
            } catch {
                await reportFailure("audio send failed: \(error.localizedDescription)")
                pendingPayloads.removeAll(keepingCapacity: false)
                break
            }
        }
        isDraining = false
    }

    private func nextTransportPayload() async -> String {
        await waitForBatchCollectionIfNeeded()

        let batchCount = min(maximumPayloadsPerMessage, pendingPayloads.count)
        let batch = Array(pendingPayloads.prefix(batchCount))
        pendingPayloads.removeFirst(batchCount)
        if pendingPayloads.isEmpty {
            flushPendingImmediately = false
        }
        return AudioChunkPayloadCodec.encode(batch)
    }

    private func waitForBatchCollectionIfNeeded() async {
        var waitedNanoseconds: UInt64 = 0
        while Self.shouldWaitForMorePayloads(
            pendingPayloadCount: pendingPayloads.count,
            maximumPayloadsPerMessage: maximumPayloadsPerMessage,
            flushRequested: flushPendingImmediately
        ), waitedNanoseconds < payloadBatchCollectionNanoseconds {
            let remainingNanoseconds = payloadBatchCollectionNanoseconds - waitedNanoseconds
            let sleepNanoseconds = min(payloadBatchCollectionPollNanoseconds, remainingNanoseconds)
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
            waitedNanoseconds += sleepNanoseconds
        }
    }

    nonisolated static func shouldWaitForMorePayloads(
        pendingPayloadCount: Int,
        maximumPayloadsPerMessage: Int,
        flushRequested: Bool = false
    ) -> Bool {
        guard !flushRequested else { return false }
        return pendingPayloadCount > 0 && pendingPayloadCount < maximumPayloadsPerMessage
    }

    private func waitForTransportIfNeeded() async -> (@Sendable (String) async throws -> Void)? {
        if let sendChunk {
            return sendChunk
        }

        for _ in 0 ..< transportAvailabilityMaxAttempts {
            try? await Task.sleep(nanoseconds: transportAvailabilityPollNanoseconds)
            if let sendChunk {
                return sendChunk
            }
        }

        return nil
    }

    private func reportTransportDispatchIfNeeded(
        payload: String,
        pendingPayloadCount: Int
    ) {
        guard outboundTransportDispatchReportBudget > 0 else { return }
        outboundTransportDispatchReportBudget -= 1
        guard let reportEvent else { return }
        let metadata = [
            "payloadLength": String(payload.count),
            "pendingPayloadCount": String(pendingPayloadCount),
            "transportDigest": AudioChunkPayloadCodec.transportDigest(payload),
            "decodedChunkCount": String(AudioChunkPayloadCodec.decode(payload).count),
        ]
        Task {
            await reportEvent("Dispatching outbound audio transport payload", metadata)
        }
    }

    private func reportTransportSendSucceededIfNeeded(
        payload: String,
        pendingPayloadCount: Int
    ) {
        guard outboundTransportSuccessReportBudget > 0 else { return }
        outboundTransportSuccessReportBudget -= 1
        guard let reportEvent else { return }
        let metadata = [
            "payloadLength": String(payload.count),
            "pendingPayloadCount": String(pendingPayloadCount),
            "transportDigest": AudioChunkPayloadCodec.transportDigest(payload),
            "decodedChunkCount": String(AudioChunkPayloadCodec.decode(payload).count),
        ]
        Task {
            await reportEvent("Delivered outbound audio transport payload", metadata)
        }
    }

    private func reportTransportDropIfNeeded(
        droppedPayloadCount: Int,
        pendingPayloadCount: Int
    ) {
        guard outboundTransportDropReportBudget > 0 else { return }
        outboundTransportDropReportBudget -= 1
        guard let reportEvent else { return }
        let metadata = [
            "droppedPayloadCount": String(droppedPayloadCount),
            "pendingPayloadCount": String(pendingPayloadCount),
            "maximumPendingPayloads": String(maximumPendingPayloads),
            "reason": "outbound-transport-backpressure",
        ]
        Task {
            await reportEvent("Dropped stale outbound audio transport payload", metadata)
        }
    }
}

struct CaptureRouteRefreshPlan: Equatable {
    let shouldStopEngine: Bool
    let shouldResetEngine: Bool
    let shouldRemoveInputTap: Bool
    let shouldRestartEngine: Bool

    static func forLiveTransmitRoute(
        engineIsRunning: Bool,
        inputTapInstalled: Bool
    ) -> CaptureRouteRefreshPlan {
        CaptureRouteRefreshPlan(
            shouldStopEngine: engineIsRunning,
            shouldResetEngine: engineIsRunning,
            shouldRemoveInputTap: inputTapInstalled,
            shouldRestartEngine: engineIsRunning || !engineIsRunning
        )
    }
}

struct CaptureTransmitStartPlan: Equatable {
    let shouldRefreshRoute: Bool

    static func forCurrentCapturePath(
        isCaptureReady: Bool,
        engineIsRunning: Bool,
        inputTapInstalled: Bool,
        hasCaptureConverter: Bool
    ) -> CaptureTransmitStartPlan {
        CaptureTransmitStartPlan(
            shouldRefreshRoute: !isCaptureReady || !engineIsRunning || !inputTapInstalled || !hasCaptureConverter
        )
    }
}

enum AudioChunkPayloadCodec {
    nonisolated static func encode(_ chunks: [String]) -> String {
        guard chunks.count > 1 else {
            return chunks.first ?? ""
        }

        let envelope: [String: Any] = [
            "kind": "pcm-batch-v1",
            "chunks": chunks,
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let string = String(data: data, encoding: .utf8) else {
            return chunks.first ?? ""
        }
        return string
    }

    nonisolated static func decode(_ payload: String) -> [String] {
        guard payload.first == "{",
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String,
              kind == "pcm-batch-v1",
              let chunks = object["chunks"] as? [String],
              !chunks.isEmpty else {
            return [payload]
        }

        return chunks
    }

    nonisolated static func transportDigest(_ payload: String, prefixBytes: Int = 6) -> String {
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.prefix(prefixBytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct PCMLevelMetrics: Equatable {
    let sampleCount: Int
    let nonZeroSampleCount: Int
    let peak: Double
    let rms: Double

    var isSilent: Bool {
        nonZeroSampleCount == 0 || peak == 0
    }

    var diagnosticMetadata: [String: String] {
        [
            "pcmSampleCount": String(sampleCount),
            "pcmNonZeroSamples": String(nonZeroSampleCount),
            "pcmPeak": Self.formatLevel(peak),
            "pcmRMS": Self.formatLevel(rms),
            "pcmSilent": String(isSilent),
        ]
    }

    nonisolated static func forBuffer(_ buffer: AVAudioPCMBuffer) -> PCMLevelMetrics? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        switch buffer.format.commonFormat {
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else { return nil }
            return collect(
                frameCount: frameCount,
                channelCount: channelCount,
                isInterleaved: buffer.format.isInterleaved
            ) { sampleIndex, channelIndex in
                let sample: Int16
                if buffer.format.isInterleaved {
                    sample = channelData.pointee[sampleIndex * channelCount + channelIndex]
                } else {
                    sample = channelData[channelIndex][sampleIndex]
                }
                return Double(Int(sample)) / 32768.0
            }
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else { return nil }
            return collect(
                frameCount: frameCount,
                channelCount: channelCount,
                isInterleaved: buffer.format.isInterleaved
            ) { sampleIndex, channelIndex in
                if buffer.format.isInterleaved {
                    return Double(channelData.pointee[sampleIndex * channelCount + channelIndex])
                } else {
                    return Double(channelData[channelIndex][sampleIndex])
                }
            }
        default:
            return nil
        }
    }

    nonisolated static func forInt16PCMData(_ data: Data) -> PCMLevelMetrics? {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
                return nil
            }
            return collect(sampleCount: sampleCount) { sampleIndex in
                Double(Int(baseAddress[sampleIndex])) / 32768.0
            }
        }
    }

    private nonisolated static func collect(
        frameCount: Int,
        channelCount: Int,
        isInterleaved _: Bool,
        sampleAt: (Int, Int) -> Double
    ) -> PCMLevelMetrics {
        collect(sampleCount: frameCount * channelCount) { sampleIndex in
            let frameIndex = sampleIndex / channelCount
            let channelIndex = sampleIndex % channelCount
            return sampleAt(frameIndex, channelIndex)
        }
    }

    private nonisolated static func collect(
        sampleCount: Int,
        sampleAt: (Int) -> Double
    ) -> PCMLevelMetrics {
        var nonZeroSampleCount = 0
        var peak = 0.0
        var squareSum = 0.0

        for sampleIndex in 0 ..< sampleCount {
            let sample = sampleAt(sampleIndex)
            let magnitude = abs(sample)
            if magnitude > 0 {
                nonZeroSampleCount += 1
            }
            peak = max(peak, magnitude)
            squareSum += sample * sample
        }

        return PCMLevelMetrics(
            sampleCount: sampleCount,
            nonZeroSampleCount: nonZeroSampleCount,
            peak: peak,
            rms: sqrt(squareSum / Double(sampleCount))
        )
    }

    private nonisolated static func formatLevel(_ level: Double) -> String {
        String(format: "%.6f", level)
    }
}

enum CaptureSendState: Equatable {
    case idle
    case sending
    case stopping(graceDeadlineNanoseconds: UInt64)

    static func shouldAcceptCapturedBuffer(
        _ state: CaptureSendState,
        nowNanoseconds: UInt64
    ) -> Bool {
        switch state {
        case .idle:
            return false
        case .sending:
            return true
        case .stopping(let graceDeadlineNanoseconds):
            return nowNanoseconds <= graceDeadlineNanoseconds
        }
    }
}

final class PCMWebSocketMediaSession: MediaSession {
    weak var delegate: MediaSessionDelegate?

    private(set) var state: MediaConnectionState = .idle {
        didSet {
            guard oldValue != state else { return }
            delegate?.mediaSession(self, didChange: state)
        }
    }

    private let reportEvent: (@Sendable (String, [String: String]) async -> Void)?
    private lazy var audioChunkSender =
        AudioChunkSender(
            sendChunk: initialSendAudioChunk,
            reportFailure: { [weak self] (message: String) in
                guard let self else { return }
                await MainActor.run {
                    self.state = .failed(message)
                }
            },
            reportEvent: { [weak self] (message: String, metadata: [String: String]) in
                guard let self else { return }
                await self.report(message, metadata: metadata)
            }
        )
    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let stateLock = NSLock()
    private let targetFormat: AVAudioFormat
    private var captureConverter: AVAudioConverter?
    private var playbackConverter: AVAudioConverter?
    private var isPlaybackReady = false
    private var isCaptureReady = false
    private var captureSendState: CaptureSendState = .idle
    private var captureSendCancellationGeneration: UInt64 = 0
    private var inputTapInstalled = false
    private var pendingPlaybackBuffers: [AVAudioPCMBuffer] = []
    private var pendingRemoteAudioChunks: [Data] = []
    private var scheduledPlaybackBufferCount = 0
    private var playbackStartTask: Task<Void, Never>?
    private var playbackNodeStartupReassertionTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private let maximumPendingPlaybackBuffers = 24
    private let maximumPendingRemoteAudioChunks = 24
    private let initialSendAudioChunk: (@Sendable (String) async throws -> Void)?
    private var currentSendAudioChunk: (@Sendable (String) async throws -> Void)?
    private var capturedBufferReportBudget = 3
    private var convertedBufferReportBudget = 3
    private var enqueuedPayloadReportBudget = 3
    private var activeAudioSessionOwnership: MediaSessionActivationMode?
    private let captureStopGraceNanoseconds: UInt64 = 120_000_000

    init(
        sendAudioChunk: (@Sendable (String) async throws -> Void)?,
        reportEvent: (@Sendable (String, [String: String]) async -> Void)? = nil
    ) {
        self.initialSendAudioChunk = sendAudioChunk
        self.currentSendAudioChunk = sendAudioChunk
        self.reportEvent = reportEvent
        self.targetFormat =
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )!

        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: targetFormat)
    }

    func updateSendAudioChunk(_ handler: (@Sendable (String) async throws -> Void)?) {
        currentSendAudioChunk = handler
        Task {
            await audioChunkSender.updateSendChunk(handler)
        }
        Task {
            await report(
                "Updated media session audio transport",
                metadata: ["configured": String(handler != nil)]
            )
        }
    }

    func start(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode
    ) async throws {
        if let existingStartTask = startTask {
            try await existingStartTask.value
        }

        let requiresCapture = startupMode == .interactive
        let playbackAlreadyReady = isPlaybackReady
        let captureAlreadyReady = isCaptureReady
        guard !playbackAlreadyReady || (requiresCapture && !captureAlreadyReady) else { return }

        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.performStart(
                activationMode: activationMode,
                startupMode: startupMode,
                playbackAlreadyReady: playbackAlreadyReady,
                captureAlreadyReady: captureAlreadyReady
            )
        }
        startTask = task

        defer {
            startTask = nil
        }

        try await task.value
    }

    private func performStart(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode,
        playbackAlreadyReady: Bool,
        captureAlreadyReady: Bool
    ) async throws {
        await report(
            "Media session start requested",
            metadata: [
                "activationMode": String(describing: activationMode),
                "startupMode": String(describing: startupMode),
                "playbackReady": String(playbackAlreadyReady),
                "captureReady": String(captureAlreadyReady)
            ]
        )
        state = .preparing
        try configureAudioSession(
            activationMode: activationMode,
            startupMode: startupMode
        )
        try preparePlaybackPathIfNeeded()
        try startPlaybackEngineIfNeeded()
        primeSystemActivatedPlaybackNodeIfNeeded(
            activationMode: activationMode,
            startupMode: startupMode,
            playbackAlreadyReady: playbackAlreadyReady
        )
        isPlaybackReady = true
        try drainPendingRemoteAudioChunksIfReady()

        let requiresCapture = startupMode == .interactive
        if requiresCapture {
            try prepareCapturePathIfNeeded()
            try installInputTapIfNeeded()
            try startCaptureEngineIfNeeded()
            isCaptureReady = true
        }

        state = .connected
        await report(
            "Media session start completed",
            metadata: [
                "activationMode": String(describing: activationMode),
                "startupMode": String(describing: startupMode),
                "captureReady": String(isCaptureReady),
                "playbackReady": String(isPlaybackReady)
            ]
        )
    }

    func startSendingAudio() async throws {
        let cancellationGeneration = currentCaptureSendCancellationGeneration()
        if !isPlaybackReady || !isCaptureReady {
            try await start(activationMode: .appManaged, startupMode: .interactive)
        }
        resetCaptureReportingBudgets()
        let captureStartPlan = CaptureTransmitStartPlan.forCurrentCapturePath(
            isCaptureReady: isCaptureReady,
            engineIsRunning: captureEngine.isRunning,
            inputTapInstalled: inputTapInstalled,
            hasCaptureConverter: captureConverter != nil
        )
        if captureStartPlan.shouldRefreshRoute {
            try refreshCapturePathForCurrentRoute()
        }
        await audioChunkSender.updateSendChunk(currentSendAudioChunk)
        await report(
            "Starting audio capture with transport state",
            metadata: ["configured": String(currentSendAudioChunk != nil)]
        )
        guard shouldEnableSendingAudio(
            expectedCancellationGeneration: cancellationGeneration
        ) else {
            await audioChunkSender.reset()
            await report(
                "Skipped enabling audio capture because transmit start was cancelled",
                metadata: ["reason": "stale-transmit-startup"]
            )
            return
        }
        await audioChunkSender.resetReportingBudgets()
        resetPlaybackForTransmit()
        setSendingAudio(true)
    }

    func stopSendingAudio() async throws {
        let stopGraceDeadline = beginCaptureStopGraceIfNeeded()
        if let stopGraceDeadline {
            try? await Task.sleep(nanoseconds: captureStopGraceNanoseconds)
            finishCaptureStopGraceIfNeeded(expectedDeadlineNanoseconds: stopGraceDeadline)
        }
        await audioChunkSender.finishDraining()
    }

    func abortSendingAudio() async {
        cancelCaptureSendState()
        await audioChunkSender.reset()
        await report(
            "Aborted audio capture without draining",
            metadata: ["reason": "stale-transmit-startup"]
        )
    }

    func receiveRemoteAudioChunk(_ payload: String) async {
        let payloads = AudioChunkPayloadCodec.decode(payload)
        guard !payloads.isEmpty else { return }

        var decodedChunks: [Data] = []
        decodedChunks.reserveCapacity(payloads.count)
        for payload in payloads {
            guard !payload.isEmpty else { continue }
            guard let data = Data(base64Encoded: payload) else {
                state = .failed("received invalid audio chunk")
                return
            }
            decodedChunks.append(data)
        }

        guard !decodedChunks.isEmpty else { return }
        if !isPlaybackReady {
            for chunk in decodedChunks {
                enqueuePendingRemoteAudioChunk(chunk)
            }
            await report(
                "Queued remote audio chunk until playback ready",
                metadata: ["pendingChunkCount": String(pendingRemoteAudioChunkCount())]
            )
            return
        }
        do {
            for chunk in decodedChunks {
                try schedulePlayback(for: chunk)
            }
        } catch {
            await report(
                "Receive playback failed",
                metadata: ["error": error.localizedDescription]
            )
            state = .failed("playback failed: \(error.localizedDescription)")
        }
    }

    func audioRouteDidChange() async {
        guard isPlaybackReady || isCaptureReady else { return }
        do {
            playbackConverter = nil
            if isPlaybackReady {
                try preparePlaybackPathIfNeeded()
                try startPlaybackEngineIfNeeded()
                reassertPlaybackNodeAfterRouteChangeIfNeeded()
            }
            if isCaptureReady {
                try refreshCapturePathForCurrentRoute()
            }
            await report(
                "Media session refreshed for audio route change",
                metadata: audioSessionMetadata(AVAudioSession.sharedInstance())
            )
        } catch {
            await report(
                "Media session audio route refresh failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func hasPendingPlayback() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !pendingRemoteAudioChunks.isEmpty
            || !pendingPlaybackBuffers.isEmpty
            || scheduledPlaybackBufferCount > 0
    }

    func close(deactivateAudioSession: Bool) {
        stateLock.lock()
        noteCaptureSendCancellationLocked()
        captureSendState = .idle
        stateLock.unlock()
        Task {
            await audioChunkSender.reset()
        }
        startTask?.cancel()
        startTask = nil
        playbackStartTask?.cancel()
        playbackStartTask = nil
        playbackNodeStartupReassertionTask?.cancel()
        playbackNodeStartupReassertionTask = nil
        pendingPlaybackBuffers.removeAll(keepingCapacity: false)
        pendingRemoteAudioChunks.removeAll(keepingCapacity: false)
        scheduledPlaybackBufferCount = 0

        if inputTapInstalled {
            captureEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        playerNode.stop()
        playerNode.reset()
        captureEngine.stop()
        playbackEngine.stop()
        captureConverter = nil
        playbackConverter = nil
        isPlaybackReady = false
        isCaptureReady = false
        deactivateAudioSessionIfNeeded(deactivateAudioSession: deactivateAudioSession)
        state = .closed
    }

    private func deactivateAudioSessionIfNeeded(deactivateAudioSession: Bool) {
        guard activeAudioSessionOwnership == .appManaged else {
            activeAudioSessionOwnership = nil
            return
        }
        activeAudioSessionOwnership = nil
        guard deactivateAudioSession else {
            Task {
                await report(
                    "Preserved active audio session during media close",
                    metadata: [:]
                )
            }
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
            Task {
                await report(
                    "Audio session deactivated for media close",
                    metadata: audioSessionMetadata(session)
                )
            }
        } catch {
            Task {
                await report(
                    "Failed to deactivate audio session for media close",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func configureAudioSession(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode
    ) throws {
        let session = AVAudioSession.sharedInstance()
        let configuration = MediaSessionAudioPolicy.configuration(
            activationMode: activationMode,
            startupMode: startupMode
        )
        guard configuration.shouldConfigureSession else {
            activeAudioSessionOwnership = nil
            Task {
                await report(
                    "Preserved system-managed audio session configuration",
                    metadata: audioSessionMetadata(session).merging(
                        [
                            "activationMode": String(describing: activationMode),
                            "startupMode": String(describing: startupMode),
                        ],
                        uniquingKeysWith: { _, new in new }
                    )
                )
            }
            return
        }
        try session.setCategory(
            configuration.category,
            mode: configuration.mode,
            options: configuration.options
        )
        try session.setPreferredSampleRate(targetFormat.sampleRate)
        try session.setPreferredIOBufferDuration(0.04)
        if configuration.shouldActivateSession {
            try session.setActive(true)
        }
        activeAudioSessionOwnership = configuration.shouldActivateSession ? activationMode : nil
        Task {
            await report(
                "Audio session configured",
                metadata: audioSessionMetadata(session).merging(
                    ["activationMode": String(describing: activationMode)],
                    uniquingKeysWith: { _, new in new }
                )
            )
        }
    }

    private func setSendingAudio(_ newValue: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        captureSendState = newValue ? .sending : .idle
    }

    private func cancelCaptureSendState() {
        stateLock.lock()
        defer { stateLock.unlock() }
        noteCaptureSendCancellationLocked()
        captureSendState = .idle
    }

    private func currentCaptureSendCancellationGeneration() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captureSendCancellationGeneration
    }

    private func shouldEnableSendingAudio(expectedCancellationGeneration: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captureSendCancellationGeneration == expectedCancellationGeneration
    }

    private func noteCaptureSendCancellationLocked() {
        captureSendCancellationGeneration &+= 1
    }

    private func beginCaptureStopGraceIfNeeded() -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        noteCaptureSendCancellationLocked()
        guard case .sending = captureSendState else {
            captureSendState = .idle
            return nil
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + captureStopGraceNanoseconds
        captureSendState = .stopping(graceDeadlineNanoseconds: deadline)
        return deadline
    }

    private func finishCaptureStopGraceIfNeeded(expectedDeadlineNanoseconds: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case .stopping(let currentDeadlineNanoseconds) = captureSendState,
              currentDeadlineNanoseconds == expectedDeadlineNanoseconds else {
            return
        }
        captureSendState = .idle
    }

    private func shouldSendCapturedBuffer(nowNanoseconds: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        let shouldAccept = CaptureSendState.shouldAcceptCapturedBuffer(
            captureSendState,
            nowNanoseconds: nowNanoseconds
        )
        if !shouldAccept,
           case .stopping = captureSendState {
            captureSendState = .idle
        }
        return shouldAccept
    }

    private func prepareCapturePathIfNeeded() throws {
        let inputFormat = captureEngine.inputNode.inputFormat(forBus: 0)
        if captureConverter == nil {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw NSError(domain: "PCMWebSocketMediaSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "unable to create capture converter"])
            }
            captureConverter = converter
        }
    }

    private func refreshCapturePathForCurrentRoute() throws {
        let inputNode = captureEngine.inputNode
        let plan = CaptureRouteRefreshPlan.forLiveTransmitRoute(
            engineIsRunning: captureEngine.isRunning,
            inputTapInstalled: inputTapInstalled
        )
        if plan.shouldStopEngine {
            captureEngine.stop()
        }
        if plan.shouldResetEngine {
            captureEngine.reset()
        }
        if plan.shouldRemoveInputTap {
            inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        captureConverter = nil
        try prepareCapturePathIfNeeded()
        try installInputTapIfNeeded()
        if plan.shouldRestartEngine {
            try startCaptureEngineIfNeeded()
        }
        awaitReportCaptureRouteRefresh()
    }

    private func preparePlaybackPathIfNeeded() throws {
        let outputFormat = playerNode.outputFormat(forBus: 0)
        if outputFormat != targetFormat && playbackConverter == nil {
            playbackConverter = AVAudioConverter(from: targetFormat, to: outputFormat)
        }
    }

    private func installInputTapIfNeeded() throws {
        guard !inputTapInstalled else { return }

        let inputNode = captureEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_920, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer)
        }
        inputTapInstalled = true
    }

    private func awaitReportCaptureRouteRefresh() {
        let inputFormat = captureEngine.inputNode.inputFormat(forBus: 0)
        Task {
            await report(
                "Refreshed capture path for current audio route",
                metadata: [
                    "sampleRate": String(inputFormat.sampleRate),
                    "channelCount": String(inputFormat.channelCount)
                ]
            )
        }
    }

    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        let nowNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard shouldSendCapturedBuffer(nowNanoseconds: nowNanoseconds), state == .connected else { return }
        reportCapturedBufferIfNeeded(buffer)
        guard let convertedBuffer = convertCapturedBuffer(buffer) else { return }
        reportConvertedBufferIfNeeded(convertedBuffer)
        guard let payload = payloadFromPCMBuffer(convertedBuffer) else { return }
        reportEnqueuedPayloadIfNeeded(payload)

        Task {
            await audioChunkSender.enqueue(payload)
        }
    }

    private func reportCapturedBufferIfNeeded(_ buffer: AVAudioPCMBuffer) {
        guard capturedBufferReportBudget > 0 else { return }
        capturedBufferReportBudget -= 1
        var metadata = [
            "frameLength": String(buffer.frameLength),
            "sampleRate": String(buffer.format.sampleRate),
            "channelCount": String(buffer.format.channelCount),
            "pcmFormat": String(describing: buffer.format.commonFormat),
            "interleaved": String(buffer.format.isInterleaved),
        ]
        if let levelMetrics = PCMLevelMetrics.forBuffer(buffer) {
            metadata.merge(levelMetrics.diagnosticMetadata) { _, new in new }
        }
        Task {
            await report(
                "Captured local audio buffer",
                metadata: metadata
            )
        }
    }

    private func reportConvertedBufferIfNeeded(_ buffer: AVAudioPCMBuffer) {
        guard convertedBufferReportBudget > 0 else { return }
        convertedBufferReportBudget -= 1
        var metadata = [
            "frameLength": String(buffer.frameLength),
            "sampleRate": String(buffer.format.sampleRate),
            "channelCount": String(buffer.format.channelCount),
            "pcmFormat": String(describing: buffer.format.commonFormat),
            "interleaved": String(buffer.format.isInterleaved),
        ]
        if let levelMetrics = PCMLevelMetrics.forBuffer(buffer) {
            metadata.merge(levelMetrics.diagnosticMetadata) { _, new in new }
        }
        Task {
            await report(
                "Converted local audio buffer",
                metadata: metadata
            )
        }
    }

    private func reportEnqueuedPayloadIfNeeded(_ payload: String) {
        guard enqueuedPayloadReportBudget > 0 else { return }
        enqueuedPayloadReportBudget -= 1
        var metadata = [
            "base64Length": String(payload.count),
            "payloadDigest": AudioChunkPayloadCodec.transportDigest(payload),
        ]
        if let data = Data(base64Encoded: payload),
           let levelMetrics = PCMLevelMetrics.forInt16PCMData(data) {
            metadata.merge(levelMetrics.diagnosticMetadata) { _, new in new }
        }
        Task {
            await report(
                "Enqueued outbound audio chunk",
                metadata: metadata
            )
        }
    }

    private func resetCaptureReportingBudgets() {
        capturedBufferReportBudget = 3
        convertedBufferReportBudget = 3
        enqueuedPayloadReportBudget = 3
    }


    private func convertCapturedBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = captureConverter else { return nil }
        let outputFrameCapacity =
            AVAudioFrameCount(
                (Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate).rounded(.up)
            ) + 1
        guard let converted =
            AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
            return nil
        }

        var localBuffer: AVAudioPCMBuffer? = buffer
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if let current = localBuffer {
                outStatus.pointee = .haveData
                localBuffer = nil
                return current
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        guard error == nil else { return nil }
        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return converted.frameLength > 0 ? converted : nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }

    private func payloadFromPCMBuffer(_ buffer: AVAudioPCMBuffer) -> String? {
        guard let channelData = buffer.int16ChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let bytes = Data(
            bytes: channelData.pointee,
            count: frameCount * MemoryLayout<Int16>.size
        )
        return bytes.base64EncodedString()
    }

    private func schedulePlayback(for data: Data) throws {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else { return }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return
        }
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channelData = sourceBuffer.int16ChannelData else { return }
        data.copyBytes(
            to: UnsafeMutableRawBufferPointer(
                start: channelData.pointee,
                count: data.count
            )
        )

        let playbackBuffer = try makePlaybackBuffer(from: sourceBuffer)
        try startPlaybackEngineIfNeeded()
        switch Self.playbackBufferReceivePlan(
            isPlayerNodePlaying: playerNode.isPlaying,
            playbackIOCycleAvailable: playbackIOCycleAvailable
        ) {
        case .deferUntilIOCycle:
            enqueuePendingPlaybackBuffer(playbackBuffer)
            requestPlaybackStartWhenReady()
            Task {
                await report(
                    "Deferred playback node start until IO cycle",
                    metadata: ["pendingBufferCount": String(pendingPlaybackBufferCount())]
                )
            }
            return
        case .scheduleAndStartNode:
            schedulePlaybackBuffer(playbackBuffer)
            startPlaybackNode()
            drainPendingPlaybackBuffers()
        case .scheduleOnly:
            schedulePlaybackBuffer(playbackBuffer)
        }
    }

    private func schedulePlaybackBuffer(_ playbackBuffer: AVAudioPCMBuffer) {
        stateLock.lock()
        scheduledPlaybackBufferCount += 1
        stateLock.unlock()
        playerNode.scheduleBuffer(playbackBuffer) { [weak self] in
            self?.markScheduledPlaybackBufferCompleted()
        }
        playerNode.prepare(withFrameCount: max(playbackBuffer.frameLength, 512))
        schedulePlaybackNodeStartupReassertion(reason: "playback-buffer-scheduled")
        var metadata = [
            "frameLength": String(playbackBuffer.frameLength),
            "sampleRate": String(playbackBuffer.format.sampleRate),
            "channelCount": String(playbackBuffer.format.channelCount),
            "pcmFormat": String(describing: playbackBuffer.format.commonFormat),
            "interleaved": String(playbackBuffer.format.isInterleaved),
        ]
        if let levelMetrics = PCMLevelMetrics.forBuffer(playbackBuffer) {
            metadata.merge(levelMetrics.diagnosticMetadata) { _, new in new }
        }
        Task {
            await report(
                "Playback buffer scheduled",
                metadata: metadata
            )
        }
    }

    private func markScheduledPlaybackBufferCompleted() {
        stateLock.lock()
        scheduledPlaybackBufferCount = max(0, scheduledPlaybackBufferCount - 1)
        stateLock.unlock()
    }

    static func playbackBufferReceivePlan(
        isPlayerNodePlaying: Bool,
        playbackIOCycleAvailable: Bool
    ) -> PlaybackBufferReceivePlan {
        if isPlayerNodePlaying {
            return .scheduleOnly
        }
        guard playbackIOCycleAvailable else { return .deferUntilIOCycle }
        return .scheduleAndStartNode
    }

    static func shouldPrimeSystemActivatedPlaybackNode(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode,
        playbackAlreadyReady: Bool
    ) -> Bool {
        activationMode == .systemActivated
            && startupMode == .playbackOnly
            && !playbackAlreadyReady
    }

    private func primeSystemActivatedPlaybackNodeIfNeeded(
        activationMode: MediaSessionActivationMode,
        startupMode: MediaSessionStartupMode,
        playbackAlreadyReady: Bool
    ) {
        guard Self.shouldPrimeSystemActivatedPlaybackNode(
            activationMode: activationMode,
            startupMode: startupMode,
            playbackAlreadyReady: playbackAlreadyReady
        ) else { return }
        startPlaybackNode(reason: "system-activated-playback-prime")
        schedulePlaybackNodeStartupReassertion(reason: "system-activated-playback-prime")
    }

    private func startPlaybackNode(reason: String = "playback-buffer-scheduled") {
        playerNode.play()
        Task {
            await report("Playback node started", metadata: ["reason": reason])
        }
    }

    private func makePlaybackBuffer(from sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter = playbackConverter else { return sourceBuffer }

        let outputFormat = playerNode.outputFormat(forBus: 0)
        let outputFrameCapacity =
            AVAudioFrameCount(
                (Double(sourceBuffer.frameLength) * outputFormat.sampleRate / sourceBuffer.format.sampleRate).rounded(.up)
            ) + 1
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            throw NSError(domain: "PCMWebSocketMediaSession", code: 2, userInfo: [NSLocalizedDescriptionKey: "unable to allocate playback buffer"])
        }

        var localBuffer: AVAudioPCMBuffer? = sourceBuffer
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            if let current = localBuffer {
                outStatus.pointee = .haveData
                localBuffer = nil
                return current
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if let error {
            throw error
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return converted
        case .error:
            throw NSError(domain: "PCMWebSocketMediaSession", code: 3, userInfo: [NSLocalizedDescriptionKey: "playback conversion failed"])
        @unknown default:
            throw NSError(domain: "PCMWebSocketMediaSession", code: 4, userInfo: [NSLocalizedDescriptionKey: "unknown playback conversion status"])
        }
    }

    private func resetPlaybackForTransmit() {
        playbackStartTask?.cancel()
        playbackStartTask = nil
        playbackNodeStartupReassertionTask?.cancel()
        playbackNodeStartupReassertionTask = nil
        pendingPlaybackBuffers.removeAll(keepingCapacity: false)
        playerNode.stop()
        playerNode.reset()
    }

    private func startCaptureEngineIfNeeded() throws {
        if !captureEngine.isRunning {
            try captureEngine.start()
            Task {
                await report("Capture engine started", metadata: [:])
            }
        }
    }

    private func startPlaybackEngineIfNeeded() throws {
        if !playbackEngine.isRunning {
            playbackEngine.prepare()
            try playbackEngine.start()
            Task {
                await report("Playback engine started", metadata: [:])
            }
        }
    }

    private var playbackIOCycleAvailable: Bool {
        playbackEngine.outputNode.lastRenderTime != nil
            || playbackEngine.mainMixerNode.lastRenderTime != nil
    }

    private func enqueuePendingPlaybackBuffer(_ playbackBuffer: AVAudioPCMBuffer) {
        pendingPlaybackBuffers.append(playbackBuffer)
        if pendingPlaybackBuffers.count > maximumPendingPlaybackBuffers {
            pendingPlaybackBuffers.removeFirst(pendingPlaybackBuffers.count - maximumPendingPlaybackBuffers)
        }
    }

    private func pendingPlaybackBufferCount() -> Int {
        pendingPlaybackBuffers.count
    }

    private func enqueuePendingRemoteAudioChunk(_ data: Data) {
        pendingRemoteAudioChunks.append(data)
        if pendingRemoteAudioChunks.count > maximumPendingRemoteAudioChunks {
            pendingRemoteAudioChunks.removeFirst(
                pendingRemoteAudioChunks.count - maximumPendingRemoteAudioChunks
            )
        }
    }

    private func pendingRemoteAudioChunkCount() -> Int {
        pendingRemoteAudioChunks.count
    }

    private func drainPendingRemoteAudioChunksIfReady() throws {
        guard isPlaybackReady else { return }
        guard !pendingRemoteAudioChunks.isEmpty else { return }
        let chunks = pendingRemoteAudioChunks
        pendingRemoteAudioChunks.removeAll(keepingCapacity: false)
        for chunk in chunks {
            try schedulePlayback(for: chunk)
        }
    }

    private func drainPendingPlaybackBuffers() {
        guard playerNode.isPlaying else { return }
        guard !pendingPlaybackBuffers.isEmpty else { return }
        let buffers = pendingPlaybackBuffers
        pendingPlaybackBuffers.removeAll(keepingCapacity: false)
        for buffer in buffers {
            schedulePlaybackBuffer(buffer)
        }
    }

    private func reassertPlaybackNodeAfterRouteChangeIfNeeded() {
        reassertPlaybackNodeIfNeeded(
            reason: "audio-route-change",
            message: "Playback node reasserted after audio route change"
        )
    }

    private func reassertPlaybackNodeIfNeeded(reason: String, message: String) {
        guard shouldReassertPlaybackNode() else { return }
        playerNode.play()
        drainPendingPlaybackBuffers()
        Task {
            await report(
                message,
                metadata: [
                    "reason": reason,
                    "pendingBufferCount": String(pendingPlaybackBufferCount()),
                    "scheduledBufferCount": String(scheduledPlaybackBufferCountSnapshot()),
                ]
            )
        }
    }

    private func shouldReassertPlaybackNode() -> Bool {
        playerNode.isPlaying
            || pendingPlaybackBufferCount() > 0
            || scheduledPlaybackBufferCountSnapshot() > 0
    }

    private func scheduledPlaybackBufferCountSnapshot() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return scheduledPlaybackBufferCount
    }

    private func schedulePlaybackNodeStartupReassertion(reason: String) {
        guard playbackNodeStartupReassertionTask == nil else { return }
        playbackNodeStartupReassertionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.playbackNodeStartupReassertionTask = nil }
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self.reassertPlaybackNodeIfNeeded(
                reason: reason,
                message: "Playback node startup reasserted"
            )
        }
    }

    private func requestPlaybackStartWhenReady() {
        guard playbackStartTask == nil else { return }
        playbackStartTask = Task { [weak self] in
            guard let self else { return }
            defer { self.playbackStartTask = nil }
            for attempt in 1...25 {
                if Task.isCancelled { return }
                if self.playerNode.isPlaying {
                    self.drainPendingPlaybackBuffers()
                    return
                }
                if self.playbackIOCycleAvailable {
                    if !self.pendingPlaybackBuffers.isEmpty {
                        let buffers = self.pendingPlaybackBuffers
                        self.pendingPlaybackBuffers.removeAll(keepingCapacity: false)
                        for buffer in buffers {
                            self.schedulePlaybackBuffer(buffer)
                        }
                    }
                    self.playerNode.play()
                    await self.report(
                        "Playback node started after IO cycle wait",
                        metadata: ["attempt": String(attempt)]
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            await self.report(
                "Playback node still waiting for IO cycle",
                metadata: ["pendingBufferCount": String(self.pendingPlaybackBufferCount())]
            )
        }
    }

    private func report(_ message: String, metadata: [String: String]) async {
        await reportEvent?(message, metadata)
    }

    private func audioSessionMetadata(_ session: AVAudioSession) -> [String: String] {
        let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ",")
        let inputs = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
        let outputNames = session.currentRoute.outputs.map(\.portName).joined(separator: ",")
        let inputNames = session.currentRoute.inputs.map(\.portName).joined(separator: ",")
        let availableInputs =
            session.availableInputs?
                .map { "\($0.portName):\($0.portType.rawValue)" }
                .joined(separator: ",")
            ?? ""
        return [
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "categoryOptions": String(session.categoryOptions.rawValue),
            "sampleRate": String(session.sampleRate),
            "outputs": outputs.isEmpty ? "none" : outputs,
            "outputNames": outputNames.isEmpty ? "none" : outputNames,
            "inputs": inputs.isEmpty ? "none" : inputs,
            "inputNames": inputNames.isEmpty ? "none" : inputNames,
            "availableInputs": availableInputs.isEmpty ? "none" : availableInputs
        ]
    }
}
