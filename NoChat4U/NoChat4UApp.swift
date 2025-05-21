import SwiftUI
import AppKit 

public class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationWillTerminate(_ notification: Notification) {
        // Terminate the Riot Client when the app closes
        terminateLeagueClient()
    }
}

@main
struct NoChat4UApp: App {
    // Hook into AppKit lifecycle events
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @StateObject private var statusManager = StatusManager()
    
    let sparkle = Sparkle()
    
    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(statusManager: statusManager)
                .environment(sparkle)
        } label: {
            Image(systemName: statusManager.isOffline ? "person.slash.fill" : "person.fill")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
} 
