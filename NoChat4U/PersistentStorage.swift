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
} 