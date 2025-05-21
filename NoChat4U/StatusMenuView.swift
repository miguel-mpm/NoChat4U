import AppKit
import LaunchAtLogin
import SwiftUI
import Sparkle
import Combine

struct MenuDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
    }
}

extension View {
    @ViewBuilder
    func hovered(_ isHovered: Binding<Bool>) -> some View {
        if #available(macOS 13.0, *) {
            self.onHover { hovering in
                isHovered.wrappedValue = hovering
            }
        } else {
            self
        }
    }
}

struct MenuItemButton: View {
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

    var body: some View {
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

struct StatusMenuView: View {
    @ObservedObject var statusManager: StatusManager
    @Environment(\.openWindow) private var openWindow
    @Environment(Sparkle.self) var sparkle
        
    init(statusManager: StatusManager) {
        self.statusManager = statusManager
    }

    var body: some View {
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
