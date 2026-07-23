import AVFoundation
import Combine
import Foundation
import SwiftUI

private enum RecoveryTranscriptionError: LocalizedError {
    case noAudioFiles
    case noSpeech
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioFiles:
            return "The saved recovery audio could not be found."
        case .noSpeech:
            return "No speech was detected in the saved recovery audio."
        case .requestFailed(let details):
            return "Retry transcription failed for \(details)"
        }
    }
}

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
    private(set) var lastRecoveryAudioFolderName: String?
    
    private var audioEngine = AVAudioEngine()
    private var sessionID = UUID()
    private var meetingID = UUID()
    private var processTap: ProcessTap?
    private let permission = AudioRecordingPermission()
    private let tapQueue = DispatchQueue(label: "io.meetingnotes.audiotap", qos: .userInitiated)
    private let audioFileLock = NSLock()
    private var isTapActive = false
    private var isAcceptingAudio = false
    private var micRetryCount = 0
    private var pendingMicRestart: DispatchWorkItem?
    private let maxMicRetries = 3
    private var micAudioFile: AVAudioFile?
    private var systemAudioFile: AVAudioFile?
    private var micAudioURL: URL?
    private var systemAudioURL: URL?
    private var recordingStartedAt = Date()

    private override init() {
        super.init()
        observeAudioEngine()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func startRecording(for meetingID: UUID) {
        errorMessage = nil
        lastRecoveryAudioFolderName = nil
        cancelCapture(removeFiles: true)
        sessionID = UUID()
        self.meetingID = meetingID
        recordingStartedAt = Date()
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
        let completedMeetingID = meetingID
        let captureStartedAt = recordingStartedAt
        let files = stopCaptureAndCloseFiles()
        isProcessing = true
        defer {
            isProcessing = false
        }

        let model = UserDefaultsManager.shared.transcriptionModel
        async let micResult = transcribe(files[0], model: model)
        async let systemResult = transcribe(files[1], model: model)
        let (micTranscription, systemTranscription) = await (micResult, systemResult)
        let results = [micTranscription, systemTranscription]

        let (updated, failures) = buildTranscriptChunks(
            from: results,
            captureStartedAt: captureStartedAt,
            existingChunks: transcriptChunks.filter(\.isFinal)
        )
        transcriptChunks = updated
        let completedFiles = files.compactMap { $0 }
        let audioFolder = preserveAudioFiles(completedFiles, meetingID: completedMeetingID)
        lastRecoveryAudioFolderName = audioFolder?.lastPathComponent
        if !failures.isEmpty {
            let retentionDays = UserDefaultsManager.shared.audioRetentionDays
            let retentionUnit = retentionDays == 1 ? "day" : "days"
            let recoveryMessage = audioFolder == nil
                ? " The audio remains in the app's temporary folder."
                : " Audio was kept for \(retentionDays) \(retentionUnit). Use Show Audio Folder in the Meetingnotes menu to find it."
            errorMessage = "Transcription failed for " + failures.joined(separator: "; ") + recoveryMessage
        } else if audioFolder == nil, !completedFiles.isEmpty {
            errorMessage = "The transcript completed, but Meetingnotes could not move the audio into its retention folder."
        }
        return updated
    }

    func transcribeRecoveryAudio(in folder: URL, captureStartedAt: Date) async throws -> [TranscriptChunk] {
        let recoveryFiles = LocalStorageManager.shared.recoveryAudioFiles(in: folder)
        guard !recoveryFiles.isEmpty else {
            throw RecoveryTranscriptionError.noAudioFiles
        }

        isProcessing = true
        defer { isProcessing = false }
        let model = UserDefaultsManager.shared.transcriptionModel
        let micURL = recoveryFiles.first(where: { $0.source == .mic })?.url
        let systemURL = recoveryFiles.first(where: { $0.source == .system })?.url
        async let micResult = transcribe(micURL, model: model)
        async let systemResult = transcribe(systemURL, model: model)
        let (micTranscription, systemTranscription) = await (micResult, systemResult)
        let results = [micTranscription, systemTranscription]
        let (chunks, failures) = buildTranscriptChunks(
            from: results,
            captureStartedAt: captureStartedAt,
            existingChunks: []
        )

        if !failures.isEmpty {
            throw RecoveryTranscriptionError.requestFailed(failures.joined(separator: "; "))
        }
        guard !chunks.isEmpty else {
            throw RecoveryTranscriptionError.noSpeech
        }
        return chunks
    }

    func cancelRecording() {
        cancelCapture(removeFiles: true)
        lastRecoveryAudioFolderName = nil
    }

    private func transcribe(_ fileURL: URL?, model: String) async -> Result<CoderAPIClient.Transcription, Error>? {
        guard let fileURL else { return nil }
        do {
            return .success(try await CoderAPIClient.shared.transcribe(fileURL: fileURL, model: model))
        } catch {
            return .failure(error)
        }
    }

    private func buildTranscriptChunks(
        from results: [Result<CoderAPIClient.Transcription, Error>?],
        captureStartedAt: Date,
        existingChunks: [TranscriptChunk]
    ) -> ([TranscriptChunk], [String]) {
        var updated = existingChunks
        var failures: [String] = []
        for (source, result) in zip([AudioSource.mic, .system], results) {
            guard let result else { continue }
            switch result {
            case .success(let transcription):
                if transcription.segments.isEmpty {
                    let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        updated.append(TranscriptChunk(timestamp: captureStartedAt, source: source, text: text, isFinal: true))
                    }
                } else {
                    for segment in transcription.segments {
                        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        updated.append(TranscriptChunk(
                            timestamp: captureStartedAt.addingTimeInterval(max(0, segment.start)),
                            source: source,
                            text: text,
                            isFinal: true
                        ))
                    }
                }
            case .failure(let error):
                failures.append("\(source.displayName): \(error.localizedDescription)")
            }
        }
        updated.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.source.rawValue < $1.source.rawValue
        }
        return (updated, failures)
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
                guard let self else { return }
                self.processAudioBuffer(
                    { buffer },
                    converter: converter,
                    targetFormat: targetFormat,
                    source: .mic
                )
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
        
        let newTap = ProcessTap(target: .systemAudio)
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
    
    private func restartSystemAudioTap() async {
        guard isRecording else { return }
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
            guard let self else { return }
            // The tap queue is serial. Reusing the converter preserves its
            // resampler state instead of discarding audio at every callback.
            self.processAudioBuffer(
                { self.copyAudioBuffer(from: inputData, format: inputFormat) },
                converter: converter,
                targetFormat: targetFormat,
                source: .system
            )
        } invalidationHandler: { [weak self] _ in
            guard let self, self.isRecording else { return }
            Task { await self.restartSystemAudioTap() }
        }
    }

    private func copyAudioBuffer(
        from inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let borrowedBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: inputData,
            deallocator: nil
        ), borrowedBuffer.frameLength > 0,
        let ownedBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: borrowedBuffer.frameLength
        ) else { return nil }

        ownedBuffer.frameLength = borrowedBuffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            ownedBuffer.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in 0..<sourceBuffers.count {
            let source = sourceBuffers[index]
            let destination = destinationBuffers[index]
            let byteCount = Int(source.mDataByteSize)
            guard byteCount <= Int(destination.mDataByteSize),
                  let sourceData = source.mData,
                  let destinationData = destination.mData else { return nil }
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = source.mDataByteSize
        }
        return ownedBuffer
    }
    
    private func processAudioBuffer(
        _ inputBufferProvider: () -> AVAudioPCMBuffer?,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        source: AudioSource
    ) {
        // The system callback copies its borrowed Core Audio memory while this
        // lock prevents teardown, then conversion operates on the owned copy.
        audioFileLock.lock()
        defer { audioFileLock.unlock() }
        guard isAcceptingAudio,
              let inputBuffer = inputBufferProvider(),
              inputBuffer.frameLength > 0 else { return }

        updateAudioLevel(inputBuffer, source: source)
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

        // Stop new callbacks and wait for any active conversion/write before
        // invalidating callback-owned buffers or finalizing AVAudioFile.
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

    private func preserveAudioFiles(_ urls: [URL], meetingID: UUID) -> URL? {
        LocalStorageManager.shared.preserveAudioFiles(urls, for: meetingID)
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
