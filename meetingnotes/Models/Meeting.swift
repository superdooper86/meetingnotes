import Foundation

enum TranscriptTimestampFormatter {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}

enum AudioSource: String, Codable, CaseIterable {
    case mic = "MIC"
    case system = "SYS"
    
    var displayName: String {
        switch self {
        case .mic:
            return "Me"
        case .system:
            return "Them"
        }
    }
    
    var copyPrefix: String {
        switch self {
        case .mic:
            return "Me"
        case .system:
            return "Them"
        }
    }
    
    var icon: String {
        switch self {
        case .mic:
            return "mic.fill"
        case .system:
            return "speaker.wave.2.fill"
        }
    }
}

struct TranscriptChunk: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let source: AudioSource
    let text: String
    let isFinal: Bool
    
    init(id: UUID = UUID(), timestamp: Date = Date(), source: AudioSource, text: String, isFinal: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.text = text
        self.isFinal = isFinal
    }
}

struct CollapsedTranscriptChunk: Identifiable {
    let id: UUID
    let timestamp: Date
    let source: AudioSource
    let combinedText: String
    
    init(id: UUID = UUID(), timestamp: Date, source: AudioSource, combinedText: String) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.combinedText = combinedText
    }
}

struct Meeting: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    var title: String
    var transcriptChunks: [TranscriptChunk]
    var userNotes: String
    var generatedNotes: String
    var templateId: UUID?  // Add property to track per-meeting template
    // MARK: - Data versioning
    /// Version of this Meeting record on disk. Useful for migration.
    var dataVersion: Int
    /// Current app data version. Increment whenever you make a breaking change to `Meeting` that requires migration.
    static let currentDataVersion = 1
    
    init(id: UUID = UUID(),
         date: Date = Date(),
         title: String = "",
         transcriptChunks: [TranscriptChunk] = [],
         userNotes: String = "",
         generatedNotes: String = "",
         templateId: UUID? = nil,
         dataVersion: Int = Meeting.currentDataVersion) {
        self.id = id
        self.date = date
        self.title = title
        self.transcriptChunks = transcriptChunks
        self.userNotes = userNotes
        self.generatedNotes = generatedNotes
        self.templateId = templateId
        self.dataVersion = dataVersion
    }
    
    // `Codable` conformance now uses the compiler-synthesised implementation.
    
    // Computed property for backward compatibility with existing code
    var transcript: String {
        return transcriptChunks
            .filter { $0.isFinal }
            .map { "[\($0.source.rawValue)] \($0.text)" }
            .joined(separator: " ")
    }
    
    // Formatted transcript for copying with collapsed sequential chunks
    var formattedTranscript: String {
        let finalChunks = transcriptChunks.filter { $0.isFinal }

        return finalChunks.map { chunk in
            "[\(TranscriptTimestampFormatter.string(from: chunk.timestamp))] \(chunk.source.copyPrefix): \(chunk.text)"
        }.joined(separator: "\n")
    }
    
    // Collapsed chunks for UI display
    var collapsedTranscriptChunks: [CollapsedTranscriptChunk] {
        transcriptChunks.filter(\.isFinal).map { chunk in
            CollapsedTranscriptChunk(
                id: chunk.id,
                timestamp: chunk.timestamp,
                source: chunk.source,
                combinedText: chunk.text
            )
        }
    }
    
    // Separate computed properties for mic and system transcripts
    var micTranscript: String {
        return transcriptChunks
            .filter { $0.source == .mic && $0.isFinal }
            .map { $0.text }
            .joined(separator: " ")
    }
    
    var systemTranscript: String {
        return transcriptChunks
            .filter { $0.source == .system && $0.isFinal }
            .map { $0.text }
            .joined(separator: " ")
    }
}
