// NotesGenerator.swift
// Handles AI-powered note generation through Coder

import Foundation

/// Result type for note generation streaming
enum GenerationResult {
    case content(String)
    case error(String)
}

/// Generates meeting notes using the selected Coder model
class NotesGenerator {
    static let shared = NotesGenerator()
    
    private init() {}
    
    /// Generates meeting notes from meeting data using template-based system prompt with streaming
    /// - Parameters:
    ///   - meeting: The meeting object containing all necessary data
    ///   - userBlurb: Information about the user for context
    ///   - systemPrompt: The system prompt template with placeholders
    ///   - templateId: Optional template ID to use for generating notes
    /// - Returns: AsyncStream of partial generated notes
    func generateNotesStream(meeting: Meeting,
                            userBlurb: String,
                            systemPrompt: String,
                            templateId: UUID? = nil) -> AsyncStream<GenerationResult> {
        
        return AsyncStream<GenerationResult>(GenerationResult.self) { continuation in
            Task {
                do {
                    guard let apiKey = KeychainHelper.shared.getCoderAPIKey(), !apiKey.isEmpty else {
                        continuation.yield(.error(ErrorMessage.noAPIKey))
                        continuation.finish()
                        return
                    }
                    
                    // Validate API key before proceeding
                    let validationResult = await CoderAPIValidator.shared.validateAPIKey(apiKey)
                    switch validationResult {
                    case .failure(let error):
                        continuation.yield(.error(error.localizedDescription))
                        continuation.finish()
                        return
                    case .success():
                        break
                    }
                    
                    // Create date formatter for meeting date
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateStyle = .full
                    dateFormatter.timeStyle = .short
                    
                    // Load template content
                    var templateContent = ""
                    if let templateId = templateId {
                        let templates = LocalStorageManager.shared.loadTemplates()
                        if let template = templates.first(where: { $0.id == templateId }) {
                            templateContent = template.formattedContent
                        }
                    }
                    
                    // If no template content, use default
                    if templateContent.isEmpty {
                        continuation.yield(.error(ErrorMessage.noTemplate))
                        continuation.finish()
                        return
                    }
                    
                    // Check if transcript is empty
                    if meeting.formattedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.yield(.error(ErrorMessage.noTranscript))
                        continuation.finish()
                        return
                    }
                    
                    // Prepare template variables
                    let templateVariables: [String: String] = [
                        "meeting_title": meeting.title.isEmpty ? "Untitled Meeting" : meeting.title,
                        "meeting_date": dateFormatter.string(from: meeting.date),
                        "transcript": meeting.formattedTranscript,
                        "user_blurb": userBlurb,
                        "user_notes": meeting.userNotes,
                        "template_content": templateContent
                    ]
                    
                    // Process the system prompt template
                    let systemContent = Settings.processTemplate(systemPrompt, with: templateVariables)
                    let stream = CoderAPIClient.shared.streamChat(
                        systemPrompt: systemContent,
                        model: UserDefaultsManager.shared.notesModel
                    )
                    for try await content in stream {
                        continuation.yield(.content(content))
                    }
                    
                    continuation.finish()
                } catch {
                    let errorMessage = ErrorHandler.shared.handleError(error)
                    print("Error in streaming generation: \(error)")
                    continuation.yield(.error(errorMessage))
                    continuation.finish()
                }
            }
        }
    }

    /// Generates a short title after meeting notes have been created.
    func generateMeetingTitle(
        meeting: Meeting,
        generatedNotes: String,
        templateId: UUID?
    ) async throws -> String? {
        let templates = LocalStorageManager.shared.loadTemplates()
        let template = templateId.flatMap { id in
            templates.first(where: { $0.id == id })
        }
        let meetingContext: String
        if let template {
            meetingContext = "\(template.title): \(template.context)"
        } else {
            meetingContext = "General meeting"
        }

        let trimmedNotes = generatedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetingContent = trimmedNotes.isEmpty ? meeting.formattedTranscript : trimmedNotes
        guard !meetingContent.isEmpty else { return nil }

        let systemPrompt = """
        Create a concise, descriptive title for a recorded meeting from its context and content.
        Return only the title in 3 to 8 words. Do not use quotation marks, Markdown, or a trailing period.
        Avoid generic titles such as Meeting, Discussion, Meeting Notes, or Untitled Meeting.
        """
        let userPrompt = """
        Meeting context:
        \(meetingContext)

        Meeting content:
        \(meetingContent)
        """

        var generatedTitle = ""
        let stream = CoderAPIClient.shared.streamChat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: UserDefaultsManager.shared.notesModel
        )
        for try await content in stream {
            generatedTitle += content
        }

        return normalizedTitle(generatedTitle)
    }

    private func normalizedTitle(_ value: String) -> String? {
        guard var title = value
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        while title.hasPrefix("#") {
            title.removeFirst()
            title = title.trimmingCharacters(in: .whitespaces)
        }
        if title.lowercased().hasPrefix("title:") {
            title = String(title.dropFirst("title:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if title.hasSuffix(".") {
            title.removeLast()
        }

        if title.count > 80 {
            let prefix = String(title.prefix(80))
            if let lastSpace = prefix.lastIndex(of: " ") {
                title = String(prefix[..<lastSpace])
            } else {
                title = prefix
            }
        }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
    
    /// Validates if the Coder service token is configured
    /// - Returns: True if API key exists, false otherwise
    func isConfigured() -> Bool {
        guard let key = KeychainHelper.shared.getCoderAPIKey(),
              !key.isEmpty else {
            return false
        }
        return true
    }
}
