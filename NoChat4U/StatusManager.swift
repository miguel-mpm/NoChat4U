import Foundation
import SwiftUI
import Vapor
import AppKit
import Logging

@MainActor
class StatusManager: ObservableObject {

    var port: Int = 0
    @Published var isOffline: Bool = false {
        didSet {
            let state = isOffline ? "offline" : "chat"
            SharedState.shared.setTargetStatus(state)
            logger.info("Status changed", metadata: ["status": .string(state)])
            
            NotificationCenter.default.post(name: Notification.Name("StatusChanged"), object: nil)
            
            // Sync the visual status in the League client UI so it matches
            // what other users see via the proxy (issue #3). Only a client we
            // launched goes through the proxy; leave any other one alone.
            if isClientLaunchedByApp {
                RiotClientAPI.updateState(state)
            }
        }
    }
    
    @Published var isClientRunning: Bool = false
    @Published var isClientLaunchedByApp: Bool = false
    @Published var chatTLSFailed = false
    
    private var chatProxy: ChatProxy?
    private let logger = Logger(label: "NoChat4U.StatusManager")
    private var clientCheckTimer: Timer?
    private var app: Application?
    
    var vaporApp: Application? {
        return app
    }
        
    init() {
        let persistedStatus = SharedState.shared.targetStatus
        isOffline = persistedStatus == "offline"
        logger.info("Loaded persisted status", metadata: ["status": .string(persistedStatus)])
        
        // The chat proxy reports whether Riot's chat server passed the TLS check.
        NotificationCenter.default.addObserver(forName: Notification.Name("ChatTLSStatus"), object: nil, queue: .main) { [weak self] note in
            let ok = note.userInfo?["ok"] as? Bool ?? true
            MainActor.assumeIsolated { self?.chatTLSFailed = !ok }
        }
        
        Task {
            var env = try Environment.detect()
            try LoggingSystem.bootstrap(from: &env)

            let vaporApp = try await Application.make(env)
            self.app = vaporApp

            vaporApp.http.server.configuration.port = 0
            vaporApp.http.server.configuration.hostname = "127.0.0.1"
            vaporApp.http.server.configuration.backlog = 8
            vaporApp.http.server.configuration.reuseAddress = true

            do {
                try await route(vaporApp)
                try await vaporApp.startup()

                let (chain, key) = try await CertificateManager.fetchCertificate()

                let proxy = try ChatProxy(certificateChain: chain, privateKey: key)
                self.chatProxy = proxy
                try proxy.start()
            } catch {
                vaporApp.logger.report(error: error)
                try? await vaporApp.asyncShutdown()

                let alert = NSAlert()
                alert.messageText = "NoChat4U failed to start"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }

            self.port = vaporApp.http.server.shared.localAddress?.port ?? 0
            self.startClientMonitoring()
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
        Task { @MainActor in
            await checkClientStatus()
        }
        
        clientCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkClientStatus()
            }
        }
    }
    
    private func checkClientStatus() async {
        let status = await isRiotClientRunning()
        
        if isClientRunning && !status.isRunning {
            resetClientLaunchedFlag()
        }
        
        if status.isRunning != isClientRunning || status.launchedByApp != isClientLaunchedByApp {
            isClientRunning = status.isRunning
            isClientLaunchedByApp = status.launchedByApp
            if !status.isRunning {
                chatTLSFailed = false
            }
            
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
            
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await checkClientStatus()
            }
        } catch {
            self.logger.error("Failed to launch League client: \(error)")
        }
    }
}
