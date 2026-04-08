import Foundation
import AVFAudio

actor AudioChunkSender {
    private let sendChunk: @Sendable (String) async throws -> Void
    private let reportFailure: @Sendable (String) async -> Void
    private let minimumSpacingNanoseconds: UInt64 = 100_000_000
    private var latestPayload: String?
    private var isDraining = false

    init(
        sendChunk: @escaping @Sendable (String) async throws -> Void,
        reportFailure: @escaping @Sendable (String) async -> Void
    ) {
        self.sendChunk = sendChunk
        self.reportFailure = reportFailure
    }

    func enqueue(_ payload: String) async {
        latestPayload = payload
        guard !isDraining else { return }
        isDraining = true
        await drain()
    }

    func reset() {
        latestPayload = nil
        isDraining = false
    }

    private func drain() async {
        while let payload = latestPayload {
            latestPayload = nil
            do {
                try await sendChunk(payload)
            } catch {
                await reportFailure("audio send failed: \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: minimumSpacingNanoseconds)
        }
        isDraining = false
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

    private let sendAudioChunk: @Sendable (String) async throws -> Void
    private lazy var audioChunkSender =
        AudioChunkSender(
            sendChunk: sendAudioChunk,
            reportFailure: { [weak self] message in
                guard let self else { return }
                await MainActor.run {
                    self.state = .failed(message)
                }
            }
        )
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let stateLock = NSLock()
    private let targetFormat: AVAudioFormat
    private var captureConverter: AVAudioConverter?
    private var playbackConverter: AVAudioConverter?
    private var isStarted = false
    private var isSendingAudio = false
    private var inputTapInstalled = false

    init(sendAudioChunk: @escaping @Sendable (String) async throws -> Void) {
        self.sendAudioChunk = sendAudioChunk
        self.targetFormat =
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16_000,
                channels: 1,
                interleaved: true
            )!

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: targetFormat)
    }

    func start() async throws {
        guard !isStarted else { return }
        state = .preparing
        try configureAudioSession()
        try prepareConverters()
        try installInputTapIfNeeded()
        try startEngineIfNeeded()
        isStarted = true
        state = .connected
    }

    func startSendingAudio() async throws {
        if !isStarted {
            try await start()
        }
        setSendingAudio(true)
    }

    func stopSendingAudio() async throws {
        setSendingAudio(false)
        await audioChunkSender.reset()
    }

    func receiveRemoteAudioChunk(_ payload: String) async {
        guard !payload.isEmpty else { return }
        guard let data = Data(base64Encoded: payload) else {
            state = .failed("received invalid audio chunk")
            return
        }
        do {
            if !isStarted {
                try await start()
            }
            try schedulePlayback(for: data)
        } catch {
            state = .failed("playback failed: \(error.localizedDescription)")
        }
    }

    func close() {
        stateLock.lock()
        isSendingAudio = false
        stateLock.unlock()
        Task {
            await audioChunkSender.reset()
        }

        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        playerNode.stop()
        engine.stop()
        captureConverter = nil
        playbackConverter = nil
        isStarted = false
        state = .closed
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(targetFormat.sampleRate)
        try session.setPreferredIOBufferDuration(0.04)
        try session.setActive(true)
    }

    private func setSendingAudio(_ newValue: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        isSendingAudio = newValue
    }

    private func prepareConverters() throws {
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        if captureConverter == nil {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw NSError(domain: "PCMWebSocketMediaSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "unable to create capture converter"])
            }
            captureConverter = converter
        }

        let outputFormat = playerNode.outputFormat(forBus: 0)
        if outputFormat != targetFormat && playbackConverter == nil {
            playbackConverter = AVAudioConverter(from: targetFormat, to: outputFormat)
        }
    }

    private func installInputTapIfNeeded() throws {
        guard !inputTapInstalled else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_920, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer)
        }
        inputTapInstalled = true
    }

    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let shouldSend = isSendingAudio
        stateLock.unlock()
        guard shouldSend, state == .connected else { return }
        guard let convertedBuffer = convertCapturedBuffer(buffer) else { return }
        guard let payload = payloadFromPCMBuffer(convertedBuffer) else { return }

        Task {
            await audioChunkSender.enqueue(payload)
        }
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
        try startEngineIfNeeded()
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(playbackBuffer, completionHandler: nil)
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

    private func startEngineIfNeeded() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }
}
