import Foundation
import Logging

/// Calls the Riot Client local API to sync the client-side chat status
/// with what NoChat4U shows other users, eliminating the visual mismatch
/// where the League client still shows "Online" even though the proxy
/// intercepts presence stanzas.
enum RiotClientAPI {
    private static let logger = Logger(label: "NoChat4U.RiotClientAPI")

    // MARK: - Lockfile

    /// Known lockfile locations, ordered by priority.
    private static let lockfileCandidates: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            // Riot Client launcher (multi-game)
            home.appendingPathComponent("Library/Application Support/Riot Games/Riot Client/Config/lockfile").path,
            // League of Legends game client
            "/Applications/League of Legends.app/Contents/LoL/lockfile",
        ]
    }()

    /// Parsed lockfile content.
    private struct Lockfile: Sendable {
        let name: String
        let pid: Int
        let port: Int
        let password: String
        let proto: String

        init?(line: String) {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 5,
                  let pid = Int(parts[1]),
                  let port = Int(parts[2]) else { return nil }
            self.name = String(parts[0])
            self.pid = pid
            self.port = port
            self.password = String(parts[3])
            self.proto = String(parts[4])
        }
    }

    // MARK: - Public API

    /// Updates the chat state the League client displays to the user.
    ///
    /// - Parameter state: One of the `ChatAccountState` enum values.
    ///   Currently only `"chat"` and `"offline"` are used by NoChat4U.
    ///   Accepts: `"chat"`, `"offline"`, `"away"`, `"mobile"`, `"dnd"`.
    static func updateState(_ state: String) {
        guard let lockfile = findLockfile() else {
            logger.debug("No Riot Client lockfile found; skipping client-side status sync")
            return
        }
        logger.info(
            "Syncing client-side chat state",
            metadata: ["state": .string(state), "port": .string("\(lockfile.port)")]
        )

        Task {
            await putState(state, lockfile: lockfile, attempt: 1)
        }
    }

    /// Best-effort call with retry. Fires a Task so callers never block.
    static func updateState(_ state: String, afterDelay seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let lockfile = findLockfile() else {
                logger.debug("No lockfile after delay; giving up")
                return
            }
            await putState(state, lockfile: lockfile, attempt: 1)
        }
    }

    // MARK: - Internal

    private static func findLockfile() -> Lockfile? {
        for path in lockfileCandidates {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { continue }

            if let lockfile = Lockfile(line: content) {
                logger.debug("Found lockfile at \(path) — port \(lockfile.port)")
                return lockfile
            }
        }
        return nil
    }

    private static func putState(
        _ state: String,
        lockfile: Lockfile,
        attempt: Int
    ) async {
        let maxAttempts = 5
        guard attempt <= maxAttempts else {
            logger.warning("Giving up after \(maxAttempts) attempts")
            return
        }

        let url = URL(string: "https://127.0.0.1:\(lockfile.port)/chat/v3/me")!

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Auth: Basic base64("riot:password")
        let authString = "riot:\(lockfile.password)"
        let authData = Data(authString.utf8).base64EncodedString()
        request.setValue("Basic \(authData)", forHTTPHeaderField: "Authorization")

        // ChatChatGamePresence schema (all fields optional).
        // Only `state` is needed to change the chat presence dot.
        let body: [String: String] = ["state": state]
        request.httpBody = try? JSONEncoder().encode(body)

        // Self-signed certificate — accept any server trust.
        let session = URLSession(
            configuration: .ephemeral,
            delegate: AcceptAllCertsDelegate(),
            delegateQueue: nil
        )

        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            logger.info(
                "PUT /chat/v3/me → \(httpResponse?.statusCode ?? 0)",
                metadata: ["attempt": .string("\(attempt)")]
            )

            if httpResponse?.statusCode == 200 || httpResponse?.statusCode == 204 {
                logger.info("Client-side chat state synced to \(state)")
            } else if let body = String(data: data, encoding: .utf8) {
                logger.debug("Response body: \(body)")
            }
        } catch {
            let delay = min(Double(attempt) * 2.0, 10.0)
            logger.warning(
                "PUT /chat/v3/me failed (attempt \(attempt)): \(error.localizedDescription). Retrying in \(delay)s"
            )
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await putState(state, lockfile: lockfile, attempt: attempt + 1)
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
