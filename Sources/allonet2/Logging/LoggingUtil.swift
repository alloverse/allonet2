//
//  LoggingUtil.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2025-11-18.
//

import Logging

extension Logger
{
    public func forClient(_ cid: ClientId) -> Logger
    {
        var clientLogger = self
        clientLogger[metadataKey: "clientId"] = .stringConvertible(cid)
        return clientLogger
    }
    public func forInteraction(_ inter: Interaction) -> Logger
    {
        let requestId = inter.requestId
        var interactionLogger = self
        interactionLogger[metadataKey: "requestId"] = .string(requestId)
        return interactionLogger
    }
}

extension Logger
{
    public init(labelSuffix: String, fileId: String = #fileID)
    {
        let module = fileId.split(separator: "/").first!
        self.init(label: "\(module):\(labelSuffix)")
    }
    
    public init(labelSuffix: String, fileId: String = #fileID, metadataProvider: MetadataProvider)
    {
        let module = fileId.split(separator: "/").first!
        self.init(label: "\(module):\(labelSuffix)", metadataProvider: metadataProvider)
    }
}
