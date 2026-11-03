import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOSSL
import Logging

private var logger = Logger(label: "NoChat4U.ChatProxy")

final class ChatProxy {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private let connectionsLock = NIOLock()
    private var connections = [ObjectIdentifier: ProxiedConnection]()
    private let serverSSLContext: NIOSSLContext
 
    init(certificateChain: [NIOSSLCertificate], privateKey: NIOSSLPrivateKey) throws {
        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificateChain.map { .certificate($0) },
            privateKey: .privateKey(privateKey)
        )
        serverConfig.certificateVerification = .none
        serverConfig.minimumTLSVersion = .tlsv12
        
        self.serverSSLContext = try NIOSSLContext(configuration: serverConfig)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusChanged),
            name: Notification.Name("StatusChanged"),
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func statusChanged() {
        sendUpdatedPresence()
    }
    
    private func sendUpdatedPresence() {
        let all = connectionsLock.withLock { Array(connections.values) }
        all.forEach { $0.resendLastPresence() }
    }
    
    func start() throws {
        logger.logLevel = .info
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                logger.debug("New client connection received")
                
                let connection = ProxiedConnection(clientChannel: channel, eventLoop: channel.eventLoop)
                self.connectionsLock.withLock {
                    self.connections[ObjectIdentifier(connection)] = connection
                }
                
                channel.closeFuture.whenComplete { [weak self] _ in
                    guard let self = self else { return }
                    self.connectionsLock.withLock {
                        if let connId = self.connections.first(where: { $0.value.clientChannel === channel })?.key {
                            logger.info("Removing connection on client disconnect")
                            self.connections.removeValue(forKey: connId)
                        }
                    }
                }
                
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: self.serverSSLContext))
                }.flatMap { _ in
                    return self.connectToServer(connection: connection).flatMap { serverChannel in
                        logger.debug("Successfully connected to server, adding client handler")
                        return channel.pipeline.addHandler(ClientToServerHandler(connection: connection))
                    }
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
        
        bootstrap.bind(host: "127.0.0.1", port: 0).whenComplete { result in
            switch result {
            case .success(let channel):
                if let port = channel.localAddress?.port {
                    SharedState.shared.setChatProxyPort(port)
                    logger.info("Chat proxy started on port \(port)")
                }
            case .failure(let error):
                logger.error("Failed to start chat proxy: \(error)")
            }
        }
    }
    
    private func connectToServer(connection: ProxiedConnection) -> EventLoopFuture<Channel> {
        guard let host = SharedState.shared.originalChatHost,
              let port = SharedState.shared.originalChatPort,
              port > 0 else {
            return connection.clientChannel.eventLoop.makeFailedFuture(
                ChatProxyError.missingServerInfo
            )
        }
        
        logger.info("Connecting to server \(host):\(port)")
        
        let sslContext: NIOSSLContext
        
        var sslConfig = TLSConfiguration.makeClientConfiguration()
        sslConfig.certificateVerification = .fullVerification
        sslConfig.applicationProtocols = ["xmpp-client"]
        sslConfig.minimumTLSVersion = .tlsv12
        
        do {
            sslContext = try NIOSSLContext(configuration: sslConfig)
        } catch {
            logger.error("Failed to create SSL context: \(error)")
            return connection.clientChannel.eventLoop.makeFailedFuture(error)
        }
        
        // Same event loop as the client channel: both directions of a
        // connection run on one thread, so its state needs no locking.
        let bootstrap = ClientBootstrap(group: connection.clientChannel.eventLoop)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(10))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    try sync.addHandler(NIOSSLClientHandler(context: sslContext, serverHostname: host))
                    try sync.addHandler(ServerToClientHandler(connection: connection))
                }
            }
        
        return bootstrap.connect(host: host, port: port).map { serverChannel in
            logger.info("TCP connected to Riot chat server, starting TLS")
            connection.serverChannel = serverChannel
            
            serverChannel.closeFuture.whenComplete { _ in
                logger.debug("Server disconnected, closing client connection")
                connection.clientChannel.close(promise: nil)
            }
            
            return serverChannel
        }
    }
    
    /// Closes every channel, the listening one included, without blocking.
    func stop() {
        logger.info("Stopping chat proxy")
        group.shutdownGracefully { _ in }
    }
}

