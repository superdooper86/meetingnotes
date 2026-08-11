import AVFoundation
import Foundation

struct CoderModel: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let ownedBy: String
    let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case ownedBy = "owned_by"
        case capabilities
    }

    var displayName: String {
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? id : label
    }

    var supportsChat: Bool { capabilities.isEmpty || capabilities.contains("chat") }
    var supportsTranscription: Bool { capabilities.contains("audio_transcription") }
    var supportsSpeakerDiarization: Bool { capabilities.contains("speaker_diarization") }
}

enum CoderAPIError: LocalizedError {
    case invalidBaseURL
    case missingAPIKey
    case missingModel(String)
    case invalidResponse
    case serviceError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter a valid Coder service URL."
        case .missingAPIKey:
            return "Enter the Coder service token."
        case .missingModel(let purpose):
            return "Select a Coder model for \(purpose)."
        case .invalidResponse:
            return "Coder returned an invalid response."
        case .serviceError(let status, let message):
            return "Coder request failed (\(status)): \(message)"
        }
    }
}

final class CoderAPIClient {
    static let shared = CoderAPIClient()

    struct Transcription {
        struct Segment: Decodable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
            let speaker: Int?
        }

        let text: String
        let segments: [Segment]
    }

    private struct ModelsResponse: Decodable {
        let data: [CoderModel]
    }

    private struct ErrorEnvelope: Decodable {
        struct ServiceError: Decodable { let message: String }
        let error: ServiceError
    }

    private struct TranscriptionResponse: Decodable {
        struct Word: Decodable {
            let word: String
            let start: TimeInterval
            let end: TimeInterval
            let speaker: Int?
        }

        let text: String
        let segments: [Transcription.Segment]?
        let words: [Word]?
    }

    private struct AudioChunk {
        let url: URL
        let offset: TimeInterval
        let isTemporary: Bool
    }

    private let transcriptionChunkDuration: TimeInterval = 3 * 60
    private let transcriptionSession: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 2 * 60 * 60
        configuration.timeoutIntervalForResource = 2 * 60 * 60
        transcriptionSession = URLSession(configuration: configuration)
    }

    func models(baseURL: String, apiKey: String) async throws -> [CoderModel] {
        var request = URLRequest(url: try endpoint(baseURL: baseURL, path: "models"))
        request.setValue("Bearer \(try requiredAPIKey(apiKey))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ModelsResponse.self, from: data).data
    }

    func models() async throws -> [CoderModel] {
        try await models(
            baseURL: UserDefaultsManager.shared.coderBaseURL,
            apiKey: KeychainHelper.shared.getCoderAPIKey() ?? ""
        )
    }

    func streamChat(
        systemPrompt: String,
        userPrompt: String = "Create the meeting notes now.",
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !selectedModel.isEmpty else { throw CoderAPIError.missingModel("notes") }
                    let baseURL = UserDefaultsManager.shared.coderBaseURL
                    let apiKey = try requiredAPIKey(KeychainHelper.shared.getCoderAPIKey() ?? "")
                    var request = URLRequest(url: try endpoint(baseURL: baseURL, path: "chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": selectedModel,
                        "messages": [
                            ["role": "system", "content": systemPrompt],
                            ["role": "user", "content": userPrompt]
                        ],
                        "stream": true
                    ])

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw CoderAPIError.invalidResponse
                    }
                    guard (200...299).contains(httpResponse.statusCode) else {
                        throw CoderAPIError.serviceError(httpResponse.statusCode, HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String,
                              !content.isEmpty else {
                            continue
                        }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func transcribe(
        fileURL: URL,
        model: String,
        language: String = "en",
        diarization: Bool = false,
        maxSpeakerCount: Int = 4
    ) async throws -> Transcription {
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty else { throw CoderAPIError.missingModel("transcription") }
        let apiKey = try requiredAPIKey(KeychainHelper.shared.getCoderAPIKey() ?? "")
        let chunks = try makeAudioChunks(from: fileURL, preserveSpeakerIdentity: diarization)
        defer {
            for chunk in chunks where chunk.isTemporary {
                try? FileManager.default.removeItem(at: chunk.url)
            }
        }

        var textParts: [String] = []
        var segments: [Transcription.Segment] = []
        var lastNormalizedText = ""
        var consecutiveDuplicateCount = 0

        for chunk in chunks {
            let transcription = try await transcribeChunk(
                chunk.url,
                model: selectedModel,
                language: language,
                apiKey: apiKey,
                diarization: diarization,
                maxSpeakerCount: maxSpeakerCount
            )
            if transcription.segments.isEmpty {
                let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    textParts.append(text)
                    segments.append(.init(start: chunk.offset, end: chunk.offset, text: text, speaker: nil))
                }
                continue
            }

            for segment in transcription.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let normalized = text.lowercased()
                if normalized == lastNormalizedText {
                    consecutiveDuplicateCount += 1
                } else {
                    lastNormalizedText = normalized
                    consecutiveDuplicateCount = 1
                }
                guard consecutiveDuplicateCount <= 2 else { continue }
                textParts.append(text)
                segments.append(.init(
                    start: segment.start + chunk.offset,
                    end: segment.end + chunk.offset,
                    text: text,
                    speaker: segment.speaker
                ))
            }
        }

        return Transcription(text: textParts.joined(separator: "\n"), segments: segments)
    }

    private func transcribeChunk(
        _ fileURL: URL,
        model: String,
        language: String,
        apiKey: String,
        diarization: Bool,
        maxSpeakerCount: Int
    ) async throws -> Transcription {
        let boundary = "Meetingnotes-\(UUID().uuidString)"
        let bodyURL = try makeMultipartBody(
            audioURL: fileURL,
            model: model,
            language: language,
            diarization: diarization,
            maxSpeakerCount: maxSpeakerCount,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: try endpoint(baseURL: UserDefaultsManager.shared.coderBaseURL, path: "audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: bodyURL.path),
           let size = attributes[.size] as? NSNumber {
            request.setValue(size.stringValue, forHTTPHeaderField: "Content-Length")
        }
        let (data, response) = try await transcriptionSession.upload(for: request, fromFile: bodyURL)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let segments = decoded.segments ?? segments(from: decoded.words ?? [])
        return Transcription(text: decoded.text, segments: segments)
    }

    private func makeAudioChunks(from fileURL: URL, preserveSpeakerIdentity: Bool) throws -> [AudioChunk] {
        let input = try AVAudioFile(forReading: fileURL)
        let format = input.processingFormat
        guard format.sampleRate > 0 else { throw CoderAPIError.invalidResponse }

        let framesPerChunk = preserveSpeakerIdentity
            ? max(1, input.length)
            : AVAudioFramePosition(format.sampleRate * transcriptionChunkDuration)
        var chunks: [AudioChunk] = []
        var frameOffset: AVAudioFramePosition = 0

        do {
            while frameOffset < input.length {
                let frameCount = min(framesPerChunk, input.length - frameOffset)
                let chunkURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("meetingnotes-transcription-\(UUID().uuidString).wav")
                try writeAudioChunk(
                    from: input,
                    frameCount: frameCount,
                    format: format,
                    to: chunkURL
                )
                chunks.append(AudioChunk(
                    url: chunkURL,
                    offset: Double(frameOffset) / format.sampleRate,
                    isTemporary: true
                ))
                frameOffset += frameCount
            }
            return chunks
        } catch {
            for chunk in chunks {
                try? FileManager.default.removeItem(at: chunk.url)
            }
            throw error
        }
    }

    private func writeAudioChunk(
        from input: AVAudioFile,
        frameCount: AVAudioFramePosition,
        format: AVAudioFormat,
        to outputURL: URL
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        var remaining = frameCount
        while remaining > 0 {
            let requestedFrames = AVAudioFrameCount(min(remaining, 8_192))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: requestedFrames) else {
                throw CoderAPIError.invalidResponse
            }
            try input.read(into: buffer, frameCount: requestedFrames)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }

    private func segments(from words: [TranscriptionResponse.Word]) -> [Transcription.Segment] {
        var result: [Transcription.Segment] = []
        var currentWords: [String] = []
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval = 0
        var currentSpeaker: Int?

        func flush() {
            guard let start = currentStart, !currentWords.isEmpty else { return }
            result.append(.init(
                start: start,
                end: currentEnd,
                text: currentWords.joined(separator: " "),
                speaker: currentSpeaker
            ))
            currentWords.removeAll(keepingCapacity: true)
            currentStart = nil
            currentEnd = 0
            currentSpeaker = nil
        }

        for word in words {
            let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speakerChanged = currentStart != nil && word.speaker != currentSpeaker
            let longPause = currentStart != nil && word.start - currentEnd > 1.5
            if speakerChanged || longPause { flush() }

            if currentStart == nil {
                currentStart = word.start
                currentSpeaker = word.speaker
            }
            currentWords.append(text)
            currentEnd = word.end

            let sentenceEnded = text.last.map { ".!?".contains($0) } ?? false
            let duration = currentEnd - (currentStart ?? currentEnd)
            if currentWords.count >= 40 || (sentenceEnded && (currentWords.count >= 12 || duration >= 8)) {
                flush()
            }
        }
        flush()
        return result
    }

    private func endpoint(baseURL: String, path: String) throws -> URL {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            throw CoderAPIError.invalidBaseURL
        }
        var basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.isEmpty { basePath = "v1" }
        components.path = "/\(basePath)/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        guard let url = components.url else { throw CoderAPIError.invalidBaseURL }
        return url
    }

    private func requiredAPIKey(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CoderAPIError.missingAPIKey }
        return trimmed
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { throw CoderAPIError.invalidResponse }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw CoderAPIError.serviceError(httpResponse.statusCode, message)
        }
    }

    private func makeMultipartBody(
        audioURL: URL,
        model: String,
        language: String,
        diarization: Bool,
        maxSpeakerCount: Int,
        boundary: String
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("meetingnotes-upload-\(UUID().uuidString).body")
        _ = FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }

        func write(_ value: String) throws {
            try output.write(contentsOf: Data(value.utf8))
        }
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n")
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\nverbose_json\r\n")
        if diarization {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"diarization\"\r\n\r\ntrue\r\n")
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"max_speaker_count\"\r\n\r\n\(maxSpeakerCount)\r\n")
        }
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\nContent-Type: audio/wav\r\n\r\n")
        let input = try FileHandle(forReadingFrom: audioURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        return bodyURL
    }
}
