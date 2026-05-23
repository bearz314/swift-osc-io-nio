//
//  Network Utilities.swift
//  SwiftOSC I/O: SwiftNIO • https://github.com/orchetect/swift-osc-io-nio
//  © 2026 Steffan Andrews • Licensed under MIT License
//

internal import SwiftOSCIOInternals
import NIOCore

/// Returns network devices in the system that have an address.
func networkDevices() throws -> [(name: String, address: SocketAddress)] {
    try System
        .enumerateDevices()
        .compactMap { device -> (name: String, address: SocketAddress)? in
            guard let address = device.address else { return nil }
            return (name: device.name, address: address)
        }
}

/// Returns the all network devices that carry an IP address with a name or address that matches the given string.
func networkDevices(
    matchingNameOrAddress interface: String,
    protocols: [NIOBSDSocket.ProtocolFamily]? = nil
) throws -> [(name: String, address: SocketAddress)] {
    var devices = try networkDevices()

    if let protocols {
        devices = devices
            .filter { $0.address.ipAddress != nil }
            .filter { protocols.contains($0.address.protocol) }
    }

    return devices.filter {
        $0.name == interface || $0.address.ipAddress == interface
    }
}

/// Attempts to resolve the best available IP address for the given network device (interface).
func resolveSocketAddressString(ofNetworkDeviceNameOrAddress interface: String, isIPv6Enabled: Bool) throws -> String {
    // if the interface is an IP address, we can determine the protocol.
    // if the interface is an interface name, ie: "en0", then defer to priority order of protocols.
    let protocols: [NIOBSDSocket.ProtocolFamily] =
        if let ip = try? SocketAddress(ipAddress: interface, port: 1) { // port number doesn't matter, is unused here
            [ip.protocol]
        } else {
            [.inet, .inet6, .local]
        }

    var matchingInterfaces = try networkDevices(matchingNameOrAddress: interface, protocols: protocols)

    if !isIPv6Enabled {
        matchingInterfaces = matchingInterfaces.filter { $0.address.protocol != .inet6 }
    }

    // Prefer IPv6, then IPv4, then anything available
    let preferredInterface = matchingInterfaces.first(where: {
        $0.address.protocol == .inet6
            && !($0.address.ipAddress ?? "").lowercased().hasPrefix("fe80:") // ignore default gateway
    })
        ?? matchingInterfaces.first(where: {
            $0.address.protocol == .inet
                && !($0.address.ipAddress ?? "").lowercased().hasPrefix("169.") // ignore default gateway
        })
        ?? matchingInterfaces.first

    guard let interface = preferredInterface,
          let ipAddress = interface.address.ipAddress
    else {
        throw OSCIOError.invalidInterface
    }

    return ipAddress
}

/// Attempts to resolve the best available IP address for the given network device (interface).
func resolveSocketAddress(ofNetworkDeviceNameOrAddress interface: String, forRemoteHost remoteHost: String) throws -> SocketAddress {
    let address = try SocketAddress.makeAddressResolvingHost(remoteHost, port: 1) // port number doesn't matter, is unused here
    return try resolveSocketAddress(ofNetworkDeviceNameOrAddress: interface, forRemoteAddress: address)
}

/// Attempts to resolve the best available IP address for the given network device (interface).
func resolveSocketAddress(
    ofNetworkDeviceNameOrAddress interface: String,
    forRemoteAddress remoteAddress: SocketAddress
) throws -> SocketAddress {
    // disambiguate IPv4 from IPv6
    var matchingInterfaces = try networkDevices(matchingNameOrAddress: interface, protocols: [remoteAddress.protocol])

    matchingInterfaces = matchingInterfaces.filter {
        !($0.address.ipAddress ?? "").lowercased().hasPrefix("169.") // ignore default IPv4 gateway
            && !($0.address.ipAddress ?? "").lowercased().hasPrefix("fe80:") // ignore default IPv6 gateway
    }

    guard let matchingInterface = matchingInterfaces.first else {
        throw OSCIOError.invalidInterface
    }

    return matchingInterface.address
}

