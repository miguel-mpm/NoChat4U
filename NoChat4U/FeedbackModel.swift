import Foundation
import Vapor

// MARK: - Feedback Form Data
struct FeedbackData {
    var title: String = ""
    var email: String = ""
    var body: String = ""
    
    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - GitHub API Models
struct GitHubIssueRequest: Content {
    let title: String
    let body: String
    
    init(from feedbackData: FeedbackData) {
        self.title = feedbackData.title
        
        var bodyText = feedbackData.body
        if !feedbackData.email.isEmpty {
            bodyText = "**Contact Email:** \(feedbackData.email)\n\n\(feedbackData.body)"
        }
        bodyText += "\n\n---\n*Submitted via NoChat4U Feedback*"
        
        self.body = bodyText
    }
}

struct GitHubIssueResponse: Content {
    let id: Int
    let number: Int
    let title: String
    let htmlUrl: String
    
    enum CodingKeys: String, CodingKey {
        case id, number, title
        case htmlUrl = "html_url"
    }
}

// MARK: - Feedback States
enum FeedbackState {
    case idle
    case submitting
    case success(GitHubIssueResponse)
    case error(String)
} 