import Foundation
import SwiftUI
import PostHog

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var settings = Settings()
    @Published var saveMessage = ""
    @Published var showingSaveMessage = false
    @Published var templates: [NoteTemplate] = []
    @Published var coderModels: [CoderModel] = []
    @Published var isLoadingModels = false
    @Published var connectionMessage = ""
    @Published var muteDeckAPIToken: String
    
    init() {
        muteDeckAPIToken = KeychainHelper.shared.getOrCreateMuteDeckAPIToken()
        loadTemplates()
    }
    
    /// Loads the Coder service token from Keychain.
    func loadAPIKey() {
        if settings.coderAPIKey.isEmpty {
            settings.coderAPIKey = KeychainHelper.shared.getCoderAPIKey() ?? ""
        }
    }

    @MainActor
    func refreshModels() async {
        isLoadingModels = true
        connectionMessage = ""
        defer { isLoadingModels = false }
        do {
            coderModels = try await CoderAPIClient.shared.models(
                baseURL: settings.coderBaseURL,
                apiKey: settings.coderAPIKey
            )
            let chatModels = coderModels.filter(\.supportsChat)
            let transcriptionModels = coderModels.filter(\.supportsTranscription)
            if !chatModels.contains(where: { $0.id == settings.notesModel }), let first = chatModels.first {
                settings.notesModel = first.id
            }
            if !transcriptionModels.contains(where: { $0.id == settings.transcriptionModel }), let first = transcriptionModels.first {
                settings.transcriptionModel = first.id
            }
            connectionMessage = "Connected to Coder"
        } catch {
            coderModels = []
            connectionMessage = error.localizedDescription
        }
    }
    
    func loadTemplates() {
        templates = LocalStorageManager.shared.loadTemplates()
        
        // Validate that the selected template still exists
        if let selectedId = settings.selectedTemplateId {
            if !templates.contains(where: { $0.id == selectedId }) {
                // Selected template was deleted, clear the selection
                settings.selectedTemplateId = nil
            }
        }
        
        // If no template is selected, select the first default template
        if settings.selectedTemplateId == nil {
            if let defaultTemplate = templates.first(where: { $0.title == "Standard Meeting" }) {
                settings.selectedTemplateId = defaultTemplate.id
            } else if let firstTemplate = templates.first {
                // Fallback to first available template
                settings.selectedTemplateId = firstTemplate.id
            }
        }
    }
    
    func saveSettings(showMessage: Bool = true) {
        // Validate that systemPrompt contains all required template placeholders
        let requiredKeys = ["meeting_title", "meeting_date", "transcript", "user_blurb", "user_notes", "template_content"]
        let missing = requiredKeys.filter { !settings.systemPrompt.contains("{{\($0)}}") }
        if !missing.isEmpty {
            if showMessage {
                saveMessage = "Cannot save settings: missing placeholders \(missing.map { "{{\($0)}}" }.joined(separator: ", ")) in system prompt"
                showingSaveMessage = true
            }
            return
        }

        // Only save API key to keychain - other values are automatically saved to UserDefaults
        // via computed properties when they're modified
        let coderSaved = KeychainHelper.shared.saveCoderAPIKey(settings.coderAPIKey)
        LocalAPIServer.shared.applyConfiguration()

        if showMessage {
            if coderSaved {
                saveMessage = "Settings saved successfully!"
            } else {
                saveMessage = "Error saving settings"
            }

            showingSaveMessage = true

            // Hide the message after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self.showingSaveMessage = false
            }
        }
    }
    
    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        settings.hasAcceptedTerms = true
        saveSettings(showMessage: false)
        PostHogSDK.shared.capture("onboarding_completed")
    }
    
    func resetToDefaults() {
        settings.systemPrompt = Settings.defaultSystemPrompt()
    }
    
    func resetOnboarding() {
        settings.hasCompletedOnboarding = false
        saveSettings(showMessage: false)
        
        // Force app to restart or recreate views by posting a notification
        // This will cause ContentView to re-evaluate and show onboarding
        NotificationCenter.default.post(name: Notification.Name("OnboardingReset"), object: nil)
    }

    func applyMuteDeckAPIConfiguration() {
        LocalAPIServer.shared.applyConfiguration()
    }

    func regenerateMuteDeckAPIToken() {
        muteDeckAPIToken = KeychainHelper.shared.regenerateMuteDeckAPIToken()
    }
}
