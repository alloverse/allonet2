//
//  ConnectionStatus.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-05-05.
//
import Foundation
import Combine

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
    case disconnected
    case connecting
    case connected
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
    @Published public var signalling: ConnectionState = .disconnected
    @Published public var iceGathering: ConnectionState = .disconnected
    @Published public var iceConnection: ConnectionState = .disconnected
    @Published public var data: ConnectionState = .disconnected
    
    var debugDescription: String {
        "state: \(reconnection), error: \(String(describing: self.lastError)), willReconnectAt: \(String(describing: self.willReconnectAt))"
    }
    public init() {} 
}
