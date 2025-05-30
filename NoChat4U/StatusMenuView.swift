import AppKit
import LaunchAtLogin
import SwiftUI
import Sparkle
import Combine
import Vapor

struct MenuDivider: SwiftUI.View {
    var body: some SwiftUI.View {
        Divider()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
    }
}

extension SwiftUI.View {
    @ViewBuilder
    func hovered(_ isHovered: Binding<Bool>) -> some SwiftUI.View {
        if #available(macOS 13.0, *) {
            self.onHover { hovering in
                isHovered.wrappedValue = hovering
            }
        } else {
            self
        }
    }
}

struct MenuItemButton: SwiftUI.View {
    let title: String
    let icon: String
    let action: () -> Void
    let isDisabled: Bool
    @State private var isHovered = false

    init(
        title: String,
        icon: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some SwiftUI.View {
        Button(action: action) {
            HStack {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Spacer()

                }.frame(width: 20)
                Text(title)
                    .font(.system(size: 13))
                Spacer()

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                isHovered && !isDisabled
                    ? Color(NSColor.gray.withAlphaComponent(0.2))
                    : Color.clear
            )
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
        .hovered($isHovered)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSVisualEffectView()
        view.material = .menu
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

class FeedbackWindowController: NSWindowController {
    private var feedbackViewModel: FeedbackViewModel?
    
    init(app: Application) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 550),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: window)
        
        self.feedbackViewModel = FeedbackViewModel(app: app)
        
        window.title = "Send Feedback - NoChat4U"
        window.center()
        window.setFrameAutosaveName("FeedbackWindow")
        window.isReleasedWhenClosed = false
        
        // Set window level to appear above menu bar extras
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // Create the SwiftUI view
        let feedbackView = FeedbackWindow(viewModel: feedbackViewModel!)
        let hostingController = NSHostingController(rootView: feedbackView)
        window.contentViewController = hostingController
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func showWindow() {
        guard let window = self.window else { return }
        
        // Ensure window appears above everything
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        
        // Activate the app and show the window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        
        // Force focus after a tiny delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            window.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct StatusMenuView: SwiftUI.View {
    @ObservedObject var statusManager: StatusManager
    @SwiftUI.Environment(\.openWindow) private var openWindow
    @SwiftUI.Environment(Sparkle.self) var sparkle
    
    private static var feedbackWindowController: FeedbackWindowController?
        
    init(statusManager: StatusManager) {
        self.statusManager = statusManager
    }

    var body: some SwiftUI.View {
        @Bindable var sparkle = sparkle
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("NoChat4U")
                    .font(.system(size: 13).weight(.bold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            MenuDivider()

            // Status
            HStack {
                HStack {
                    Circle()
                        .fill(statusManager.isOffline ? .offline : .online)
                        .frame(width: 10, height: 10)
                    Spacer()
                }.frame(width: 20)

                Text(statusManager.isOffline ? "Offline" : "Online")
                    .font(.system(size: 13))
                Spacer()

                Toggle(
                    "",
                    isOn: Binding(
                        get: { !statusManager.isOffline },
                        set: { statusManager.isOffline = !$0 }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            // Launch at Login
            HStack {
                HStack {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Spacer()
                }.frame(width: 20)
                Text("Launch at login")
                Spacer()
                LaunchAtLogin.Toggle {
                    Text("")

                }.toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            
            // Updates
            HStack{
                MenuItemButton(
                    title: "Check for updates...",
                    icon: "arrow.clockwise",
                    action: { self.sparkle.checkForUpdates() }
                )
                Spacer()
                Divider()
                Toggle("auto", isOn: $sparkle.automaticallyChecksForUpdates)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.trailing, 10)
            }

            MenuDivider()

            // Send Feedback
            MenuItemButton(
                title: "Send feedback",
                icon: "envelope",
                action: { openFeedbackWindow() }
            )

            MenuDivider()

            // Play button
            MenuItemButton(
                title: getPlayButtonText(),
                icon: getPlayButtonIcon(),
                isDisabled: statusManager.isClientRunning,
                action: { statusManager.launchGame() }
            )

            MenuDivider()

            // Quit
            MenuItemButton(
                title: "Quit",
                icon: "power",
                action: { NSApplication.shared.terminate(nil) }
            )
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .frame(width: 300)
        .background(VisualEffect())
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
        )
    }
    
    private func openFeedbackWindow() {
        guard let app = statusManager.vaporApp else { return }
        
        if StatusMenuView.feedbackWindowController == nil {
            StatusMenuView.feedbackWindowController = FeedbackWindowController(app: app)
        }
        
        StatusMenuView.feedbackWindowController?.showWindow()
    }
    
    private func getPlayButtonText() -> String {
        if statusManager.isClientRunning {
            if statusManager.isClientLaunchedByApp {
                return "Already running"
            } else {
                return "Close Riot Client first!"
            }
        } else {
            return "Play"
        }
    }
    
    private func getPlayButtonIcon() -> String {
        if statusManager.isClientRunning && !statusManager.isClientLaunchedByApp {
            return "exclamationmark.triangle"
        } else {
            return "gamecontroller"
        }
    }
}