/// Attempts to resolve the best available IP address for the given network device (interface).
func resolveSocketAddressString(ofNetworkDeviceNameOrAddress interface: String, forRemoteHost remoteHost: String) throws -> String {
    guard let ipAddress = try resolveSocketAddress(ofNetworkDeviceNameOrAddress: interface, forRemoteHost: remoteHost)
        .ipAddress
    else {
        throw OSCIOError.invalidInterface
    }

    return ipAddress
}

/// Attempts to resolve the best available IP address for the given network device (interface).
func resolveSocketAddressString(
    ofNetworkDeviceNameOrAddress interface: String,
    forRemoteAddress remoteAddress: SocketAddress
) throws -> String {
    guard let ipAddress = try resolveSocketAddress(ofNetworkDeviceNameOrAddress: interface, forRemoteAddress: remoteAddress)
        .ipAddress
    else {
        throw OSCIOError.invalidInterface
    }

    return ipAddress
}

/// Attempts to resolve a hostname or IP address to an appropriate IP address.
func resolveSocketAddressPreferringIPv4(
    forHostnameOrIPAddress host: String,
    port: UInt16,
    isIPv6Enabled: Bool
) throws -> SocketAddress {
    // Note: NIO forces resolving a hostname to its IPv6 address if both IPv4 and IPv6 addresses
    // are mapped to it, but we want more control over which IP protocol we're asking for.

    // First try resolving IPv4, then if that does not return an address check for IPv6 if IPv6 is allowed
    if let string = try IPUtils.ipAddress(forHostnameOrIPAddress: host, family: .ipv4) {
        try SocketAddress(ipAddress: string, port: Int(port))
    } else if isIPv6Enabled,
              let string = try IPUtils.ipAddress(forHostnameOrIPAddress: host, family: .ipv6)
    {
        try SocketAddress(ipAddress: string, port: Int(port))
    } else {
        // Note that we have no control over which protocol NIO resolves to
        // try SocketAddress.makeAddressResolvingHost(host, port: Int(port))
        throw OSCIOError.noRemoteHost // TODO: not the most appropriate error case, could use a new one
    }
}

/// Parses `interface` parameter input and returns a suitable interface host address to bind to for the given channel (IPv4 or IPv6).
/// This method is designed to be used by OSC classes that implement dual channels for both IPv4 or IPv6.
/// If the channel is not used, `nil` is returned and is not an error condition.
func hostAddressStringForBinding(interface: String?, isIPv4: Bool) throws -> String? {
    guard let interface else {
        // Don't bind to "localhost", "127.0.0.1" (IPv4) or "::1" (IPv6)
        return isIPv4 ? "0.0.0.0" : "::"
    }
    
    // allow use of wildcard addresses
    return if interface == "0.0.0.0" || interface == "::" {
        if interface == "0.0.0.0", isIPv4 {
            "0.0.0.0"
        } else if interface == "::", !isIPv4 {
            "::"
        } else {
            // channel not used
            nil
        }
    }
    // interface supplied by the user could be IPv4 or IPv6. we only want to attempt to
    // bind to the appropriate IP protocol since this classes uses two channels (IPv4 and IPv6)
    else if let addr = try? SocketAddress(ipAddress: interface, port: 1) { // port number doesn't matter here
        // interface is an address and not a name
        if addr.protocol == (isIPv4 ? .inet : .inet6) {
            try resolveSocketAddressString(ofNetworkDeviceNameOrAddress: interface, isIPv6Enabled: !isIPv4)
        } else {
            // channel not used
            nil
        }
    }
    // interface is likely a name and not an address
    else {
        try resolveSocketAddressString(ofNetworkDeviceNameOrAddress: interface, isIPv6Enabled: !isIPv4)
    }
}
