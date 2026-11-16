import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Observation

/// Dictation into the message field, with a speech model the app runs itself.
///
/// The model is Parakeet (NVIDIA's speech recognizer, in a 220 MB build), fetched
/// the first time dictation is used and kept on the device. Nothing that is said
/// leaves the phone, and the only permission asked for is the microphone.
///
/// While listening, everything heard so far is transcribed again about once a
/// second, so the text on screen can still correct itself; stopping runs one
/// last pass over the whole recording.
@MainActor
@Observable
final class Dictation {
    private(set) var isListening = false
    /// What has been heard since listening started.
    private(set) var transcript = ""
    /// Shown while the speech model is being fetched or loaded.
    private(set) var status: String?
    var error: String?

    /// Dictation stops by itself after this long.
    private static let longestSeconds = 300.0

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let recording = Recording()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isStarting = false

    func toggle() {
        if isListening {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isListening, !isStarting else { return }
        isStarting = true
        defer {
            isStarting = false
            status = nil
        }
        error = nil
        transcript = ""
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "The microphone is turned off for this app. Turn it on in Settings > Privacy & Security > Microphone."
            return
        }
        do {
            try await SpeechModel.shared.prepare { [weak self] message in
                Task { @MainActor in if self?.isStarting == true { self?.status = message } }
            }

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "Dictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
            }
            let recording = recording
            recording.reset(sampleRate: format.sampleRate)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                recording.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isListening = true
            loop = Task { [weak self] in await self?.transcribeWhileListening() }
        } catch {
            self.error = "Dictation could not start: \(error.localizedDescription)"
            cancel()
        }
    }

    private func transcribeWhileListening() async {
        var transcribed = 0
        while !Task.isCancelled, engine.isRunning {
            try? await Task.sleep(for: .seconds(1))
            let (samples, rate) = recording.snapshot()
            if Double(samples.count) / rate > Self.longestSeconds {
                stop()
                return
            }
            // Wait for half a second of new sound before going over it all again.
            guard Double(samples.count - transcribed) / rate >= 0.5 else { continue }
            transcribed = samples.count
            if let text = try? await SpeechModel.shared.transcribe(samples, sampleRate: rate), !Task.isCancelled, engine.isRunning {
                transcript = text
            }
        }
    }

    /// Stops listening and settles the text with one last pass over everything said.
    func stop() {
        guard isListening, engine.isRunning else { return }
        stopAudio()
        let (samples, rate) = recording.snapshot()
        Task {
            if let text = try? await SpeechModel.shared.transcribe(samples, sampleRate: rate), isListening { transcript = text }
            isListening = false
        }
    }

    /// Stops listening and drops whatever has not reached the text yet.
    func cancel() {
        stopAudio()
        isListening = false
    }

    private func stopAudio() {
        loop?.cancel()
        loop = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// The sound recorded so far, written by the audio thread and read by the transcriber.
private final class Recording: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate = 16000.0

    func reset(sampleRate: Double) {
        lock.withLock {
            samples = []
            self.sampleRate = sampleRate
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let new = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.withLock { samples.append(contentsOf: new) }
    }

    func snapshot() -> (samples: [Float], sampleRate: Double) {
        lock.withLock { (samples, sampleRate) }
    }
}

/// The speech model, loaded once and shared.
actor SpeechModel {
    static let shared = SpeechModel()
    private var manager: AsrManager?

    /// Fetches the model if it is not on the device yet, then loads it.
    func prepare(status: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        guard manager == nil else { return }
        status("Getting the speech model ready…")
        // The graphics processor loads this build in about a second; the Neural
        // Engine would first spend minutes compiling it.
        let models = try await AsrModels.downloadAndLoad(version: .redux, encoderComputeUnits: .cpuAndGPU) { progress in
            if case .downloading = progress.phase {
                status("Downloading the speech model (220 MB), \(Int(progress.fractionCompleted * 100))%")
            }
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    /// Text for mono sound at any sample rate.
    func transcribe(_ samples: [Float], sampleRate: Double) async throws -> String {
        try await prepare()
        guard let manager, Double(samples.count) / sampleRate >= 0.3 else { return "" }
        let audio = sampleRate == 16000 ? samples : try AudioConverter().resample(samples, from: sampleRate)
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text for a sound file, for checking the model without a microphone.
    func transcribe(file: URL) async throws -> String {
        try await transcribe(try AudioConverter().resampleAudioFile(file), sampleRate: 16000)
    }
}
