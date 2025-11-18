// i e: anything but Linux
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)

import Foundation
import Logging
import os.log

public struct OSLogHandler: LogHandler
{
    public init(subsystem: String, category: String) {
        self.log = OSLog(subsystem: subsystem, category: category)
    }
    
    private let log: OSLog
    
    public var logLevel: Logging.Logger.Level = .info
    public var metadataProvider: Logging.Logger.MetadataProvider?
    public var metadata = Logging.Logger.Metadata()

    public subscript(metadataKey metadataKey: String) -> Logging.Logger.Metadata.Value? {
        get {
            self.metadata[metadataKey]
        }
        set {
            self.metadata[metadataKey] = newValue
        }
    }

    public func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata explicitMetadata: Logging.Logger.Metadata?,
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
        let metas = effectiveMetadata.map {"\($0): \($1)"}.joined(separator: ", ")
        let type = Self.levels[level]!
        os_log("%{public}@", log: log, type: type, "\(message)\n# from \(file)#\(line) \(function) [\(metas)]")
    }

    internal static func prepareMetadata(
        base: Logging.Logger.Metadata,
        provider: Logging.Logger.MetadataProvider?,
        explicit: Logging.Logger.Metadata?
    ) -> Logging.Logger.Metadata {
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
    
    private static var levels: [Logging.Logger.Level: OSLogType] = [
        .trace: .debug,
        .debug: .debug,
        .info: .info,
        .notice: .info,
        .warning: .info,
        .error: .error,
        .critical: .fault
    ]
}

#endif
