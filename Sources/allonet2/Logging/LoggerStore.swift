//
//  LoggerStore.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-10-15.
//

import Foundation
import Logging

public struct StoredLogMessage: Codable
{
    let label: String
    let timestamp: TimeInterval
    
    let level: Logger.Level
    let message: Logger.Message
    let metadata: [String: Logger.MetadataValue]?
    let source: String
    let file: String
    let function: String
    let line: UInt
}


/// A LogHandler that stores each incoming log message, so that it can be later be displayed in debug UI
public class StoringLogHandler: LogHandler
{
    public init(label: String)
    {
        self.label = label
    }
    
    private let label: String
    public var logLevel: Logger.Level = .info
    public var metadataProvider: Logger.MetadataProvider?
    public var metadata = Logger.Metadata()

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get {
            self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    public func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata explicitMetadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let effectiveMetadata = Self.prepareMetadata(
            base: self.metadata,
            provider: self.metadataProvider,
            explicit: explicitMetadata
        )

        let storedMessage = StoredLogMessage(
            label: label,
            timestamp: Date.now.timeIntervalSince1970,
            
            level: level,
            message: message,
            metadata: effectiveMetadata,
            source: source,
            file: file,
            function: function,
            line: line
        )
        Task { await LogStore.shared.store(storedMessage) }
    }

    internal static func prepareMetadata(
        base: Logger.Metadata,
        provider: Logger.MetadataProvider?,
        explicit: Logger.Metadata?
    ) -> Logger.Metadata? {
        var metadata = base

        let provided = provider?.get() ?? [:]

        guard !provided.isEmpty || !((explicit ?? [:]).isEmpty) else {
            return metadata
        }

        if !provided.isEmpty {
            metadata.merge(provided, uniquingKeysWith: { _, provided in provided })
        }

        if let explicit = explicit, !explicit.isEmpty {
            metadata.merge(explicit, uniquingKeysWith: { _, explicit in explicit })
        }

        return metadata
    }
}

// The global repository of stored logs
public actor LogStore
{
    public private(set) static var shared = LogStore()
    public var capacity: Int = 5000
    public func setCapacity(_ newValue: Int) {
        self.capacity = newValue
    }

    // MARK: Storage + streaming
    private var logs: [StoredLogMessage] = []
    private var continuations: [UUID: AsyncStream<StoredLogMessage>.Continuation] = [:]
    private func removeContinuation(for key: UUID) { self.continuations.removeValue(forKey: key) }

    /// All logs so far (snapshot copy).
    public func allLogs() -> [StoredLogMessage] { logs }

    /// A replay-then-live stream. New subscribers get all current logs, then future ones until they cancel.
    public func stream() -> AsyncStream<StoredLogMessage>
    {
        AsyncStream { continuation in
            for log in logs {
                continuation.yield(log)
            }

            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                // Remove the continuation when the consumer cancels or finishes
                Task { await self?.removeContinuation(for:id) }
            }
        }
    }
    
    public func store(_ log: StoredLogMessage)
    {
        if logs.count > capacity { logs.removeFirst(capacity/10) }
        
        logs.append(log)
        
        // Fan-out to all active listeners
        for c in continuations.values
        {
            c.yield(log)
        }
    }

    /// Clear stored history (does not affect active streams except that future replays will be empty).
    public func clear() { logs.removeAll(keepingCapacity: false) }
    
    deinit {
        // Finish any dangling continuations to unblock consumers
        for c in continuations.values { c.finish() }
        continuations.removeAll()
    }
}


// Please excuse the slop Codable implementation below

extension Logger.Message: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(describing: self))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        self = Logger.Message(stringLiteral: string)
    }
}

extension Logger.Level: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Logger.Level(rawValue: raw) ?? .info
    }
}

extension Logger.MetadataValue: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .stringConvertible(let sc):
            try container.encode(String(describing: sc))
        case .array(let values):
            try container.encode(values)
        case .dictionary(let dict):
            try container.encode(dict)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // TODO
        self = .string(try container.decode(String.self))
    }
}
