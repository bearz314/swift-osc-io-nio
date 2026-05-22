//
//  OSCTCPServer Core.swift
//  SwiftOSC I/O: SwiftNIO • https://github.com/orchetect/swift-osc-io-nio
//  © 2026 Steffan Andrews • Licensed under MIT License
//

internal import SwiftOSCIOInternals
import Foundation
import NIO
import SwiftOSCCore

extension OSCTCPServer {
    /// Internal operations class so as to not expose I/O implementation details as public.
    final class Core {
        typealias Parent = OSCTCPServer

        /// Internal queue used for synchronizing access to mutable properties.
        let syncQueue = DispatchQueue(label: "com.orchetect.SwiftOSC.OSCTCPServer.Core.syncQueue", target: .global())

        // anywhere that we are assigning this variable, it is wrapped in sync calls to `queue`
        // so we don't need to wrap it with `syncQueue` to synchronize
        nonisolated(unsafe) var channel: (any Channel)?

        /// Currently connected client sessions.
        private var _clients: [OSCTCPClientSessionID: ClientConnection] {
            get {
                syncQueue.sync { __clients }
            }
            _modify {
                var value = syncQueue.sync { __clients }
                yield &value
                syncQueue.sync { __clients = value }
            }
            set {
                syncQueue.sync { __clients = newValue }
            }
        }

        nonisolated(unsafe) private var __clients: [OSCTCPClientSessionID: ClientConnection] = [:]

        let queue: DispatchQueue

        var receiveHandler: OSCPacketHandler? {
            get { syncQueue.sync { _receiveHandler } }
            set { syncQueue.sync { _receiveHandler = newValue } }
        }

        nonisolated(unsafe) private var _receiveHandler: OSCPacketHandler?

        var receiveErrorHandler: OSCDecodeErrorHandlerBlock? {
            get { syncQueue.sync { _receiveErrorHandler } }
            set { syncQueue.sync { _receiveErrorHandler = newValue } }
        }

        nonisolated(unsafe) private var _receiveErrorHandler: OSCDecodeErrorHandlerBlock?

        var notificationHandler: Parent.NotificationHandlerBlock? {
            get { syncQueue.sync { _notificationHandler } }
            set { syncQueue.sync { _notificationHandler = newValue } }
        }

        nonisolated(unsafe) private var _notificationHandler: Parent.NotificationHandlerBlock?

        var localHost: String? {
            isStarted ? channel?.localAddress?.ipAddress : nil
        }

        var localPort: UInt16 {
            UInt16(channel?.localAddress?.port ?? 0)
        }

        private var preferredLocalPort: UInt16? {
            get { syncQueue.sync { _preferredLocalPort } }
            set { syncQueue.sync { _preferredLocalPort = newValue } }
        }

        nonisolated(unsafe) private var _preferredLocalPort: UInt16?

        let interface: String?

        var isIPv6Enabled: Bool {
            get {
                syncQueue.sync { _isIPv6Enabled }
            }
            set {
                syncQueue.sync { _isIPv6Enabled = newValue }
                if isStarted {
                    print("Setting isIPv6Enabled will not have any effect until the TCP server is stopped and restarted again.")
                }
            }
        }

        nonisolated(unsafe) private var _isIPv6Enabled: Bool

        var isStarted: Bool {
            channel?.isActive ?? false
        }

        let framingMode: OSCTCPFramingMode

        init(
            port: UInt16?,
            interface: String?,
            isIPv6Enabled: Bool,
            framingMode: OSCTCPFramingMode,
            queue: DispatchQueue?,
            receiveHandler: OSCPacketHandler?
        ) {
            _preferredLocalPort = (port == nil || port == 0) ? nil : port
            self.interface = interface
            _isIPv6Enabled = isIPv6Enabled
            self.framingMode = framingMode
            let queue = queue ?? DispatchQueue(
                label: "com.orchetect.SwiftOSC.OSCTCPServer.queue",
                target: .global() // do NOT use syncQueue
            )
            self.queue = queue
            _receiveHandler = receiveHandler
        }

        deinit {
            stop()
        }
    }
}

extension OSCTCPServer.Core: Sendable { }

// MARK: - Lifecycle

extension OSCTCPServer.Core {
    func start() throws {
        try queue.sync {
            guard !isStarted else { return }

            let bootstrap = ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        switch self.framingMode {
                        case .osc1_0:
                            try channel.pipeline
                                .syncOperations
                                .addHandler(ByteToMessageHandler(OSCTCPLengthHeaderFrameDecoder()))
                        case .osc1_1:
                            try channel.pipeline
                                .syncOperations
                                .addHandler(ByteToMessageHandler(OSCTCPSLIPFrameDecoder()))
                        }
                        try channel.pipeline
                            .syncOperations
                            .addHandler(ChildChannelHandler(server: self))
                    }
                }

