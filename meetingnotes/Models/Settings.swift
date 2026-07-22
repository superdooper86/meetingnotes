import Foundation

struct Settings: Codable {
    var coderAPIKey: String = ""
    
    // Computed properties that access UserDefaults
    var userBlurb: String {
        get { UserDefaultsManager.shared.userBlurb }
        set { UserDefaultsManager.shared.userBlurb = newValue }
    }
    
    var systemPrompt: String {
        get { UserDefaultsManager.shared.systemPrompt }
        set { UserDefaultsManager.shared.systemPrompt = newValue }
    }
    
    var selectedTemplateId: UUID? {
        get { UserDefaultsManager.shared.selectedTemplateId }
        set { UserDefaultsManager.shared.selectedTemplateId = newValue }
    }
    
    var hasCompletedOnboarding: Bool {
        get { UserDefaultsManager.shared.hasCompletedOnboarding }
        set { UserDefaultsManager.shared.hasCompletedOnboarding = newValue }
    }
    
    var hasAcceptedTerms: Bool {
        get { UserDefaultsManager.shared.hasAcceptedTerms }
        set { UserDefaultsManager.shared.hasAcceptedTerms = newValue }
    }
    
    var coderBaseURL: String {
        get { UserDefaultsManager.shared.coderBaseURL }
        set { UserDefaultsManager.shared.coderBaseURL = newValue }
    }

    var notesModel: String {
        get { UserDefaultsManager.shared.notesModel }
        set { UserDefaultsManager.shared.notesModel = newValue }
    }

    var transcriptionModel: String {
        get { UserDefaultsManager.shared.transcriptionModel }
        set { UserDefaultsManager.shared.transcriptionModel = newValue }
    }

    var muteDeckAPIEnabled: Bool {
        get { UserDefaultsManager.shared.muteDeckAPIEnabled }
        set { UserDefaultsManager.shared.muteDeckAPIEnabled = newValue }
    }

    var muteDeckAPIPort: Int {
        get { UserDefaultsManager.shared.muteDeckAPIPort }
        set { UserDefaultsManager.shared.muteDeckAPIPort = newValue }
    }

    var audioRetentionDays: Int {
        get { UserDefaultsManager.shared.audioRetentionDays }
        set { UserDefaultsManager.shared.audioRetentionDays = newValue }
    }

    // System prompt default loading
    static func defaultSystemPrompt() -> String {
        guard let path = Bundle.main.path(forResource: "DefaultSystemPrompt", ofType: "txt"),
              let content = try? String(contentsOfFile: path) else {
            return "You are a helpful assistant that creates comprehensive meeting notes from transcript data."
        }
        return content
    }
    
    // Add a computed property for the full prompt
    var fullSystemPrompt: String {
        let defaultPrompt = Settings.defaultSystemPrompt()
        if userBlurb.isEmpty {
            return defaultPrompt
        }
        return "\(defaultPrompt)\n\nContext about the user: \(userBlurb)"
    }
    
    // Template processing method
    static func processTemplate(_ template: String, with variables: [String: String]) -> String {
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
    
    init(coderAPIKey: String = "") {
        self.coderAPIKey = coderAPIKey
    }
    
    // MARK: - Codable conformance for API key only
    private enum CodingKeys: String, CodingKey {
        case coderAPIKey
    }
}
