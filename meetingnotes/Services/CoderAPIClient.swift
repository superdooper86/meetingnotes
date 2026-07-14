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

    private struct ModelsResponse: Decodable {
        let data: [CoderModel]
    }

    private struct ErrorEnvelope: Decodable {
        struct ServiceError: Decodable { let message: String }
        let error: ServiceError
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    private init() {}

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

    func streamChat(systemPrompt: String, model: String) -> AsyncThrowingStream<String, Error> {
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
                            ["role": "user", "content": "Create the meeting notes now."]
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

    func transcribe(fileURL: URL, model: String, language: String = "en") async throws -> String {
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty else { throw CoderAPIError.missingModel("transcription") }
        let apiKey = try requiredAPIKey(KeychainHelper.shared.getCoderAPIKey() ?? "")
        let boundary = "Meetingnotes-\(UUID().uuidString)"
        let bodyURL = try makeMultipartBody(
            audioURL: fileURL,
            model: selectedModel,
            language: language,
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
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(TranscriptionResponse.self, from: data).text
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

    private func makeMultipartBody(audioURL: URL, model: String, language: String, boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("meetingnotes-upload-\(UUID().uuidString).body")
        _ = FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }

        func write(_ value: String) throws {
            try output.write(contentsOf: Data(value.utf8))
        }
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n")
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n")
        let input = try FileHandle(forReadingFrom: audioURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        return bodyURL
    }
}