            // bind to interface, if specified
            let host: String = if let interface {
                switch interface {
                case "0.0.0.0",
                     "::" where isIPv6Enabled:
                    // pass thru wildcard
                    interface
                default:
                    try resolveSocketAddressString(ofNetworkDeviceNameOrAddress: interface, isIPv6Enabled: isIPv6Enabled)
                }
            } else {
                // Don't bind to "localhost", "127.0.0.1" (IPv4) or "::1" (IPv6)
                isIPv6Enabled ? "::" : "0.0.0.0"
            }

            let port = Int(preferredLocalPort ?? localPort)

            let configuredChannel = bootstrap
                .bind(host: host, port: port)

            channel = try configuredChannel
                .wait()
        }
    }

    func stop() {
        // disconnect all clients
        closeClients()

        queue.sync {
            // close server
            channel?.close(promise: nil)
            channel = nil
        }
    }
}

// MARK: - Communication

extension OSCTCPServer.Core {
    func send(
        _ packet: OSCPacket,
        toClientIDs clientIDs: [OSCTCPClientSessionID]?,
        errorHandler: ((_ clientID: OSCTCPClientSessionID, _ error: any Error) -> Void)?
    ) {
        let clientIDs = clientIDs ?? queue.sync { Array(_clients.keys) }
        for clientID in clientIDs {
            do {
                try send(packet, toClientID: clientID)
            } catch {
                errorHandler?(clientID, error)
            }
        }
    }

    func send(_ oscPacket: OSCPacket, toClientID clientID: OSCTCPClientSessionID) throws {
        guard let connection = _clients[clientID] else {
            throw OSCIOError.clientNotFound(clientID: clientID)
        }

        try connection.send(oscPacket)
    }
}

extension OSCTCPServer.Core: _OSCTCPPacketDispatcherProtocol {
    // provides implementation for dispatching incoming OSC data
}

extension OSCTCPServer.Core: OSCTCPGeneratesServerNotificationsProtocol {
    func generateConnectedNotification(remoteHost: String, remotePort: UInt16, clientID: OSCTCPClientSessionID) {
        let notif: Parent.Notification = .connected(remoteHost: remoteHost, remotePort: remotePort, clientID: clientID)
        notificationHandler?(notif)
    }

    func generateDisconnectedNotification(
        remoteHost: String,
        remotePort: UInt16,
        clientID: OSCTCPClientSessionID,
        error: (any Error)?
    ) {
        let notif: Parent.Notification = .disconnected(remoteHost: remoteHost, remotePort: remotePort, clientID: clientID, error: error)
        notificationHandler?(notif)
    }
}

// MARK: - Properties

extension OSCTCPServer.Core {
    func setReceiveHandler(_ handler: OSCPacketHandler?) {
        receiveHandler = handler
    }

    func setReceiveErrorHandler(_ handler: OSCDecodeErrorHandlerBlock?) {
        receiveErrorHandler = handler
    }

    func setNotificationHandler(_ handler: Parent.NotificationHandlerBlock?) {
        notificationHandler = handler
    }

    var clients: [OSCTCPClientSessionID: (host: String, port: UInt16)] {
        _clients
            .reduce(into: [:] as [OSCTCPClientSessionID: (host: String, port: UInt16)]) { base, element in
                base[element.key] = (
                    host: element.value.remoteHost,
                    port: element.value.remotePort
                )
            }
    }

    func disconnectClient(clientID: OSCTCPClientSessionID) {
        closeClient(clientID: clientID)
    }
}

// MARK: - Clients

extension OSCTCPServer.Core {
    /// Close connections for any connected clients and remove them from the list of connected clients.
    func closeClients() {
        let clientIDs = _clients.keys // take local copy before mutating collection
        for clientID in clientIDs {
            closeClient(clientID: clientID)
        }
    }

    func addClient(channel: any Channel) -> OSCTCPClientSessionID {
        let clientID = newClientID()
        let connection = ClientConnection(
            server: self,
            channel: channel,
            clientID: clientID,
            framingMode: framingMode
        )
        _clients[clientID] = connection

        return clientID
    }

    /// Generate a new client ID that is not currently in use by any connected client(s).
    private func newClientID() -> OSCTCPClientSessionID {
        queue.sync {
            var clientID = 0
            while clientID == 0 || _clients.keys.contains(clientID) {
                // don't allow 0 or negative numbers
                clientID = Int.random(in: 1 ... Int.max)
            }

            assert(clientID > 0)
            return clientID
        }
    }

    /// Close a connection and remove it from the list of connected clients.
    func closeClient(clientID: Int) {
        queue.sync {
            _clients[clientID]?.close()
            _clients[clientID] = nil
        }
    }
}
