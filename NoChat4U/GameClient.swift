import Foundation

// File where we can find the Riot Client installation folder
private let riotClientInstallsPath = "/Users/Shared/Riot Games/RiotClientInstalls.json"
// Track if the client was launched by our app
private var clientLaunchedByApp = false
// Track the PID of the client process launched by our app
private var launchedClientPID: Int32? = nil

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

public func isRiotClientRunning() -> ClientStatus {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "RiotClientServices"]
    
    let pipe = Pipe()
    process.standardOutput = pipe
    
    do {
        try process.run()
        process.waitUntilExit()
        
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
    
    // Mark that we've launched the client
    clientLaunchedByApp = true
    // Store the PID of the launched process
    launchedClientPID = process.processIdentifier
}

public func resetClientLaunchedFlag() {
    clientLaunchedByApp = false
    launchedClientPID = nil
}

// Terminate the launched client process
public func terminateLeagueClient() {
    if clientLaunchedByApp, let pid = launchedClientPID {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/kill")
        process.arguments = ["\(pid)"]

        do {
            try process.run()
            process.waitUntilExit()
            print("Attempted to terminate client process with PID \(pid)")
        } catch {
            print("Error attempting to terminate client process \(pid): \(error)")
        }

        resetClientLaunchedFlag()
    } else {
        print("No client process launched by the app to terminate.")
    }
}

enum LeagueClientError: Error {
    case installFileNotFound
} 
