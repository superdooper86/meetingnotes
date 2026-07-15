import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Captures microphone and system audio locally, then sends completed files to Coder.
@MainActor
final class AudioManager: NSObject, ObservableObject {
    static let shared = AudioManager()
    
    @Published var transcriptChunks: [TranscriptChunk] = []
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var errorMessage: String?
    @Published var micAudioLevel: Float = 0
    @Published var systemAudioLevel: Float = 0
    
    private var audioEngine = AVAudioEngine()
    private var sessionID = UUID()
    private var processTap: ProcessTap?
    private let audioProcessController = AudioProcessController()
    private let permission = AudioRecordingPermission()
    private let tapQueue = DispatchQueue(label: "io.meetingnotes.audiotap", qos: .userInitiated)
    private let audioFileLock = NSLock()
    private var isTapActive = false
    private var isRestartingSystemTap = false
    private var isAcceptingAudio = false
    private var micRetryCount = 0
    private var pendingMicRestart: DispatchWorkItem?
    private let maxMicRetries = 3
    private var cancellables = Set<AnyCancellable>()
    
    private var micAudioFile: AVAudioFile?
    private var systemAudioFile: AVAudioFile?
    private var micAudioURL: URL?
    private var systemAudioURL: URL?

    private override init() {
        super.init()
        observeAudioEngine()
        audioProcessController.activate()
        NSWorkspace.shared.publisher(for: \.runningApplications)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isTapActive else { return }
                Task { await self.restartSystemAudioTapIfNeeded() }
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func startRecording() {
        sessionID = UUID()
        errorMessage = nil
        cancelCapture(removeFiles: true)
        do {
            try prepareAudioFiles()
            startMicrophoneTap()
            Task { await startSystemAudioTap() }
        } catch {
            errorMessage = "Could not prepare meeting audio: \(error.localizedDescription)"
            cancelCapture(removeFiles: true)
        }
    }

    func stopRecordingAndTranscribe() async -> [TranscriptChunk] {
        let files = stopCaptureAndCloseFiles()
        isProcessing = true
        defer {
            isProcessing = false
            removeAudioFiles(files.compactMap { $0 })
        }

        let model = UserDefaultsManager.shared.transcriptionModel
        async let micResult = transcribe(files[0], model: model)
        async let systemResult = transcribe(files[1], model: model)
        let (micTranscription, systemTranscription) = await (micResult, systemResult)
        let results = [micTranscription, systemTranscription]

        var updated = transcriptChunks.filter(\.isFinal)
        var failures: [String] = []
        for (source, result) in zip([AudioSource.mic, .system], results) {
            guard let result else { continue }
            switch result {
            case .success(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    updated.append(TranscriptChunk(source: source, text: trimmed, isFinal: true))
                }
            case .failure(let error):
                failures.append("\(source.displayName): \(error.localizedDescription)")
            }
        }
        transcriptChunks = updated
        if !failures.isEmpty {
            errorMessage = "Transcription failed for " + failures.joined(separator: "; ")
        }
        return updated
    }
    
    func cancelRecording() {
        cancelCapture(removeFiles: true)
    }
        
    private func transcribe(_ fileURL: URL?, model: String) async -> Result<String, Error>? {
        guard let fileURL else { return nil }
        do {
            return .success(try await CoderAPIClient.shared.transcribe(fileURL: fileURL, model: model))
        } catch {
            return .failure(error)
        }
    }
    
    private func prepareAudioFiles() throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000
        ]
        let base = FileManager.default.temporaryDirectory
        let id = sessionID.uuidString
        let micURL = base.appendingPathComponent("meetingnotes-\(id)-mic.m4a")
        let systemURL = base.appendingPathComponent("meetingnotes-\(id)-system.m4a")
        let newMicAudioFile = try AVAudioFile(
            forWriting: micURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let newSystemAudioFile = try AVAudioFile(
            forWriting: systemURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        audioFileLock.lock()
        micAudioFile = newMicAudioFile
        systemAudioFile = newSystemAudioFile
        micAudioURL = micURL
        systemAudioURL = systemURL
        isAcceptingAudio = true
        audioFileLock.unlock()
    }

    private func startMicrophoneTap() {
        do {
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard let targetFormat = micAudioFile?.processingFormat,
                  let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported microphone format"])
            }
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self, buffer.frameLength > 0 else { return }
                self.updateAudioLevel(buffer, source: .mic)
                self.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat, source: .mic)
            }
            audioEngine.prepare()
            try audioEngine.start()
            micRetryCount = 0
        } catch {
            errorMessage = "Could not start microphone capture: \(error.localizedDescription)"
            restartMicrophone()
        }
    }
    
    private func restartMicrophone() {
        guard hasActiveAudioFiles(), micRetryCount < maxMicRetries else { return }
        micRetryCount += 1
        pendingMicRestart?.cancel()
        cleanupAudioEngine()

        let restart = DispatchWorkItem { [weak self] in
            guard let self, self.hasActiveAudioFiles() else { return }
            self.startMicrophoneTap()
        }
        pendingMicRestart = restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: restart)
    }
        
    private func cleanupAudioEngine() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()
        audioEngine = AVAudioEngine()
        observeAudioEngine()
    }
    
    private func observeAudioEngine() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            self?.handleAudioEngineConfigurationChange()
        }
    }
        
    private func startSystemAudioTap(isRestart: Bool = false) async {
        if !isRestart, !(await checkSystemAudioPermissions()) {
            errorMessage = "System audio recording permission denied."
            cancelCapture(removeFiles: true)
            return
        }
        
        let processIDs = audioProcessController.processes.map(\.objectID)
        let newTap = ProcessTap(target: .systemAudio(processObjectIDs: processIDs))
        newTap.activate()
        if let tapError = newTap.errorMessage {
            errorMessage = "Failed to activate system audio capture: \(tapError)"
            if !isRestart { cancelCapture(removeFiles: true) }
            return
        }
        
        processTap = newTap
        isTapActive = true
        do {
            try startTapIO(newTap)
            if !isRestart {
                isRecording = true
                AudioLevelManager.shared.updateRecordingState(true)
            }
        } catch {
            errorMessage = "Failed to capture system audio: \(error.localizedDescription)"
            newTap.invalidate()
            isTapActive = false
            if !isRestart { cancelCapture(removeFiles: true) }
        }
    }
    
    private func restartSystemAudioTapIfNeeded() async {
        let next = Set(audioProcessController.processes.map(\.objectID))
        let current: Set<AudioObjectID>
        if case .systemAudio(let processIDs) = processTap?.target {
            current = Set(processIDs)
        } else {
            current = []
        }
        if next != current { await restartSystemAudioTap() }
    }

    private func restartSystemAudioTap() async {
        guard isRecording else { return }
        isRestartingSystemTap = true
        defer { isRestartingSystemTap = false }
        if isTapActive {
            processTap?.invalidate()
            processTap = nil
            isTapActive = false
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard isRecording else { return }
        await startSystemAudioTap(isRestart: true)
    }

    private func checkSystemAudioPermissions() async -> Bool {
        if permission.status == .authorized { return true }
        permission.request()
        for _ in 0..<10 {
            if permission.status == .authorized { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return permission.status == .authorized
    }
    
    private func startTapIO(_ tap: ProcessTap) throws {
        guard var description = tap.tapStreamDescription,
              let inputFormat = AVAudioFormat(streamDescription: &description),
              let targetFormat = systemAudioFile?.processingFormat,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "AudioManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported system audio format"])
        }
        try tap.run(on: tapQueue) { [weak self] _, inputData, _, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: inputData, deallocator: nil),
                  buffer.frameLength > 0 else { return }
            self.updateAudioLevel(buffer, source: .system)
            self.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat, source: .system)
        } invalidationHandler: { [weak self] _ in
            guard let self, !self.isRestartingSystemTap, self.isRecording else { return }
            Task { await self.restartSystemAudioTap() }
        }
    }
    
    private func processAudioBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        source: AudioSource
    ) {
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if suppliedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else { return }

        audioFileLock.lock()
        defer { audioFileLock.unlock() }
        guard isAcceptingAudio else {
            return
        }
        do {
            switch source {
            case .mic:
                try micAudioFile?.write(from: outputBuffer)
            case .system:
                try systemAudioFile?.write(from: outputBuffer)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = "Could not save meeting audio: \(error.localizedDescription)"
            }
        }
    }

    private func updateAudioLevel(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        let rms = sqrt(samples.reduce(0) { $0 + ($1 * $1) } / Float(buffer.frameLength))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch source {
            case .mic:
                self.micAudioLevel = rms
                AudioLevelManager.shared.updateMicLevel(rms)
            case .system:
                self.systemAudioLevel = rms
                AudioLevelManager.shared.updateSystemLevel(rms)
            }
        }
    }
    
    private func stopCaptureAndCloseFiles() -> [URL?] {
        isRecording = false
        pendingMicRestart?.cancel()
        pendingMicRestart = nil
        AudioLevelManager.shared.updateRecordingState(false)

        // Stop new writes and wait for any callback already writing before
        // AVAudioFile is finalized and released.
        audioFileLock.lock()
        isAcceptingAudio = false
        audioFileLock.unlock()

        if isTapActive {
            processTap?.invalidate()
            processTap = nil
            isTapActive = false
        }
        cleanupAudioEngine()
        micRetryCount = 0
        resetAudioLevels()

        audioFileLock.lock()
        let micHasAudio = (micAudioFile?.length ?? 0) > 0
        let systemHasAudio = (systemAudioFile?.length ?? 0) > 0
        micAudioFile = nil
        systemAudioFile = nil
        let files: [URL?] = [micHasAudio ? micAudioURL : nil, systemHasAudio ? systemAudioURL : nil]
        audioFileLock.unlock()
        if !micHasAudio, let micAudioURL { try? FileManager.default.removeItem(at: micAudioURL) }
        if !systemHasAudio, let systemAudioURL { try? FileManager.default.removeItem(at: systemAudioURL) }
        micAudioURL = nil
        systemAudioURL = nil
        return files
    }
    
    private func cancelCapture(removeFiles: Bool) {
        let files = stopCaptureAndCloseFiles().compactMap { $0 }
        if removeFiles { removeAudioFiles(files) }
        isProcessing = false
    }

    private func removeAudioFiles(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
        
    private func resetAudioLevels() {
        micAudioLevel = 0
        systemAudioLevel = 0
        AudioLevelManager.shared.updateMicLevel(0)
        AudioLevelManager.shared.updateSystemLevel(0)
    }

    private func hasActiveAudioFiles() -> Bool {
        audioFileLock.lock()
        defer { audioFileLock.unlock() }
        return isAcceptingAudio
    }
    
    private func handleAudioEngineConfigurationChange() {
        restartMicrophone()
    }
} 
