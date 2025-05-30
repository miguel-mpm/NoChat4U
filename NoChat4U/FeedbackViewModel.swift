import Foundation
import SwiftUI
import Vapor

@MainActor
class FeedbackViewModel: ObservableObject {
    @Published var feedbackData = FeedbackData()
    @Published var state: FeedbackState = .idle
    
    private let feedbackService: FeedbackService
    
    init(app: Application) {
        self.feedbackService = FeedbackService(app: app)
    }
    
    var isSubmitting: Bool {
        if case .submitting = state {
            return true
        }
        return false
    }
    
    var canSubmit: Bool {
        feedbackData.isValid && !isSubmitting
    }
    
    var submitButtonText: String {
        switch state {
        case .submitting:
            return "Sending..."
        default:
            return "Send Feedback"
        }
    }
    
    func submitFeedback() {
        guard canSubmit else { return }
        
        state = .submitting
        
        Task {
            do {
                let response = try await feedbackService.submitFeedback(feedbackData)
                await MainActor.run {
                    state = .success(response)
                }
            } catch {
                await MainActor.run {
                    state = .error(error.localizedDescription)
                }
            }
        }
    }
    
    func reset() {
        feedbackData = FeedbackData()
        state = .idle
    }
    
    func dismiss() {
        // This will be called when the window should be closed
        reset()
    }
} 