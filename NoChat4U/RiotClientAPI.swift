import Foundation
import Logging

/// Calls the local Riot/League APIs to sync the client-side chat status
/// with what NoChat4U shows other users, eliminating the visual mismatch
/// where the League client still shows "Online" even though the proxy
/// intercepts presence stanzas.
enum RiotClientAPI {
    private static let logger = Logger(label: "NoChat4U.RiotClientAPI")
    private static let maxAttempts = 5
    private static let generationLock = NSLock()
    private static var generation = 0

    // MARK: - Lockfile

    /// Static fallback locations. Runtime discovery handles custom installs.
    private static let riotLockfileCandidates: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/Riot Games/Riot Client/Config/lockfile").path
        ]
    }()

    private static let staticLeagueLockfileCandidates = [
        "/Applications/League of Legends.app/Contents/LoL/lockfile"
    ]

    /// Parsed lockfile content.
    private struct Lockfile: Sendable {
        let path: String
        let name: String
        let pid: Int
        let port: Int
        let password: String
        let proto: String

        init?(path: String, line: String) {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 5,
                  let pid = Int(parts[1]),
                  let port = Int(parts[2]) else { return nil }
            self.path = path
            self.name = String(parts[0])
            self.pid = pid
            self.port = port
            self.password = String(parts[3])
            self.proto = String(parts[4])
        }
    }

    private enum LocalChatAPI: Sendable {
        case leagueClient
        case riotClient

        var endpoint: String {
            switch self {
            case .leagueClient:
                return "/lol-chat/v1/me"
            case .riotClient:
                return "/chat/v3/me"
            }
        }

        func body(for state: String) -> [String: String] {
            switch self {
            case .leagueClient:
                return ["availability": state]
            case .riotClient:
                return ["state": state]
            }
        }
    }

    private struct SyncTarget: Sendable {
        let api: LocalChatAPI
        let lockfile: Lockfile
    }

    // MARK: - Public API

    /// Updates the chat state the League client displays to the user.
    ///
    /// - Parameter state: Currently `"chat"` or `"offline"`.
    static func updateState(_ state: String) {
        let generation = nextGeneration()
        Task {
            await syncState(state, attempt: 1, generation: generation)
        }
    }

    /// Best-effort call with retry. Fires a Task so callers never block.
    static func updateState(_ state: String, afterDelay seconds: Double) {
        let generation = nextGeneration()
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await syncState(state, attempt: 1, generation: generation)
        }
    }

    // MARK: - Internal

    private static func syncState(_ state: String, attempt: Int, generation: Int) async {
        guard isCurrentGeneration(generation) else { return }

        guard attempt <= maxAttempts else {
            logger.warning("Giving up after \(maxAttempts) client-side status sync attempts")
            return
        }

        let targets = findSyncTargets()
        guard !targets.isEmpty else {
            logger.debug("No Riot/League lockfile found; retrying client-side status sync")
            await retry(state, attempt: attempt, generation: generation)
            return
        }

        for target in targets {
            guard isCurrentGeneration(generation) else { return }
            if await putState(state, target: target, attempt: attempt) {
                return
            }
        }

        await retry(state, attempt: attempt, generation: generation)
    }

    private static func retry(_ state: String, attempt: Int, generation: Int) async {
        let delay = min(Double(attempt) * 2.0, 10.0)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        await syncState(state, attempt: attempt + 1, generation: generation)
    }

    private static func findSyncTargets() -> [SyncTarget] {
        var targets: [SyncTarget] = []

        for lockfile in readLockfiles(from: leagueLockfileCandidates()) {
            targets.append(SyncTarget(api: .leagueClient, lockfile: lockfile))
        }

        for lockfile in readLockfiles(from: riotLockfileCandidates) {
            targets.append(SyncTarget(api: .riotClient, lockfile: lockfile))
        }

        return targets.reduce(into: [SyncTarget]()) { unique, target in
            let alreadyAdded = unique.contains {
                $0.api.endpoint == target.api.endpoint &&
                $0.lockfile.port == target.lockfile.port
            }
            if !alreadyAdded {
                unique.append(target)
            }
        }
    }

    private static func leagueLockfileCandidates() -> [String] {
        unique(staticLeagueLockfileCandidates + runningLeagueLockfilePaths())
    }

    private static func readLockfiles(from paths: [String]) -> [Lockfile] {
        paths.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            guard let content = try? String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { return nil }

            if let lockfile = Lockfile(path: path, line: content) {
                logger.debug(
                    "Found \(lockfile.name) lockfile",
                    metadata: ["port": .string("\(lockfile.port)")]
                )
                return lockfile
            }
            return nil
        }
    }

    private static func runningLeagueLockfilePaths() -> [String] {
        guard let output = processOutput(
            executable: "/bin/ps",
            arguments: ["-axo", "command="]
        ) else {
            return []
        }

        let marker = "League of Legends.app/Contents/LoL"
        return unique(output.components(separatedBy: .newlines).compactMap { line in
            guard line.contains("LeagueClient"),
                  let range = line.range(of: marker) else { return nil }

            let installRoot = String(line[..<range.upperBound])
            guard installRoot.hasPrefix("/") else { return nil }
            return installRoot + "/lockfile"
        })
    }

    private static func putState(
        _ state: String,
        target: SyncTarget,
        attempt: Int
    ) async -> Bool {
        let lockfile = target.lockfile
        let url = URL(string: "https://127.0.0.1:\(lockfile.port)\(target.api.endpoint)")!

        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Auth: Basic base64("riot:password")
        let authString = "riot:\(lockfile.password)"
        let authData = Data(authString.utf8).base64EncodedString()
        request.setValue("Basic \(authData)", forHTTPHeaderField: "Authorization")

        let body = target.api.body(for: state)
        request.httpBody = try? JSONEncoder().encode(body)

        // Self-signed certificate — accept any server trust.
        let session = URLSession(
            configuration: .ephemeral,
            delegate: AcceptAllCertsDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0
            logger.info(
                "PUT \(target.api.endpoint) → \(statusCode)",
                metadata: [
                    "attempt": .string("\(attempt)"),
                    "lockfile": .string(lockfile.name)
                ]
            )

            if statusCode == 200 || statusCode == 201 || statusCode == 204 {
                logger.info("Client-side chat state synced to \(state)")
                return true
            }

            logger.warning(
                "Client-side chat state sync rejected",
                metadata: [
                    "status": .string("\(statusCode)"),
                    "body": .string(compactBody(data))
                ]
            )
            return false
        } catch {
            logger.warning(
                "PUT \(target.api.endpoint) failed",
                metadata: [
                    "attempt": .string("\(attempt)"),
                    "error": .string(error.localizedDescription)
                ]
            )
            return false
        }
    }

    private static func processOutput(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            logger.debug("Failed to run process \(executable): \(error.localizedDescription)")
            return nil
        }
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { path in
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private static func compactBody(_ data: Data) -> String {
        guard let string = String(data: data, encoding: .utf8) else {
            return "<non-utf8 body>"
        }
        return String(string.prefix(300))
    }

    private static func nextGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        generation += 1
        return generation
    }

    private static func isCurrentGeneration(_ value: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == value
    }
}

// MARK: - URLSession delegate that accepts self-signed TLS certificates

private final class AcceptAllCertsDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
