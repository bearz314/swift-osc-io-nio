//
//  OSCUDPClient Core.swift
//  SwiftOSC I/O: SwiftNIO • https://github.com/orchetect/swift-osc-io-nio
//  © 2026 Steffan Andrews • Licensed under MIT License
//

internal import SwiftOSCIOInternals
import Foundation
import NIO
import SwiftOSCCore

extension OSCUDPClient {
    /// Internal operations class so as to not expose I/O implementation details as public.
    final class Core {
        typealias Parent = OSCUDPClient

        /// Internal queue used for synchronizing access to mutable properties.
        let syncQueue = DispatchQueue(label: "com.orchetect.SwiftOSC.OSCUDPClient.Core.syncQueue", target: .global())

        let queue: DispatchQueue

        // anywhere that we are assigning this variable, it is wrapped in sync calls to `queue`
        // so we don't need to wrap it with `syncQueue` to synchronize
        nonisolated(unsafe) private var ipv4Channel: (any Channel)?

        // anywhere that we are assigning this variable, it is wrapped in sync calls to `queue`
        // so we don't need to wrap it with `syncQueue` to synchronize
        nonisolated(unsafe) private var ipv6Channel: (any Channel)?

        var localHost: String? {
            isStarted
                ? (ipv4Channel?.localAddress?.ipAddress ?? ipv6Channel?.localAddress?.ipAddress)
                : nil
        }
        
        var localPort: UInt16 {
            if let port = ipv4Channel?.localAddress?.port ?? ipv6Channel?.localAddress?.port {
                UInt16(port)
            } else {
                preferredLocalPort ?? 0
            }
        }

        private var preferredLocalPort: UInt16? {
            get { syncQueue.sync { _preferredLocalPort } }
            set { syncQueue.sync { _preferredLocalPort = newValue } }
        }

        nonisolated(unsafe) private var _preferredLocalPort: UInt16?

        let interface: String?

        var isPortReuseEnabled: Bool {
            get { syncQueue.sync { _isPortReuseEnabled } }
            set { syncQueue.sync { _isPortReuseEnabled = newValue } }
        }

        nonisolated(unsafe) private var _isPortReuseEnabled: Bool

        var isIPv4BroadcastEnabled: Bool {
            get {
                syncQueue.sync { _isIPv4BroadcastEnabled }
            }
            set {
                syncQueue.sync { _isIPv4BroadcastEnabled = newValue }
                let broadcast: ChannelOptions.Types.SocketOption.Value = newValue ? 1 : 0

                ipv4Channel?
                    .setOption(.socketOption(.so_broadcast), value: broadcast)
                    .whenComplete { error in }
            }
        }

        nonisolated(unsafe) private var _isIPv4BroadcastEnabled: Bool = false

        var isIPv6Enabled: Bool {
            get {
                syncQueue.sync { _isIPv6Enabled }
            }
            set {
                syncQueue.sync { _isIPv6Enabled = newValue }
                if isStarted {
                    print("Setting isIPv6Enabled will not have any effect until the UDP client is stopped and started again.")
                }
            }
        }

        nonisolated(unsafe) private var _isIPv6Enabled: Bool

        var isStarted: Bool {
            if isIPv6Enabled {
                isIPv4Started && isIPv6Started
            } else {
                isIPv4Started
            }
        }

        private var isIPv4Started: Bool {
            ipv4Channel?.isActive ?? false
        }

        private var isIPv6Started: Bool {
            ipv6Channel?.isActive ?? false
        }

        init(
            localPort: UInt16?,
            interface: String?,
            isPortReuseEnabled: Bool,
            isIPv4BroadcastEnabled: Bool,
            isIPv6Enabled: Bool,
            queue: DispatchQueue?
        ) {
            self.queue = queue ?? DispatchQueue(
                label: "com.orchetect.SwiftOSC.OSCUDPClient.queue",
                target: .global() // do NOT use syncQueue
            )
            _preferredLocalPort = (localPort == nil || localPort == 0) ? nil : localPort
            self.interface = interface
            _isPortReuseEnabled = isPortReuseEnabled
            _isIPv6Enabled = isIPv6Enabled
            _isIPv4BroadcastEnabled = isIPv4BroadcastEnabled
        }

        deinit {
            stop()
        }
    }
}

extension OSCUDPClient.Core: Sendable { }

// MARK: - Lifecycle

extension OSCUDPClient.Core {
    func start() throws {
        try queue.sync {
            try _start()
        }
    }

    func _start() throws {
        try _startIPv4()
        if isIPv6Enabled { try _startIPv6() }
    }

    private func _startIPv4() throws {
        guard !isIPv4Started else { return }
        if let channel = try _start(isIPv4: true) { ipv4Channel = channel }
    }

    private func _startIPv6() throws {
        guard !isIPv6Started else { return }
        if let channel = try _start(isIPv4: false) { ipv6Channel = channel }
    }

    private func _start(isIPv4: Bool) throws -> (any Channel)? {
        if isIPv4 { _stopIPv4() } else { _stopIPv6() }

        // bind to interface, if specified
        // `nil` return value is not an error condition; just means this channel is not used
        guard let host = try hostAddressStringForBinding(interface: interface, isIPv4: isIPv4) else { return nil }

        let port = Int(preferredLocalPort ?? 0)

        // Channel Setup
        let reuseAddress: ChannelOptions.Types.SocketOption.Value = isPortReuseEnabled ? 1 : 0
        let broadcast: ChannelOptions.Types.SocketOption.Value = _isIPv4BroadcastEnabled ? 1 : 0
        let bootstrap = DatagramBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            // configure port reuse
            .channelOption(.socketOption(.so_reuseaddr), value: reuseAddress)
            // configure ipv4 broadcast
            .channelOption(.socketOption(.so_broadcast), value: broadcast)

        let configuredChannel = bootstrap
            // bind to host and port
            .bind(host: host, port: port)

        return try configuredChannel
            .wait()
    }

    func stop() {
        queue.sync {
            _stopIPv4()
            _stopIPv6()
        }
    }

    private func _stopIPv4() {
        try? ipv4Channel?.close().wait()
        ipv4Channel = nil
    }

    private func _stopIPv6() {
        try? ipv6Channel?.close().wait()
        ipv6Channel = nil
    }
}

// MARK: - Communication

extension OSCUDPClient.Core {
    func send(_ packet: OSCPacket, to host: String, port: UInt16) throws {
        try queue.sync {
            if !isStarted {
                try _start()
            }

            // resolve host and port to `SocketAddress`
            let remoteAddress = try resolveSocketAddressPreferringIPv4(
                forHostnameOrIPAddress: host,
                port: port,
                isIPv6Enabled: isIPv6Enabled
            )

            // use corresponding channel for IP protocol
            let channel = switch remoteAddress.protocol {
            case .inet: ipv4Channel
            case .inet6: ipv6Channel
            default: throw OSCIOError.noRemoteHost
            }

            guard let channel else {
                throw OSCIOError.notStarted
            }

            // create buffer from data
            let data = try packet.rawData()
            let buffer: ByteBuffer = channel.allocator.buffer(bytes: data)

            let envelope = AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)
            try channel.writeAndFlush(envelope)
                .wait()
        }
    }
}
