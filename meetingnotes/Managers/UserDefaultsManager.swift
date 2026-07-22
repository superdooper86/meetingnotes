// UserDefaultsManager.swift
// Manages non-sensitive app settings using UserDefaults

import Foundation

/// Manages non-sensitive app settings using UserDefaults
class UserDefaultsManager {
    static let shared = UserDefaultsManager()
    
    private let userDefaults = UserDefaults.standard
    
    private init() {}
    
    // MARK: - Keys
    private enum Keys {
        static let userBlurb = "userBlurb"
        static let systemPrompt = "systemPrompt"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let hasAcceptedTerms = "hasAcceptedTerms"
        static let selectedTemplateId = "selectedTemplateId"
        static let coderBaseURL = "coderBaseURL"
        static let notesModel = "notesModel"
        static let transcriptionModel = "transcriptionModel"
        static let muteDeckAPIEnabled = "muteDeckAPIEnabled"
        static let muteDeckAPIPort = "muteDeckAPIPort"
        static let audioRetentionDays = "audioRetentionDays"
    }
    
    // MARK: - User Blurb
    var userBlurb: String {
        get { userDefaults.string(forKey: Keys.userBlurb) ?? "" }
        set { userDefaults.set(newValue, forKey: Keys.userBlurb) }
    }
    
    // MARK: - System Prompt
    var systemPrompt: String {
        get { 
            let stored = userDefaults.string(forKey: Keys.systemPrompt)
            return stored?.isEmpty == false ? stored! : Settings.defaultSystemPrompt()
        }
        set { userDefaults.set(newValue, forKey: Keys.systemPrompt) }
    }
    
    // MARK: - Onboarding Status
    var hasCompletedOnboarding: Bool {
        get { userDefaults.bool(forKey: Keys.hasCompletedOnboarding) }
        set { userDefaults.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }
    
    // MARK: - Terms Acceptance
    var hasAcceptedTerms: Bool {
        get { userDefaults.bool(forKey: Keys.hasAcceptedTerms) }
        set { userDefaults.set(newValue, forKey: Keys.hasAcceptedTerms) }
    }
    
    // MARK: - Selected Template ID
    var selectedTemplateId: UUID? {
        get { 
            guard let uuidString = userDefaults.string(forKey: Keys.selectedTemplateId) else { return nil }
            return UUID(uuidString: uuidString)
        }
        set { 
            if let uuid = newValue {
                userDefaults.set(uuid.uuidString, forKey: Keys.selectedTemplateId)
            } else {
                userDefaults.removeObject(forKey: Keys.selectedTemplateId)
            }
        }
    }

    var coderBaseURL: String {
        get { userDefaults.string(forKey: Keys.coderBaseURL) ?? "http://dev:8787/v1" }
        set { userDefaults.set(newValue, forKey: Keys.coderBaseURL) }
    }

    var notesModel: String {
        get { userDefaults.string(forKey: Keys.notesModel) ?? "gpt-5.4-mini" }
        set { userDefaults.set(newValue, forKey: Keys.notesModel) }
    }

    var transcriptionModel: String {
        get { userDefaults.string(forKey: Keys.transcriptionModel) ?? "groq/whisper-large-v3-turbo" }
        set { userDefaults.set(newValue, forKey: Keys.transcriptionModel) }
    }

    var muteDeckAPIEnabled: Bool {
        get { userDefaults.bool(forKey: Keys.muteDeckAPIEnabled) }
        set { userDefaults.set(newValue, forKey: Keys.muteDeckAPIEnabled) }
    }

    var muteDeckAPIPort: Int {
        get {
            let stored = userDefaults.integer(forKey: Keys.muteDeckAPIPort)
            return stored == 0 ? 9880 : stored
        }
        set { userDefaults.set(newValue, forKey: Keys.muteDeckAPIPort) }
    }

    var audioRetentionDays: Int {
        get {
            guard userDefaults.object(forKey: Keys.audioRetentionDays) != nil else { return 3 }
            return min(max(userDefaults.integer(forKey: Keys.audioRetentionDays), 1), 365)
        }
        set { userDefaults.set(min(max(newValue, 1), 365), forKey: Keys.audioRetentionDays) }
    }
}
