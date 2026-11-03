import Foundation

// File where we can find the Riot Client installation folder
private let riotClientInstallsPath = "/Users/Shared/Riot Games/RiotClientInstalls.json"
// Track if the client was launched by our app
private var clientLaunchedByApp = false
// The client process launched by our app (kept to signal it only while it runs)
private var launchedClient: Process?

struct RiotClientInstalls: Codable {
    let associated_client: [String: String]
    let patchlines: [String: String]
    let rc_default: String
}

func findLeagueClient() throws -> String {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: riotClientInstallsPath)) else {
        throw LeagueClientError.installFileNotFound
    }
    
    let decoder = JSONDecoder()
    let installs = try decoder.decode(RiotClientInstalls.self, from: data)
    return installs.rc_default
}

public struct ClientStatus {
    let isRunning: Bool
    let launchedByApp: Bool
}

// Main actor: the launch flags above are only read and written there.
@MainActor
public func isRiotClientRunning() async -> ClientStatus {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "RiotClientServices"]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    
    do {
        try process.run()
        
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                continuation.resume()
            }
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        let isRunning = !output.isEmpty
        return ClientStatus(isRunning: isRunning, launchedByApp: clientLaunchedByApp)
    } catch {
        print("Error checking if Riot Client is running: \(error)")
        return ClientStatus(isRunning: false, launchedByApp: false)
    }
}

public func launchLeagueClient(proxyHost: String, proxyPort: UInt16) throws {
    let clientPath = try findLeagueClient()
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: clientPath)
    
    let configUrl = "http://\(proxyHost):\(proxyPort)/customConfig"
    let product = "league_of_legends"
    let patchline = "live"
    process.arguments = ["--client-config-url=\(configUrl)", "--launch-product=\(product)", "--launch-patchline=\(patchline)"]
    
    try process.run()
    
    clientLaunchedByApp = true
    launchedClient = process
}

public func resetClientLaunchedFlag() {
    clientLaunchedByApp = false
    launchedClient = nil
}

// Terminate the launched client process. Synchronous on purpose: it runs
// during app termination, when async work never gets scheduled.
public func terminateLeagueClient() {
    guard clientLaunchedByApp, let client = launchedClient, client.isRunning else {
        print("No running client process launched by the app to terminate.")
        return
    }
    client.terminate()
    print("Sent SIGTERM to client process with PID \(client.processIdentifier)")
    resetClientLaunchedFlag()
}

enum LeagueClientError: Error {
    case installFileNotFound
}
