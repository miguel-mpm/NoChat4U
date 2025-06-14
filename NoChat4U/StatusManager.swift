import Foundation
import SwiftUI
import Vapor
import Logging

@MainActor
class StatusManager: ObservableObject {

    var port: Int = 0
    @Published var isOffline: Bool = false {
        didSet {
            // Update SharedState when isOffline changes
            SharedState.shared.setTargetStatus(isOffline ? "offline" : "chat")
            logger.info("Status changed", metadata: ["status": .string(isOffline ? "offline" : "chat")])
            
            // Post notification to trigger presence update
            NotificationCenter.default.post(name: Notification.Name("StatusChanged"), object: nil)
        }
    }
    
    @Published var isClientRunning: Bool = false
    @Published var isClientLaunchedByApp: Bool = false
    
    private var chatProxy: ChatProxy?
    private let logger = Logger(label: "NoChat4U.StatusManager")
    private var clientCheckTimer: Timer?
    private var app: Application?
    
    // Public accessor for the Vapor app for feedback functionality
    var vaporApp: Application? {
        return app
    }
        
    init() {
        // Load persisted status
        let persistedStatus = SharedState.shared.targetStatus
        isOffline = persistedStatus == "offline"
        logger.info("Loaded persisted status", metadata: ["status": .string(persistedStatus)])
        
        Task {
            var env = try Environment.detect()
            try LoggingSystem.bootstrap(from: &env)

            let vaporApp = try await Application.make(env)
            self.app = vaporApp

            vaporApp.http.server.configuration.port = 0 // Random port
            vaporApp.http.server.configuration.hostname = "127.0.0.1"
            vaporApp.http.server.configuration.backlog = 8
            vaporApp.http.server.configuration.reuseAddress = true

            do {
                try await route(vaporApp)
                try await vaporApp.startup()
                
                // Start chat proxy
                chatProxy = try ChatProxy()
                try chatProxy?.start()
            } catch {
                vaporApp.logger.report(error: error)
                try? await vaporApp.asyncShutdown()
                throw error
            }

            port = vaporApp.http.server.shared.localAddress?.port ?? 0
            
            // Start checking for Riot client
            startClientMonitoring()
        }
    }
    
    deinit {
        clientCheckTimer?.invalidate()
        chatProxy?.stop()
        Task {
            try? await app?.asyncShutdown()
        }
    }
    
    func startClientMonitoring() {
        // Check initially
        Task { @MainActor in
            await checkClientStatus()
        }
        
        // Check every 2 seconds
        clientCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkClientStatus()
            }
        }
    }
    
    private func checkClientStatus() async {
        let status = isRiotClientRunning()
        
        // If client was running and is now not running, reset the launchedByApp flag
        if isClientRunning && !status.isRunning {
            resetClientLaunchedFlag()
        }
        
        if status.isRunning != isClientRunning || status.launchedByApp != isClientLaunchedByApp {
            isClientRunning = status.isRunning
            isClientLaunchedByApp = status.launchedByApp
            
            logger.info(
                "Riot client status changed", 
                metadata: [
                    "running": .string(status.isRunning ? "yes" : "no"), 
                    "launchedByApp": .string(status.launchedByApp ? "yes" : "no")
                ]
            )
        }
    }
    
    func launchGame() {
        do {
            let configPort = port
            try launchLeagueClient(proxyHost: "127.0.0.1", proxyPort: UInt16(configPort))
            
            // Immediately check client status after launch attempt
            Task { @MainActor in
                // Give it a moment to start
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await checkClientStatus()
            }
        } catch {
            self.logger.error("Failed to launch League client: \(error)")
        }
    }
} 
