import Foundation
import NIO
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
        guard let lastPresence = SharedState.shared.getLastPresence() else { return }
        
        let connection: ProxiedConnection? = connectionsLock.withLock {
            connections.values.first
        }
        
        guard let conn = connection, let serverChannel = conn.serverChannel else { return }
        
        let targetStatus = SharedState.shared.targetStatus
        let modifiedStanza = modifyPresenceXML(lastPresence, targetStatus: targetStatus)
        
        logger.debug("Sending modified presence stanza: \(modifiedStanza)")
        
        var presenceBuffer = ByteBuffer()
        presenceBuffer.writeString(modifiedStanza)
        
        serverChannel.eventLoop.execute {
            serverChannel.writeAndFlush(presenceBuffer, promise: nil)
        }
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
                
                let sslHandler = NIOSSLServerHandler(context: self.serverSSLContext)
                return channel.pipeline.addHandler(sslHandler).flatMap { _ in
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
        
        let sslContext: NIOSSLContext?
        
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
        
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(10))
            .channelInitializer { channel in
                logger.debug("Initializing channel to server")
                
                if let sslContext = sslContext {
                    do {
                        let sslHandler = try NIOSSLClientHandler(
                            context: sslContext,
                            serverHostname: host
                        )
                        return channel.pipeline.addHandler(sslHandler).flatMap {
                            logger.debug("SSL handler added, adding server-to-client handler")
                            return channel.pipeline.addHandler(ServerToClientHandler(connection: connection))
                        }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                } else {
                    return channel.pipeline.addHandler(ServerToClientHandler(connection: connection))
                }
            }
        
        return bootstrap.connect(host: host, port: port).map { serverChannel in
            logger.info("Connected to Riot chat server")
            connection.serverChannel = serverChannel
            
            serverChannel.closeFuture.whenComplete { _ in
                logger.debug("Server disconnected, closing client connection")
                connection.clientChannel.close(promise: nil)
            }
            
            return serverChannel
        }
    }
    
    func stop() {
        logger.info("Stopping chat proxy")
        connectionsLock.withLock {
            for (_, connection) in connections {
                connection.clientChannel.close(promise: nil)
                connection.serverChannel?.close(promise: nil)
            }
            connections.removeAll()
        }
    }
}

enum ChatProxyError: Error {
    case missingServerInfo
}

/// A connection between a client and server
final class ProxiedConnection {
    let clientChannel: Channel
    private let eventLoop: EventLoop
    private var xmlBufferToServer = ""
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
    
    /// Forward data from client to server with presence XML modification if needed
    func processClientData(_ data: ByteBuffer) -> EventLoopFuture<Void> {
        guard let serverChannel = serverChannel else {
            return eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel)
        }
        
        if !eventLoop.inEventLoop {
            return eventLoop.submit {
                self.processClientData(data)
            }.flatMap { $0 }
        }
        
        let string = data.getString(at: data.readerIndex, length: data.readableBytes) ?? ""
        logger.debug("Client data: \(string)")
        
        xmlBufferToServer += string
        
        if xmlBufferToServer.contains("<presence") && xmlBufferToServer.contains("</presence>") {
            if let presenceStartRange = xmlBufferToServer.range(of: "<presence"),
               let presenceEndRange = xmlBufferToServer.range(of: "</presence>") {
                let stanzaEndIndex = presenceEndRange.upperBound
                let presenceStanza = String(xmlBufferToServer[presenceStartRange.lowerBound..<stanzaEndIndex])
                
                if !presenceStanza.contains("to='") {
                    SharedState.shared.storeLastPresence(presenceStanza)
                }
                
                let beforeStanza = presenceStartRange.lowerBound > xmlBufferToServer.startIndex ?
                    String(xmlBufferToServer[..<presenceStartRange.lowerBound]) : ""
                let afterStanza = stanzaEndIndex < xmlBufferToServer.endIndex ?
                    String(xmlBufferToServer[stanzaEndIndex...]) : ""
                xmlBufferToServer = beforeStanza + afterStanza
                
                let targetStatus = SharedState.shared.targetStatus
                let modifiedStanza = modifyPresenceXML(presenceStanza, targetStatus: targetStatus)
                
                logger.debug("Modified presence stanza: \(modifiedStanza)")
                
                var presenceBuffer = ByteBuffer()
                presenceBuffer.writeString(modifiedStanza)
                
                return serverChannel.eventLoop.submit {
                    serverChannel.writeAndFlush(presenceBuffer)
                }.flatMap { $0 }.flatMap {
                    if !self.xmlBufferToServer.isEmpty {
                        return self.processClientData(ByteBuffer())
                    } else {
                        return self.eventLoop.makeSucceededFuture(())
                    }
                }
            }
        }
        
        var buffer = ByteBuffer()
        buffer.writeString(xmlBufferToServer)
        xmlBufferToServer = ""
        
        return serverChannel.eventLoop.submit {
            serverChannel.writeAndFlush(buffer)
        }.flatMap { $0 }
    }
    
    /// Forward data from server to client (no modifications needed)
    func forwardToClient(_ data: ByteBuffer) -> EventLoopFuture<Void> {
        return clientChannel.eventLoop.submit {
            self.clientChannel.writeAndFlush(data)
        }.flatMap { $0 }
    }
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
    
    init(connection: ProxiedConnection) {
        self.connection = connection
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        
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
        
        context.eventLoop.execute {
            context.close(promise: nil)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        logger.debug("Server disconnected, closing client connection")
        connection.clientChannel.close(promise: nil)
    }
}
