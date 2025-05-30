import Foundation
import Vapor
import Logging

class FeedbackService {
    private let logger = Logger(label: "NoChat4U.FeedbackService")
    private let app: Application
    
    // Token will be replaced during build process
    private let githubToken = "GITHUB_TOKEN_PLACEHOLDER"
    private let apiURL = "https://api.github.com/repos/miguel-mpm/nochat4u/issues"
    
    init(app: Application) {
        self.app = app
    }
    
    func submitFeedback(_ feedbackData: FeedbackData) async throws -> GitHubIssueResponse {
        logger.info("Submitting feedback", metadata: [
            "title": .string(feedbackData.title),
            "hasEmail": .string(feedbackData.email.isEmpty ? "false" : "true")
        ])
        
        // Validate token was injected during build
        guard githubToken != "GITHUB_TOKEN_PLACEHOLDER" else {
            logger.error("GitHub token not configured")
            throw FeedbackError.apiError("Feedback feature not configured")
        }
        
        let client = app.client
        let request = GitHubIssueRequest(from: feedbackData)
        
        do {
            let response = try await client.post(URI(string: apiURL)) { req in
                req.headers.add(name: .contentType, value: "application/json")
                req.headers.add(name: .authorization, value: "token \(githubToken)")
                req.headers.add(name: .userAgent, value: "NoChat4U-App")
                
                try req.content.encode(request)
            }
            
            guard response.status == .created else {
                let errorMessage = "GitHub API returned status: \(response.status)"
                logger.error("Failed to create issue", metadata: ["status": .string("\(response.status)")])
                throw FeedbackError.apiError(errorMessage)
            }
            
            let githubResponse = try response.content.decode(GitHubIssueResponse.self)
            logger.info("Successfully created GitHub issue", metadata: [
                "issueNumber": .string("\(githubResponse.number)"),
                "issueId": .string("\(githubResponse.id)")
            ])
            
            return githubResponse
            
        } catch let error as FeedbackError {
            throw error
        } catch {
            logger.error("Network error during feedback submission", metadata: ["error": .string(error.localizedDescription)])
            throw FeedbackError.networkError(error.localizedDescription)
        }
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
