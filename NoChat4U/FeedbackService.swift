import Foundation
import Vapor
import Logging

class FeedbackService {
    private let logger = Logger(label: "NoChat4U.FeedbackService")
    private let app: Application
    
    private let apiURL = "https://api.github.com/repos/miguel-mpm/nochat4u/issues"
    
    init(app: Application) {
        self.app = app
    }
    
    func submitFeedback(_ feedbackData: FeedbackData) async throws -> GitHubIssueResponse {
        logger.info("Submitting feedback", metadata: [
            "title": .string(feedbackData.title),
            "hasEmail": .string(feedbackData.email.isEmpty ? "false" : "true")
        ])
        
        // Feedback is disabled until a secure runtime token mechanism is implemented.
        // Previously the GitHub token was embedded at build time via token replacement,
        // which leaked the secret into the distributed binary.
        logger.error("GitHub token not configured")
        throw FeedbackError.apiError("Feedback feature not configured")
    }
}

// MARK: - Feedback Errors
enum FeedbackError: LocalizedError {
    case networkError(String)
    case apiError(String)
    case invalidData
    
    var errorDescription: String? {
        switch self {
        case .networkError(let message):
            return "Network error: \(message)"
        case .apiError(let message):
            return "API error: \(message)"
        case .invalidData:
            return "Invalid feedback data"
        }
    }
}
