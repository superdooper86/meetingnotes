import Foundation

final class CoderAPIValidator {
    static let shared = CoderAPIValidator()
    
    private init() {}
    
    func validateAPIKey(_ apiKey: String) async -> Result<Void, APIKeyValidationError> {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.emptyKey)
        }
        do {
            let models = try await CoderAPIClient.shared.models(
                baseURL: UserDefaultsManager.shared.coderBaseURL,
                apiKey: apiKey
            )
            return models.isEmpty ? .failure(.noModelsAvailable) : .success(())
        } catch let error as CoderAPIError {
            return .failure(.connection(error.localizedDescription))
        } catch {
            return .failure(.connection(error.localizedDescription))
        }
    }
    
    func validateCurrentAPIKey() async -> Result<Void, APIKeyValidationError> {
        guard let apiKey = KeychainHelper.shared.getCoderAPIKey() else {
            return .failure(.emptyKey)
        }
        return await validateAPIKey(apiKey)
    }
}

enum APIKeyValidationError: Error, LocalizedError {
    case emptyKey
    case noModelsAvailable
    case connection(String)
    
    var errorDescription: String? {
        switch self {
        case .emptyKey:
            return ErrorMessage.noAPIKey
        case .noModelsAvailable:
            return ErrorMessage.noModelsAvailable
        case .connection(let message):
            return message
        }
    }
}