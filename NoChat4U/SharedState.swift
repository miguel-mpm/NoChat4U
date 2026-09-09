import Foundation
import os

final class SharedState {
    static let shared = SharedState()
    
    private let lock = OSAllocatedUnfairLock()
    
    private var _originalChatHost: String?
    private var _originalChatPort: Int?
    private var _chatProxyPort: Int?
    private var _lastPresenceXML: String?
    
    var originalChatHost: String? { lock.withLock { _originalChatHost } }
    var originalChatPort: Int?    { lock.withLock { _originalChatPort } }
    var chatProxyPort: Int?       { lock.withLock { _chatProxyPort } }
    var lastPresenceXML: String?  { lock.withLock { _lastPresenceXML } }
    
    private init() {}
    
    func setOriginalChatServer(host: String, port: Int) {
        lock.withLock {
            _originalChatHost = host
            _originalChatPort = port
        }
    }
    
    func setChatProxyPort(_ port: Int) {
        lock.withLock { _chatProxyPort = port }
    }
    
    var targetStatus: String {
        get { PersistentStorage.shared.targetStatus }
        set {
            guard newValue == "chat" || newValue == "offline" else { return }
            PersistentStorage.shared.targetStatus = newValue
        }
    }
    
    func setTargetStatus(_ status: String) {
        targetStatus = status
    }
    
    func storeLastPresence(_ xml: String) {
        lock.withLock { _lastPresenceXML = xml }
    }
    
    func getLastPresence() -> String? {
        lock.withLock { _lastPresenceXML }
    }
}
