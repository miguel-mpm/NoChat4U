import Foundation
import Logging
import os

/// Calls the local Riot/League APIs to sync the client-side chat status
/// with what NoChat4U shows other users, eliminating the visual mismatch
/// where the League client still shows "Online" even though the proxy
/// intercepts presence stanzas.
enum RiotClientAPI {
    private static let logger = Logger(label: "NoChat4U.RiotClientAPI")
    private static let maxAttempts = 5
    private static let currentSync = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    // MARK: - Lockfile

    /// Static fallback location. Runtime discovery handles custom installs.
    private static let staticLeagueLockfile = "/Applications/League of Legends.app/Contents/LoL/lockfile"

    private static let riotLockfile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Riot Games/Riot Client/Config/lockfile").path

    /// Parsed lockfile content: `name:pid:port:password:protocol`.
    private struct Lockfile {
        let name: String
        let port: Int
        let password: String

        init?(line: String) {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 5, let port = Int(parts[2]) else { return nil }
            self.name = String(parts[0])
            self.port = port
            self.password = String(parts[3])
        }
    }

    /// League Client API first (`availability`), Riot Client API as fallback (`state`).
    private struct SyncTarget {
        let endpoint: String
        let bodyKey: String
        let lockfile: Lockfile
    }

    // MARK: - Public API

    /// Updates the chat state the League client displays to the user.
    /// Best effort with retry, never blocks the caller. A newer call cancels
    /// the previous one, so a stale retry cannot overwrite a newer toggle.
    ///
    /// - Parameter state: Currently `"chat"` or `"offline"`.
    static func updateState(_ state: String) {
        currentSync.withLock { current in
            current?.cancel()
            current = Task.detached { await syncState(state) }
        }
    }

    // MARK: - Internal

    private static func syncState(_ state: String) async {
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                try? await Task.sleep(nanoseconds: UInt64(attempt - 1) * 2_000_000_000) // 2, 4, 6, 8 s
            }
            for target in findSyncTargets() {
                guard !Task.isCancelled else { return }
                if await putState(state, target: target, attempt: attempt) { return }
            }
            guard !Task.isCancelled else { return }
        }
        logger.warning("Giving up after \(maxAttempts) client-side status sync attempts")
    }

    private static func findSyncTargets() -> [SyncTarget] {
        var seen = Set<String>()
        let leaguePaths = ([staticLeagueLockfile] + runningLeagueLockfilePaths()).filter { seen.insert($0).inserted }

        var targets = leaguePaths.compactMap(readLockfile).map {
            SyncTarget(endpoint: "/lol-chat/v1/me", bodyKey: "availability", lockfile: $0)
        }
        if let riot = readLockfile(riotLockfile) {
            targets.append(SyncTarget(endpoint: "/chat/v3/me", bodyKey: "state", lockfile: riot))
        }
        return targets
    }

    private static func readLockfile(_ path: String) -> Lockfile? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              let lockfile = Lockfile(line: content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        logger.debug(
            "Found \(lockfile.name) lockfile",
            metadata: ["port": .string("\(lockfile.port)")]
        )
        return lockfile
    }

    private static func runningLeagueLockfilePaths() -> [String] {
        guard let output = processOutput(
            executable: "/bin/ps",
            arguments: ["-axo", "command="]
        ) else {
            return []
        }

        let marker = "League of Legends.app/Contents/LoL"
        return output.components(separatedBy: .newlines).compactMap { line in
            guard line.contains("LeagueClient"),
                  let range = line.range(of: marker) else { return nil }

            let installRoot = String(line[..<range.upperBound])
            guard installRoot.hasPrefix("/") else { return nil }
            return installRoot + "/lockfile"
        }
    }

    private static func putState(
        _ state: String,
        target: SyncTarget,
        attempt: Int
    ) async -> Bool {
        let lockfile = target.lockfile
        let url = URL(string: "https://127.0.0.1:\(lockfile.port)\(target.endpoint)")!

        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Auth: Basic base64("riot:password")
        let authString = "riot:\(lockfile.password)"
        let authData = Data(authString.utf8).base64EncodedString()
        request.setValue("Basic \(authData)", forHTTPHeaderField: "Authorization")

        request.httpBody = try? JSONEncoder().encode([target.bodyKey: state])

        // Self-signed certificate — accept any server trust.
        let session = URLSession(
            configuration: .ephemeral,
            delegate: AcceptAllCertsDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info(
                "PUT \(target.endpoint) → \(statusCode)",
                metadata: [
                    "attempt": .string("\(attempt)"),
                    "lockfile": .string(lockfile.name)
                ]
            )

            if (200..<300).contains(statusCode) {
                logger.info("Client-side chat state synced to \(state)")
                return true
            }

            logger.warning(
                "Client-side chat state sync rejected",
                metadata: [
                    "status": .string("\(statusCode)"),
                    "body": .string(String(decoding: data.prefix(300), as: UTF8.self))
                ]
            )
            return false
        } catch {
            logger.warning(
                "PUT \(target.endpoint) failed",
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
        // Apps started from Finder or at login have no LANG; without a UTF-8
        // locale ps escapes non-ASCII path characters ("è" -> "M-CM-(").
        process.environment = ["LC_ALL": "en_US.UTF-8"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            // Lenient: one process with non-UTF-8 arguments must not hide the others.
            return String(decoding: data, as: UTF8.self)
        } catch {
            logger.debug("Failed to run process \(executable): \(error.localizedDescription)")
            return nil
        }
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
