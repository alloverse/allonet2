//
//  LoggerStore.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-10-15.
//

import Foundation
import Logging

/// A LogHandler that stores each incoming log message, so that it can be later be displayed in debug UI
public class LoggerStore: LogHandler
{
    public static var shared: LoggerStore! = nil
    public init(label: String)
    {
        self.label = label
        Self.shared = self
    }
    
    public struct StoredLog {
        let log: Logger.Message
        let level: Logger.Level
        let metadata: Logger.Metadata?
    }
    
    public var logs: [StoredLog] = []
    //public var incomingLogs: AsyncStream<StoredLog>
    
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

        let stored = StoredLog(log: message, level: level, metadata: effectiveMetadata)
        logs.append(stored)
    }

    internal static func prepareMetadata(
        base: Logger.Metadata,
        provider: Logger.MetadataProvider?,
        explicit: Logger.Metadata?
    ) -> Logger.Metadata? {
        var metadata = base

        let provided = provider?.get() ?? [:]

        guard !provided.isEmpty || !((explicit ?? [:]).isEmpty) else {
            // all per-log-statement values are empty
            return nil
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
