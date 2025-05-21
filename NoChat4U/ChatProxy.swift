import Foundation
import NIO
import NIOSSL
import Logging

private var logger = Logger(label: "NoChat4U.ChatProxy")

extension NIOSSLServerHandler: @retroactive @unchecked Sendable {}
extension NIOSSLClientHandler: @retroactive @unchecked Sendable {}
extension ChannelHandlerContext: @retroactive @unchecked Sendable {}

class ChatProxy {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private var connections = [ObjectIdentifier: ProxiedConnection]()
    private let serverSSLContext: NIOSSLContext
 
    init() throws {
        // Generate self-signed certificate and key
        let certPath = NSTemporaryDirectory() + "cert.pem"
        let keyPath = NSTemporaryDirectory() + "key.pem"
        
        // Check if the certificate and key already exist
        if !FileManager.default.fileExists(atPath: certPath) || !FileManager.default.fileExists(atPath: keyPath) {
            // Generate the certificate and key using OpenSSL
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-keyout", keyPath, "-out", certPath, "-days", "365", "-nodes", "-subj", "/CN=NoChat4U"]
            
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                logger.error("Failed to generate certificate: OpenSSL error \(process.terminationStatus)")
                throw NIOSSLError.failedToLoadCertificate
            }
        }
        
        // Load the PEM files
        let certData = try Data(contentsOf: URL(fileURLWithPath: certPath))
        let keyData = try Data(contentsOf: URL(fileURLWithPath: keyPath))
        
        // Create server SSL context
        var serverConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: [UInt8](certData), format: .pem))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: [UInt8](keyData), format: .pem))
        )
        serverConfig.certificateVerification = .none
        serverConfig.trustRoots = .default
        serverConfig.minimumTLSVersion = .tlsv1
        serverConfig.maximumTLSVersion = .tlsv12
        serverConfig.cipherSuites = "ALL"
        serverConfig.renegotiationSupport = .always
        
        self.serverSSLContext = try NIOSSLContext(configuration: serverConfig)
        
        // Set up a notification observer for when the status changes
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
        guard let lastPresence = SharedState.shared.getLastPresence(),
              !connections.isEmpty else {
            return
        }
        
        logger.info("Status changed, sending updated presence stanza")
        
        // Use the first active connection to send the presence
        guard let connection = connections.values.first else {
            logger.warning("No active connections to send presence update")
            return
        }
        
        let targetStatus = SharedState.shared.targetStatus
        let modifiedStanza = modifyPresenceXML(lastPresence, targetStatus: targetStatus)
        
        logger.debug("Sending modified presence stanza: \(modifiedStanza)")
        
        var presenceBuffer = ByteBuffer()
        presenceBuffer.writeString(modifiedStanza)
        
        guard let serverChannel = connection.serverChannel else {
            return
        }
        
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
                
                // Create the connection object first
                let connection = ProxiedConnection(clientChannel: channel, eventLoop: channel.eventLoop)
                self.connections[ObjectIdentifier(connection)] = connection
                
                // When client disconnects, remove the connection
                channel.closeFuture.whenComplete { [weak self] _ in
                    guard let self = self else { return }
                    if let connId = self.connections.first(where: { $0.value.clientChannel === channel })?.key {
                        logger.info("Removing connection on client disconnect")
                        self.connections.removeValue(forKey: connId)
                    }
                }
                
                // First add SSL handler to client side
                let sslHandler = NIOSSLServerHandler(context: self.serverSSLContext)
                return channel.pipeline.addHandler(sslHandler).flatMap { _ in
                    // Then establish connection to server and create the proxy pipeline
                    return self.connectToServer(connection: connection).flatMap { serverChannel in
                        logger.debug("Successfully connected to server, adding client handler")
                        return channel.pipeline.addHandler(ClientToServerHandler(connection: connection))
                    }
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
        
        // Bind on localhost with a random port
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
        
        // Configure SSL/TLS for the outgoing connection if needed
        let sslContext: NIOSSLContext?
        
        var sslConfig = TLSConfiguration.makeClientConfiguration()
        sslConfig.certificateVerification = .none
        sslConfig.trustRoots = .default
        sslConfig.applicationProtocols = ["xmpp-client"]
        sslConfig.minimumTLSVersion = .tlsv1
        sslConfig.maximumTLSVersion = .tlsv13
        sslConfig.cipherSuites = "ALL"
        
        do {
            sslContext = try NIOSSLContext(configuration: sslConfig)
        } catch {
            logger.error("Failed to create SSL context: \(error)")
            return connection.clientChannel.eventLoop.makeFailedFuture(error)
        }
        
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .seconds(10))
            .channelInitializer { channel in
                logger.debug("Initializing channel to server")
                
                if let sslContext = sslContext {
                    let sslHandler = try! NIOSSLClientHandler(
                        context: sslContext,
                        serverHostname: host
                    )
                    return channel.pipeline.addHandler(sslHandler).flatMap {
                        logger.debug("SSL handler added, adding server-to-client handler")
                        return channel.pipeline.addHandler(ServerToClientHandler(connection: connection))
                    }
                } else {
                    return channel.pipeline.addHandler(ServerToClientHandler(connection: connection))
                }
            }
        
        // Connect to the original server
        return bootstrap.connect(host: host, port: port).map { serverChannel in
            logger.info("Connected to Riot chat server")
            connection.serverChannel = serverChannel
            
            // When server disconnects, close the client connection too
            serverChannel.closeFuture.whenComplete { _ in
                logger.debug("Server disconnected, closing client connection")
                connection.clientChannel.close(promise: nil)
            }
            
            return serverChannel
        }
    }
    
    func stop() {
        logger.info("Stopping chat proxy")
        for (_, connection) in connections {
            connection.clientChannel.close(promise: nil)
            connection.serverChannel?.close(promise: nil)
        }
        connections.removeAll()
        
        try? group.syncShutdownGracefully()
    }
}

