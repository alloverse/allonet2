//
//  ConnectionStatus.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-05-05.
//
import Foundation
import OpenCombineShim

/// Overall status of the client, including whether it is trying to reconnect
public enum ReconnectionState : Equatable
{
    case idle
    case waitingForReconnect
    
    case connecting
    case connected
}

/// Status of a single subsystem
public enum ConnectionState
{
    case idle
    case connecting
    case connected
    case failed
}

/// Observable status of both the client itself and all its subsystems
@MainActor
public class ConnectionStatus: ObservableObject
{
    @Published public var reconnection: ReconnectionState = .idle
    // What was the last connection error?
    // If state is now .idle, it was a permanent error and we're wholly disconnected.
    // If state is now .waitingToReconnect, it was a temporary error and we're about to reconnect.
    @Published public var lastError: Error?
    @Published public var willReconnectAt: Date?
    
    // Subsystem statuses:
    @Published public var signalling: ConnectionState = .idle
    @Published public var iceGathering: ConnectionState = .idle
    @Published public var iceConnection: ConnectionState = .idle
    @Published public var data: ConnectionState = .idle
    
    var debugDescription: String {
        "state: \(reconnection), error: \(String(describing: self.lastError)), willReconnectAt: \(String(describing: self.willReconnectAt))"
    }
    public init(reconnection: ReconnectionState = .idle, lastError: Error? = nil, willReconnectAt: Date? = nil, signalling: ConnectionState = .idle, iceGathering: ConnectionState = .idle, iceConnection: ConnectionState = .idle, data: ConnectionState = .idle)
    {
        self.reconnection = reconnection
        self.lastError = lastError
        self.willReconnectAt = willReconnectAt
        self.signalling = signalling
        self.iceGathering = iceGathering
        self.iceConnection = iceConnection
        self.data = data
    }
}