enum ChatProxyError: Error {
    case missingServerInfo
}

/// A connection between a client and server
final class ProxiedConnection {
    let clientChannel: Channel
    private let eventLoop: EventLoop
    // Touched only on eventLoop, which the client and server channels share.
    private var pendingToServer: [UInt8] = []
    private var lastPresence: String?
    private var clientStateChecked = false
    private static let presenceOpen = Array("<presence".utf8)
    private static let presenceClose = Array("</presence>".utf8)
    private let serverChannelLock = NIOLock()
    private var _serverChannel: Channel?
    
    var serverChannel: Channel? {
        get { serverChannelLock.withLock { _serverChannel } }
        set { serverChannelLock.withLock { _serverChannel = newValue } }
    }
    
    init(clientChannel: Channel, eventLoop: EventLoop) {
        self.clientChannel = clientChannel
        self.eventLoop = eventLoop
    }
    
    /// Forward data from client to server, rewriting presence stanzas if needed.
    /// Bytes from an unfinished `<presence` on wait for the rest of the stanza,
    /// so a presence split across reads is never forwarded unmodified.
    func processClientData(_ data: ByteBuffer) -> EventLoopFuture<Void> {
        eventLoop.assertInEventLoop()
        guard let serverChannel = serverChannel else {
            return eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
        }
        pendingToServer.append(contentsOf: data.readableBytesView)
        
        var out = ByteBuffer()
        var start = 0
        while true {
            guard let open = pendingToServer[start...].firstRange(of: Self.presenceOpen) else {
                // Forward all but a tail that may be the beginning of "<presence".
                let end = pendingToServer.count - Self.partialPrefixLength(pendingToServer[start...])
                out.writeBytes(pendingToServer[start..<end])
                start = end
                break
            }
            out.writeBytes(pendingToServer[start..<open.lowerBound])
            start = open.lowerBound
            guard let end = Self.stanzaEnd(in: pendingToServer, after: open.upperBound) else { break }
            
            let stanza = String(decoding: pendingToServer[start..<end], as: UTF8.self)
            start = end
            if !stanza.contains("to='") {
                handleClientPresence(stanza)
            }
            let modifiedStanza = modifyPresenceXML(stanza, targetStatus: SharedState.shared.targetStatus)
            logger.debug("Modified presence stanza: \(modifiedStanza)")
            out.writeString(modifiedStanza)
        }
        pendingToServer.removeFirst(start)
        
        guard out.readableBytes > 0 else { return eventLoop.makeSucceededVoidFuture() }
        return serverChannel.writeAndFlush(out)
    }
    
    /// Re-sends this connection's last presence for the current target status.
    func resendLastPresence() {
        eventLoop.execute {
            guard let presence = self.lastPresence, let serverChannel = self.serverChannel else { return }
            let modifiedStanza = modifyPresenceXML(presence, targetStatus: SharedState.shared.targetStatus)
            serverChannel.writeAndFlush(ByteBuffer(string: modifiedStanza), promise: nil)
        }
    }
    
    /// Handles the client's own broadcast presence.
    private func handleClientPresence(_ stanza: String) {
        let showsOffline = stanza.contains("<show>offline</show>")
        // First presence: the chat is up, so is the client's local API. Align
        // the state the client shows with NoChat4U's (issue #3), whenever the
        // user logs in, and also when the client restored an old offline state.
        if !clientStateChecked {
            clientStateChecked = true
            let target = SharedState.shared.targetStatus
            if showsOffline != (target == "offline") {
                RiotClientAPI.updateState(target)
            }
        }
        // Remember it for re-sending, unless offline or unavailable: re-sending
        // those after going back online would keep the user hidden.
        guard !showsOffline, !stanza.contains("type='unavailable'") else { return }
        lastPresence = stanza
    }
    
