import Foundation

enum StorageKey {
    static let targetStatus = "targetStatus"
}

class PersistentStorage {
    static let shared = PersistentStorage()
    private let defaults = UserDefaults.standard
    
    private init() {}
    
    var targetStatus: String {
        get {
            return defaults.string(forKey: StorageKey.targetStatus) ?? "chat"
        }
        set {
            defaults.set(newValue, forKey: StorageKey.targetStatus)
        }
    }

    private let appSupportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoChat4U", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func getCachedCert() -> (certData: Data, keyData: Data)? {
        let certPath = appSupportDir.appendingPathComponent("cached-fullchain.pem")
        let keyPath = appSupportDir.appendingPathComponent("cached-privkey.pem")
        guard let certData = try? Data(contentsOf: certPath),
              let keyData = try? Data(contentsOf: keyPath) else { return nil }
        return (certData, keyData)
    }

    func setCachedCert(certData: Data, keyData: Data) {
        let certPath = appSupportDir.appendingPathComponent("cached-fullchain.pem")
        let keyPath = appSupportDir.appendingPathComponent("cached-privkey.pem")
        try? certData.write(to: certPath, options: .atomic)
        try? keyData.write(to: keyPath, options: .atomic)
    }
} 