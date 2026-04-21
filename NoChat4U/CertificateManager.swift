import Foundation
import NIOSSL
import Security

enum CertificateError: LocalizedError {
    case downloadFailed(Error)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let underlying):
            return "Failed to download the security certificate. Check your internet connection or look for a new version of NoChat4U. (\(underlying.localizedDescription))"
        case .parseFailed:
            return "Failed to parse the security certificate. Please look for a new version of NoChat4U."
        }
    }
}

struct CertificateManager {
    private static let certURL = URL(string: "https://raw.githubusercontent.com/miguel-mpm/NoChat4U/main/certs/fullchain.pem")!
    private static let keyURL = URL(string: "https://raw.githubusercontent.com/miguel-mpm/NoChat4U/main/certs/privkey.pem")!
    private static let renewalBuffer: TimeInterval = 20 * 24 * 60 * 60 // 20 days

    static func fetchCertificate() async throws -> (certificateChain: [NIOSSLCertificate], privateKey: NIOSSLPrivateKey) {
        // Use valid cached cert if it's not expiring soon
        if let (certData, keyData) = PersistentStorage.shared.getCachedCert(),
           let expiry = certExpiry(from: certData),
           expiry > Date().addingTimeInterval(renewalBuffer) {
            if let chain = try? NIOSSLCertificate.fromPEMBytes([UInt8](certData)),
               let key = try? NIOSSLPrivateKey(bytes: [UInt8](keyData), format: .pem),
               !chain.isEmpty {
                logCertValidity(from: certData, source: "cache")
                return (chain, key)
            }
        }

        // Download fresh cert and key from the repo
        do {
            print("[CertificateManager] Downloading certificate from GitHub...")
            let (certData, _) = try await URLSession.shared.data(from: certURL)
            let (keyData, _) = try await URLSession.shared.data(from: keyURL)

            guard let chain = try? NIOSSLCertificate.fromPEMBytes([UInt8](certData)),
                  !chain.isEmpty,
                  let key = try? NIOSSLPrivateKey(bytes: [UInt8](keyData), format: .pem) else {
                throw CertificateError.parseFailed
            }

            PersistentStorage.shared.setCachedCert(certData: certData, keyData: keyData)
            logCertValidity(from: certData, source: "download")
            return (chain, key)
        } catch is CertificateError {
            throw CertificateError.parseFailed
        } catch {
            throw CertificateError.downloadFailed(error)
        }
    }

    private static func logCertValidity(from pemData: Data, source: String) {
        let notBefore = certDate(from: pemData, key: kSecOIDX509V1ValidityNotBefore)
        let notAfter = certExpiry(from: pemData)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let before = notBefore.map { formatter.string(from: $0) } ?? "unknown"
        let after = notAfter.map { formatter.string(from: $0) } ?? "unknown"
        print("[CertificateManager] Certificate loaded from \(source) — valid \(before) → \(after)")
    }

    private static func certDate(from pemData: Data, key: CFString) -> Date? {
        guard let pemString = String(data: pemData, encoding: .utf8),
              let startRange = pemString.range(of: "-----BEGIN CERTIFICATE-----"),
              let endRange = pemString.range(of: "-----END CERTIFICATE-----") else { return nil }

        let base64 = String(pemString[startRange.upperBound..<endRange.lowerBound])
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        guard let derData = Data(base64Encoded: base64),
              let secCert = SecCertificateCreateWithData(nil, derData as CFData) else { return nil }

        let keys = [key] as CFArray
        guard let values = SecCertificateCopyValues(secCert, keys, nil) as? [String: Any],
              let dict = values[key as String] as? [String: Any],
              let date = dict[kSecPropertyKeyValue as String] as? Date else { return nil }

        return date
    }

    // Extract the expiry date from the first certificate in a PEM chain
    private static func certExpiry(from pemData: Data) -> Date? {
        return certDate(from: pemData, key: kSecOIDX509V1ValidityNotAfter)
    }
}