    /// Index just past the presence whose `<presence` name ends at `nameEnd`,
    /// or nil while the stanza is still incomplete.
    private static func stanzaEnd(in bytes: [UInt8], after nameEnd: Int) -> Int? {
        guard let tagEnd = bytes[nameEnd...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
        if bytes[tagEnd - 1] == UInt8(ascii: "/") {
            return tagEnd + 1 // self-closing <presence ... />
        }
        return bytes[(tagEnd + 1)...].firstRange(of: presenceClose)?.upperBound
    }
    
    /// Length of the longest tail of `bytes` that is a proper prefix of "<presence".
    private static func partialPrefixLength(_ bytes: ArraySlice<UInt8>) -> Int {
        for length in stride(from: min(presenceOpen.count - 1, bytes.count), to: 0, by: -1)
        where bytes.suffix(length).elementsEqual(presenceOpen.prefix(length)) {
            return length
        }
        return 0
    }
    
    /// Forward data from server to client (no modifications needed)
    func forwardToClient(_ data: ByteBuffer) -> EventLoopFuture<Void> {
        return clientChannel.eventLoop.submit {
            self.clientChannel.writeAndFlush(data)
        }.flatMap { $0 }
    }
}

/// Tells StatusManager whether Riot's chat server passed the TLS check.
private func postChatTLSStatus(ok: Bool) {
    NotificationCenter.default.post(name: Notification.Name("ChatTLSStatus"), object: nil, userInfo: ["ok": ok])
}

/// Modifies presence XML to change the status if needed
private func modifyPresenceXML(_ xml: String, targetStatus: String) -> String {
    guard targetStatus == "offline" else {
        return xml
    }

    logger.info("Modifying presence XML for target status: \(targetStatus)")
    
    var modifiedXml = xml
    
    if let lolStartRange = modifiedXml.range(of: "<league_of_legends>"),
       let lolEndRange = modifiedXml.range(of: "</league_of_legends>") {
        let fullRange = lolStartRange.lowerBound..<lolEndRange.upperBound
        modifiedXml.removeSubrange(fullRange)
    }

    if let keystoneStartRange = modifiedXml.range(of: "<keystone>"),
       let keystoneEndRange = modifiedXml.range(of: "</keystone>") {
        let fullRange = keystoneStartRange.lowerBound..<keystoneEndRange.upperBound
        modifiedXml.removeSubrange(fullRange)
    }
    
    if let riotClientStartRange = modifiedXml.range(of: "<riot_client>"),
       let riotClientEndRange = modifiedXml.range(of: "</riot_client>") {
        let fullRange = riotClientStartRange.lowerBound..<riotClientEndRange.upperBound
        modifiedXml.removeSubrange(fullRange)
    }
    
    if let showStartRange = modifiedXml.range(of: "<show>"),
       let showEndRange = modifiedXml.range(of: "</show>") {
        let showContentRange = showStartRange.upperBound..<showEndRange.lowerBound
        modifiedXml.replaceSubrange(showContentRange, with: "offline")
    }
    
    return modifiedXml
}

/// Handler for client-to-server data
final class ClientToServerHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    private let connection: ProxiedConnection
    
    init(connection: ProxiedConnection) {
        self.connection = connection
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        
        connection.processClientData(buffer).whenFailure { [weak context] error in
            logger.error("Error forwarding client data: \(error)")
            if let ctx = context {
                ctx.eventLoop.execute {
                    ctx.close(promise: nil)
                }
            }
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Client handler error: \(error)")
        
        if let sslError = error as? NIOSSLError,
           case .uncleanShutdown = sslError {
            return
        }
        
        context.eventLoop.execute {
            context.close(promise: nil)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("Client disconnected, closing server connection")
        connection.serverChannel?.close(promise: nil)
    }
}

/// Handler for server-to-client data
final class ServerToClientHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    
    private let connection: ProxiedConnection
    private var tlsStatusReported = false
    
    init(connection: ProxiedConnection) {
        self.connection = connection
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if !tlsStatusReported {
            // First data from Riot: the TLS handshake passed.
            tlsStatusReported = true
            postChatTLSStatus(ok: true)
        }
        
        connection.forwardToClient(buffer).whenFailure { [weak context] error in
            logger.error("Error forwarding server data: \(error)")
            if let ctx = context {
                ctx.eventLoop.execute {
                    ctx.close(promise: nil)
                }
            }
        }
    }
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Server handler error: \(error)")
        
        if let sslError = error as? NIOSSLError,
           case .uncleanShutdown = sslError {
            return
        }
        if let sslError = error as? NIOSSLError, case .handshakeFailed = sslError {
            postChatTLSStatus(ok: false)
        }
        
        context.eventLoop.execute {
            context.close(promise: nil)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("Server disconnected, closing client connection")
        connection.clientChannel.close(promise: nil)
    }
}
