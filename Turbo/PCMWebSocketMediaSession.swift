import Foundation
import AVFAudio

enum PlaybackBufferReceivePlan: Equatable {
    case deferUntilIOCycle
    case scheduleAndStartNode
    case scheduleOnly
}

actor AudioChunkSender {
    private var sendChunk: (@Sendable (String) async throws -> Void)?
    private let reportFailure: @Sendable (String) async -> Void
    private let reportEvent: (@Sendable (String, [String: String]) async -> Void)?
    // Wake transmit can legitimately buffer a few seconds of speech while the
    // background receiver re-establishes its playback path after PTT activation.
    private let maximumPendingPayloads = 128
    private let maximumPayloadsPerMessage = 4
    private let payloadBatchCollectionNanoseconds: UInt64 = 220_000_000
    private let transportAvailabilityPollNanoseconds: UInt64 = 50_000_000
    private let transportAvailabilityMaxAttempts = 20
    private var pendingPayloads: [String] = []
    private var isDraining = false
    private var outboundTransportDispatchReportBudget = 3
    private var outboundTransportSuccessReportBudget = 3

    init(
        sendChunk: (@Sendable (String) async throws -> Void)?,
        reportFailure: @escaping @Sendable (String) async -> Void,
        reportEvent: (@Sendable (String, [String: String]) async -> Void)? = nil
    ) {
        self.sendChunk = sendChunk
        self.reportFailure = reportFailure
        self.reportEvent = reportEvent
    }

    func updateSendChunk(_ handler: (@Sendable (String) async throws -> Void)?) {
        sendChunk = handler
    }

    func enqueue(_ payload: String) async {
        pendingPayloads.append(payload)
        if pendingPayloads.count > maximumPendingPayloads {
            pendingPayloads.removeFirst(pendingPayloads.count - maximumPendingPayloads)
        }
        guard !isDraining else { return }
        isDraining = true
        await drain()
    }

    func reset() {
        pendingPayloads.removeAll(keepingCapacity: false)
        isDraining = false
        outboundTransportDispatchReportBudget = 3
        outboundTransportSuccessReportBudget = 3
    }

    func finishDraining(pollNanoseconds: UInt64 = 10_000_000) async {
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
                await reportTransportDispatchIfNeeded(
                    payload: payload,
                    pendingPayloadCount: pendingPayloads.count
                )
                try await sendChunk(payload)
                await reportTransportSendSucceededIfNeeded(
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
        if Self.shouldWaitForMorePayloads(
            pendingPayloadCount: pendingPayloads.count,
            maximumPayloadsPerMessage: maximumPayloadsPerMessage
        ) {
            try? await Task.sleep(nanoseconds: payloadBatchCollectionNanoseconds)
        }

        let batchCount = min(maximumPayloadsPerMessage, pendingPayloads.count)
        let batch = Array(pendingPayloads.prefix(batchCount))
        pendingPayloads.removeFirst(batchCount)
        return AudioChunkPayloadCodec.encode(batch)
    }

    nonisolated static func shouldWaitForMorePayloads(
        pendingPayloadCount: Int,
        maximumPayloadsPerMessage: Int
    ) -> Bool {
        pendingPayloadCount > 0 && pendingPayloadCount < maximumPayloadsPerMessage
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
    ) async {
        guard outboundTransportDispatchReportBudget > 0 else { return }
        outboundTransportDispatchReportBudget -= 1
        await reportEvent?(
            "Dispatching outbound audio transport payload",
            [
                "payloadLength": String(payload.count),
                "pendingPayloadCount": String(pendingPayloadCount),
            ]
        )
    }

    private func reportTransportSendSucceededIfNeeded(
        payload: String,
        pendingPayloadCount: Int
    ) async {
        guard outboundTransportSuccessReportBudget > 0 else { return }
        outboundTransportSuccessReportBudget -= 1
        await reportEvent?(
            "Delivered outbound audio transport payload",
            [
                "payloadLength": String(payload.count),
                "pendingPayloadCount": String(pendingPayloadCount),
            ]
        )
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
    private var isSendingAudio = false
    private var inputTapInstalled = false
    private var pendingPlaybackBuffers: [AVAudioPCMBuffer] = []
    private var pendingRemoteAudioChunks: [Data] = []
    private var playbackStartTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private let maximumPendingPlaybackBuffers = 24
    private let maximumPendingRemoteAudioChunks = 24
    private let initialSendAudioChunk: (@Sendable (String) async throws -> Void)?
    private var currentSendAudioChunk: (@Sendable (String) async throws -> Void)?
    private var capturedBufferReportBudget = 3
    private var convertedBufferReportBudget = 3
    private var enqueuedPayloadReportBudget = 3
    private var activeAudioSessionOwnership: MediaSessionActivationMode?

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
        resetPlaybackForTransmit()
        setSendingAudio(true)
    }

    func stopSendingAudio() async throws {
        setSendingAudio(false)
        await audioChunkSender.finishDraining()
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

    func close(deactivateAudioSession: Bool) {
        stateLock.lock()
        isSendingAudio = false
        stateLock.unlock()
        Task {
            await audioChunkSender.reset()
        }
        startTask?.cancel()
        startTask = nil
        playbackStartTask?.cancel()
        playbackStartTask = nil
        pendingPlaybackBuffers.removeAll(keepingCapacity: false)
        pendingRemoteAudioChunks.removeAll(keepingCapacity: false)

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
        isSendingAudio = newValue
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
        stateLock.lock()
        let shouldSend = isSendingAudio
        stateLock.unlock()
        guard shouldSend, state == .connected else { return }
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
        Task {
            await report(
                "Captured local audio buffer",
                metadata: [
                    "frameLength": String(buffer.frameLength),
                    "sampleRate": String(buffer.format.sampleRate),
                    "channelCount": String(buffer.format.channelCount)
                ]
            )
        }
    }

    private func reportConvertedBufferIfNeeded(_ buffer: AVAudioPCMBuffer) {
        guard convertedBufferReportBudget > 0 else { return }
        convertedBufferReportBudget -= 1
        Task {
            await report(
                "Converted local audio buffer",
                metadata: [
                    "frameLength": String(buffer.frameLength),
                    "sampleRate": String(buffer.format.sampleRate),
                    "channelCount": String(buffer.format.channelCount)
                ]
            )
        }
    }

    private func reportEnqueuedPayloadIfNeeded(_ payload: String) {
        guard enqueuedPayloadReportBudget > 0 else { return }
        enqueuedPayloadReportBudget -= 1
        Task {
            await report(
                "Enqueued outbound audio chunk",
                metadata: ["base64Length": String(payload.count)]
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
        playerNode.scheduleBuffer(playbackBuffer, completionHandler: nil)
        Task {
            await report(
                "Playback buffer scheduled",
                metadata: [
                    "frameLength": String(playbackBuffer.frameLength),
                    "sampleRate": String(playbackBuffer.format.sampleRate)
                ]
            )
        }
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

    private func startPlaybackNode() {
        playerNode.play()
        Task {
            await report("Playback node started", metadata: [:])
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
        return [
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "sampleRate": String(session.sampleRate),
            "outputs": outputs.isEmpty ? "none" : outputs,
            "inputs": inputs.isEmpty ? "none" : inputs
        ]
    }
}
