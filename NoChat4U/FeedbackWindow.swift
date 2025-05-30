import SwiftUI

struct FeedbackWindow: View {
    @ObservedObject var viewModel: FeedbackViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 16) {
                HStack {
                    Text("Send Feedback")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    Button("Cancel") {
                        viewModel.dismiss()
                        closeWindow()
                    }
                    .buttonStyle(.bordered)
                }
                
                Text("Help us improve NoChat4U by sharing your feedback, bug reports, or feature requests.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)
            
            Divider()
            
            // Content
            ScrollView {
                VStack(spacing: 20) {
                    switch viewModel.state {
                    case .idle, .submitting:
                        feedbackForm
                    case .success(let response):
                        successView(response: response)
                    case .error(let errorMessage):
                        errorView(errorMessage: errorMessage)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 500, height: 550)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func closeWindow() {
        // Find and close the current window
        if let window = NSApp.keyWindow {
            window.close()
        }
    }
    
    @ViewBuilder
    private var feedbackForm: some View {
        VStack(spacing: 16) {
            // Privacy Notice
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                Text("All data on this form will be posted as a public GitHub issue")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(6)
            
            // Title Field
            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.headline)
                TextField("Brief description of your feedback", text: $viewModel.feedbackData.title)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isSubmitting)
            }
            
            // Email Field
            VStack(alignment: .leading, spacing: 6) {
                Text("Email (Optional)")
                    .font(.headline)
                TextField("your.email@example.com", text: $viewModel.feedbackData.email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isSubmitting)
                Text("We'll use this to follow up on your feedback if needed. Note: This will be visible in the public GitHub issue.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Body Field
            VStack(alignment: .leading, spacing: 6) {
                Text("Details")
                    .font(.headline)
                
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.textBackgroundColor))
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        .frame(minHeight: 150)
                    
                    if viewModel.feedbackData.body.isEmpty {
                        Text("Please describe your feedback, bug report, or feature request in detail...")
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 8)
                    }
                    
                    TextEditor(text: $viewModel.feedbackData.body)
                        .padding(4)
                        .disabled(viewModel.isSubmitting)
                        .background(Color.clear)
                }
                .frame(minHeight: 150)
            }
            
            Spacer(minLength: 20)
            
            // Submit Button
            HStack {
                Spacer()
                Button(viewModel.submitButtonText) {
                    viewModel.submitFeedback()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmit)
            }
        }
    }
    
    @ViewBuilder
    private func successView(response: GitHubIssueResponse) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            
            Text("Feedback Sent Successfully!")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Thank you for your feedback! We've created issue #\(response.number) to track your submission.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(spacing: 12) {
                Button("View on GitHub") {
                    if let url = URL(string: response.htmlUrl) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                
                
                Button("Send Another") {
                    viewModel.reset()
                }
                .buttonStyle(.borderedProminent)
            }
            
            Spacer()
        }
        .padding(.top, 40)
    }
    
    @ViewBuilder
    private func errorView(errorMessage: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Failed to Send Feedback")
                .font(.title2)
                .fontWeight(.bold)
            
            Text(errorMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(spacing: 12) {
                Button("Try Again") {
                    viewModel.state = .idle
                }
                .buttonStyle(.borderedProminent)
                
                Button("Cancel") {
                    viewModel.dismiss()
                    closeWindow()
                }
                .buttonStyle(.bordered)
            }
            
            Spacer()
        }
        .padding(.top, 40)
    }
} 