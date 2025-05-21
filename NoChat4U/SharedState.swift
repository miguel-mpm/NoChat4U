import Foundation

class SharedState {
    static let shared = SharedState()
    
    private(set) var originalChatHost: String?
    private(set) var originalChatPort: Int?
    private(set) var chatProxyPort: Int?
    private(set) var lastPresenceXML: String?
    
    private init() {}
    
    func setOriginalChatServer(host: String, port: Int) {
        self.originalChatHost = host
        self.originalChatPort = port
    }
    
    func setChatProxyPort(_ port: Int) {
        self.chatProxyPort = port
    }
    
    var targetStatus: String {
        get {
            return PersistentStorage.shared.targetStatus
        }
        set {
            guard newValue == "chat" || newValue == "offline" else {
                return
            }
            PersistentStorage.shared.targetStatus = newValue
        }
    }
    
    func setTargetStatus(_ status: String) {
        self.targetStatus = status
    }
    
    func storeLastPresence(_ xml: String) {
        self.lastPresenceXML = xml
    }
    
    func getLastPresence() -> String? {
        return lastPresenceXML
    }
} 