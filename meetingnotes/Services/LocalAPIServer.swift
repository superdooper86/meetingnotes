import Foundation
import Network

private struct LocalAPIRequest {
    let method: String
    let path: String
    let headers: [String: String]
}

private struct LocalAPIResponse {
    let status: Int
    let reason: String
    let payload: [String: Any]

    static func json(status: Int = 200, reason: String = "OK", _ payload: [String: Any]) -> LocalAPIResponse {
        LocalAPIResponse(status: status, reason: reason, payload: payload)
    }

    func encoded() -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Cache-Control: no-store",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(headers.utf8)
        response.append(body)
        return response
    }
}

private final class LocalAPIConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, isComplete, error in
            if let data { self.buffer.append(data) }

            if self.buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.handleRequest()
                return
            }
            if self.buffer.count > 64 * 1024 {
                self.send(.json(status: 413, reason: "Payload Too Large", ["error": "request headers are too large"]))
                return
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func handleRequest() {
        guard let request = Self.parse(buffer) else {
            send(.json(status: 400, reason: "Bad Request", ["error": "invalid HTTP request"]))
            return
        }
        Task { @MainActor in
            let response = LocalAPIRouter.handle(request)
            send(response)
        }
    }

    private func send(_ response: LocalAPIResponse) {
        connection.send(content: response.encoded(), completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    private static func parse(_ data: Data) -> LocalAPIRequest? {
        guard let text = String(data: data, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n") else {
            return nil
        }
        let lines = text[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3 else { return nil }

        let requestTarget = requestParts[1]
        let path = URLComponents(string: requestTarget)?.path ?? requestTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestTarget
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return LocalAPIRequest(method: requestParts[0].uppercased(), path: path, headers: headers)
    }
}

@MainActor
private enum LocalAPIRouter {
    static func handle(_ request: LocalAPIRequest) -> LocalAPIResponse {
        let path = request.path.count > 1 ? request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : request.path
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path

        if request.method == "GET", normalizedPath == "/api/info" {
            return .json(infoPayload())
        }
        guard authorized(request) else {
            return .json(status: 401, reason: "Unauthorized", ["error": "invalid or missing bearer token"])
        }

        let controller = LocalRecordingController.shared
        switch (request.method, normalizedPath) {
        case ("GET", "/api/recording/status"):
            return .json(controller.statusPayload())
        case ("POST", "/api/recording/start"):
            do {
                return .json(try controller.startRecording())
            } catch {
                return .json(status: 409, reason: "Conflict", [
                    "error": error.localizedDescription,
                    "state": "processing"
                ])
            }
        case ("POST", "/api/recording/stop"):
            return .json(controller.stopRecording())
        case ("POST", "/api/recording/cancel"):
            return .json(controller.cancelRecording())
        default:
            return .json(status: 404, reason: "Not Found", ["error": "endpoint not found"])
        }
    }

    private static func authorized(_ request: LocalAPIRequest) -> Bool {
        guard let authorization = request.headers["authorization"],
              authorization.lowercased().hasPrefix("bearer ") else {
            return false
        }
        let supplied = String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        return timingSafeEqual(supplied, KeychainHelper.shared.getOrCreateMuteDeckAPIToken())
    }

    private static func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func infoPayload() -> [String: Any] {
        // MuteDeck identifies compatible local API targets by the MeetingDebrief contract.
        [
            "status": "ok",
            "name": "MeetingDebrief",
            "implementation": "Meetingnotes",
            "api_version": "1",
            "apiVersion": "1",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            "endpoints": [
                "GET /api/info",
                "GET /api/recording/status",
                "POST /api/recording/start",
                "POST /api/recording/stop",
                "POST /api/recording/cancel"
            ]
        ]
    }
}

private enum LocalRecordingError: LocalizedError {
    case processing
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .processing:
            return "The previous meeting is still processing."
        case .saveFailed:
            return "Could not create a meeting for this recording."
        }
    }
}

@MainActor
private final class LocalRecordingController {
    static let shared = LocalRecordingController()

    private let recordingManager = RecordingSessionManager.shared
    private var isStopping = false

    private init() {}

    func statusPayload() -> [String: Any] {
        let state: String
        if isStopping || recordingManager.isProcessing {
            state = "processing"
        } else if recordingManager.isRecording {
            state = "recording"
        } else if recordingManager.activeMeetingId != nil {
            state = "starting"
        } else {
            state = "idle"
        }
        let isRecording = state == "recording" || state == "starting"
        let elapsed = recordingManager.recordingStartedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
        let sessionID: Any = recordingManager.activeMeetingId.map { $0.uuidString as Any } ?? NSNull()
        return [
            "success": true,
            "status": state,
            "state": state,
            "recording": isRecording,
            "is_recording": isRecording,
            "isRecording": isRecording,
            "paused": false,
            "is_paused": false,
            "isPaused": false,
            "duration": elapsed,
            "duration_seconds": elapsed,
            "durationSeconds": elapsed,
            "session_id": sessionID,
            "sessionId": sessionID
        ]
    }

    func startRecording() throws -> [String: Any] {
        if isStopping || recordingManager.isProcessing {
            throw LocalRecordingError.processing
        }
        if recordingManager.activeMeetingId != nil {
            return statusPayload()
        }

        let meeting = Meeting(templateId: LocalStorageManager.shared.preferredTemplateID())
        guard LocalStorageManager.shared.saveMeeting(meeting) else {
            throw LocalRecordingError.saveFailed
        }
        NotificationCenter.default.post(name: .meetingSaved, object: meeting)
        recordingManager.startRecording(for: meeting.id)
        return statusPayload()
    }

    func stopRecording() -> [String: Any] {
        guard !isStopping, recordingManager.activeMeetingId != nil else {
            return statusPayload()
        }
        isStopping = true
        Task { [weak self] in
            await self?.finishRecording()
        }
        return statusPayload()
    }

    func cancelRecording() -> [String: Any] {
        guard !isStopping else { return statusPayload() }
        let meetingID = recordingManager.activeMeetingId
        recordingManager.cancelRecording()
        if let meetingID,
           let meeting = LocalStorageManager.shared.loadMeetings().first(where: { $0.id == meetingID }) {
            _ = LocalStorageManager.shared.deleteMeeting(meeting)
            NotificationCenter.default.post(name: .meetingDeleted, object: meeting)
        }
        return statusPayload()
    }

    private func finishRecording() async {
        let meetingID = recordingManager.activeMeetingId
        let chunks = await recordingManager.stopRecording()
        guard let meetingID,
              var meeting = LocalStorageManager.shared.loadMeetings().first(where: { $0.id == meetingID }) else {
            isStopping = false
            return
        }

        meeting.transcriptChunks = chunks
        meeting.recoveryAudioFolderName = recordingManager.lastRecoveryAudioFolderName
        let templates = LocalStorageManager.shared.loadTemplates()
        if meeting.templateId == nil {
            meeting.templateId = LocalStorageManager.shared.preferredTemplateID(in: templates)
        }
        _ = LocalStorageManager.shared.saveMeeting(meeting)
        NotificationCenter.default.post(name: .meetingSaved, object: meeting)

        if !meeting.formattedTranscript.isEmpty {
            let stream = NotesGenerator.shared.generateNotesStream(
                meeting: meeting,
                userBlurb: UserDefaultsManager.shared.userBlurb,
                systemPrompt: UserDefaultsManager.shared.systemPrompt,
                templateId: meeting.templateId
            )
            var generatedNotes = ""
            for await result in stream {
                switch result {
                case .content(let content):
                    generatedNotes += content
                case .error:
                    generatedNotes = ""
                }
            }
            var meetingChanged = false
            if !generatedNotes.isEmpty {
                meeting.generatedNotes = generatedNotes
                meetingChanged = true
            }
            if meeting.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    if let title = try await NotesGenerator.shared.generateMeetingTitle(
                        meeting: meeting,
                        generatedNotes: generatedNotes,
                        templateId: meeting.templateId
                    ) {
                        meeting.title = title
                        meetingChanged = true
                    }
                } catch {
                    // The recording and generated notes remain valid without a generated title.
                    print("Meeting title generation failed: \(error)")
                }
            }
            if meetingChanged {
                _ = LocalStorageManager.shared.saveMeeting(meeting)
                NotificationCenter.default.post(name: .meetingSaved, object: meeting)
            }
        }
        isStopping = false
    }
}