enum ChatProxyError: Error {
    case missingServerInfo
}

/// A connection between a client and server
class ProxiedConnection {
    let clientChannel: Channel
    var serverChannel: Channel?
    private let eventLoop: EventLoop
    private var xmlBufferToServer = ""
    
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
        
        // Get the string data if possible
        let string = data.getString(at: data.readerIndex, length: data.readableBytes) ?? ""
            logger.debug("Client data: \(string)")
            
            // Append to our buffer
            xmlBufferToServer += string
            
            // Check for presence stanza and modify if found
            if xmlBufferToServer.contains("<presence") && xmlBufferToServer.contains("</presence>") {
                if let presenceStartRange = xmlBufferToServer.range(of: "<presence"),
                   let presenceEndRange = xmlBufferToServer.range(of: "</presence>") {
                        // Extract the presence stanza
                        let stanzaEndIndex = presenceEndRange.upperBound
                        let presenceStanza = String(xmlBufferToServer[presenceStartRange.lowerBound..<stanzaEndIndex])
                        
                        if(!presenceStanza.contains("to='")) {
                            // Store the original presence stanza
                            SharedState.shared.storeLastPresence(presenceStanza)
                        }
                        
                        // Remove from buffer
                        let beforeStanza = presenceStartRange.lowerBound > xmlBufferToServer.startIndex ? 
                            String(xmlBufferToServer[..<presenceStartRange.lowerBound]) : ""
                        let afterStanza = stanzaEndIndex < xmlBufferToServer.endIndex ? 
                            String(xmlBufferToServer[stanzaEndIndex...]) : ""
                        xmlBufferToServer = beforeStanza + afterStanza
                        
                        // Modify the presence stanza
                        let targetStatus = SharedState.shared.targetStatus
                        let modifiedStanza = modifyPresenceXML(presenceStanza, targetStatus: targetStatus)
                        
                        logger.debug("Modified presence stanza: \(modifiedStanza)")
                        
                        // Create buffer and send
                        var presenceBuffer = ByteBuffer()
                        presenceBuffer.writeString(modifiedStanza)
                        
                        return serverChannel.eventLoop.submit {
                                serverChannel.writeAndFlush(presenceBuffer)
                            }.flatMap { $0 }.flatMap {
                                // Forward remaining buffer if any
                                if !self.xmlBufferToServer.isEmpty {
                                    return self.processClientData(ByteBuffer()) 
                                } else {
                                    return self.eventLoop.makeSucceededFuture(())
                                }
                            }
                     
                }
            } 
            
            // forward remaining buffer
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
        return xml // No modification needed for "chat" status
    }

    logger.info("Modifying presence XML for target status: \(targetStatus)")
    
    var modifiedXml = xml
    
    // Remove the league_of_legends element if present
    if let lolStartRange = modifiedXml.range(of: "<league_of_legends>"),
       let lolEndRange = modifiedXml.range(of: "</league_of_legends>") {
        let fullRange = lolStartRange.lowerBound..<lolEndRange.upperBound
        modifiedXml.removeSubrange(fullRange)
    }
    
    // Replace the show tag content with "offline"
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
        
        // Forward client data to server (with possible modification)
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
        
        // For SSL/TLS shutdown, don't treat as a fatal error
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
        
        // Forward server data to client (no modification needed)
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
        
        // For SSL/TLS shutdown, don't treat as a fatal error
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