@MainActor
final class LocalAPIServer: ObservableObject {
    static let shared = LocalAPIServer()

    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var listeningPort: UInt16?

    private let queue = DispatchQueue(label: "io.meetingnotes.local-api", qos: .userInitiated)
    private var listener: NWListener?

    private init() {}

    var statusText: String {
        if isRunning, let listeningPort {
            return "Listening on 127.0.0.1:\(listeningPort)"
        }
        return errorMessage ?? "Stopped"
    }

    func applyConfiguration() {
        guard UserDefaultsManager.shared.muteDeckAPIEnabled else {
            stop()
            return
        }
        let configuredPort = UserDefaultsManager.shared.muteDeckAPIPort
        guard let port = UInt16(exactly: configuredPort), port > 0 else {
            stop()
            errorMessage = "Enter a port between 1 and 65535."
            return
        }
        if isRunning, listeningPort == port { return }
        start(port: port)
    }

    private func start(port: UInt16) {
        stop()
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: port)!
            )
            let listener = try NWListener(using: parameters)
            let queue = self.queue
            listener.newConnectionHandler = { connection in
                LocalAPIConnection(connection: connection, queue: queue).start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        isRunning = true
                        listeningPort = port
                        errorMessage = nil
                    case .failed(let error):
                        isRunning = false
                        listeningPort = nil
                        errorMessage = "Local API failed: \(error.localizedDescription)"
                    case .cancelled:
                        isRunning = false
                        listeningPort = nil
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            _ = KeychainHelper.shared.getOrCreateMuteDeckAPIToken()
            listener.start(queue: queue)
        } catch {
            errorMessage = "Local API failed: \(error.localizedDescription)"
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        listeningPort = nil
        if !UserDefaultsManager.shared.muteDeckAPIEnabled {
            errorMessage = nil
        }
    }
}
