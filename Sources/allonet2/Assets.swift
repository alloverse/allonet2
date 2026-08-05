//
//  Assets.swift
//  allonet2
//
//  Created by Nevyn Bengtsson on 2026-08-05.
//

import Foundation
import Crypto

/// Content address of an asset: `sha256:` followed by 64 lowercase hex digits. The id is derived
/// from the bytes, so holding one is also the means of verifying whatever you were handed for it.
public struct AssetID: Hashable, Sendable, CustomStringConvertible
{
    static let prefix = "sha256:"
    private static let hexDigits = Set("0123456789abcdef")

    public let description: String

    /// Parse an id off the wire or out of a component. Nil for anything that isn't our shape;
    /// callers are at a trust boundary and must decide what a bad id means to them.
    public init?(_ string: String)
    {
        guard string.hasPrefix(Self.prefix) else { return nil }
        let hex = string.dropFirst(Self.prefix.count)
        guard hex.count == 64, hex.allSatisfy(Self.hexDigits.contains) else { return nil }
        description = string
    }

    public init(hashing data: Data)
    {
        self.init(digest: SHA256.hash(data: data))
    }

    init(digest: some Sequence<UInt8>)
    {
        description = Self.prefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Address a file without reading it into memory, so publishing a large mesh costs one chunk.
    public init(hashingContentsOf fileURL: URL) throws
    {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty
        {
            hasher.update(data: chunk)
        }
        self.init(digest: hasher.finalize())
    }

    /// Base name for this asset on disk. Never carries the `sha256:` prefix, which is not a legal
    /// filename character everywhere we run.
    var hex: String { String(description.dropFirst(Self.prefix.count)) }
}

extension AssetID: Codable
{
    public init(from decoder: any Decoder) throws
    {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let id = AssetID(string) else { throw AssetError.malformedID(string) }
        self = id
    }

    public func encode(to encoder: any Encoder) throws
    {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public enum AssetError: Error, CustomStringConvertible, Equatable
{
    case malformedID(String)
    case notFound(AssetID)
    /// Publishing needs the token from the announce response, so it needs a live session.
    case notAllowedToPublish
    case tooLarge(bytes: Int, max: Int)
    /// The bytes we got don't hash to the id we asked for: the place is buggy or lying.
    case hashMismatch(expected: AssetID, actual: AssetID)
    case transferFailed(id: AssetID?, status: Int, body: String)
    /// A type sidecar with no bytes beside it, or vice versa.
    case damagedStore(id: AssetID, path: String)
    case cannotWrite(path: String)

    public var description: String
    {
        switch self
        {
        case .malformedID(let string): return "Not an asset id: '\(string)'"
        case .notFound(let id): return "The place has no asset \(id)"
        case .notAllowedToPublish: return "Not allowed to publish assets; the place issues that right when you announce"
        case .tooLarge(let bytes, let max): return "Asset is \(bytes) bytes, which is over the \(max) byte limit"
        case .hashMismatch(let expected, let actual): return "Asked for \(expected) but the bytes hash to \(actual)"
        case .transferFailed(let id, let status, let body): return "Transfer of \(id?.description ?? "asset") failed with HTTP \(status): \(body)"
        case .damagedStore(let id, let path): return "Asset store is damaged around \(id) at \(path)"
        case .cannotWrite(let path): return "Could not write to \(path)"
        }
    }
}

/// A content-addressed store of asset bytes on disk. The place keeps one as the origin every agent
/// fetches from; each client keeps one as its cache. Identical layout on both sides: the bytes at
/// `<hex>.<ext>` and the media type that chose that extension at `<hex>.type`, so a stored file can
/// be handed straight to a loader that dispatches on the extension (RealityKit has no data-based
/// USDZ loader). The extension is a convenience; the id remains derived from content alone.
public actor AssetStore
{
    public nonisolated let directory: URL

    public init(directory: URL)
    {
        self.directory = directory
    }

    /// Where a client caches what it fetched. Deliberately not `.cachesDirectory` on Linux: there
    /// Foundation reads /etc/default/useradd rather than $HOME and lands on `/home/.cache`, which in
    /// the AlloPlace container is neither the process's home nor a mounted volume. The place is told
    /// its directory explicitly instead of guessing.
    public static var defaultCacheDirectory: URL
    {
#if canImport(Darwin)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
#else
        let base = FileManager.default.temporaryDirectory
#endif
        return base.appendingPathComponent("com.alloverse.assets", isDirectory: true)
    }

    public struct Entry: Sendable, Equatable
    {
        public let id: AssetID
        /// Where the bytes are. Safe to hand to a file-based loader.
        public let url: URL
        public let contentType: String
        public let size: Int
    }

    /// What we hold for `id`, or nil if we don't hold it. Absence is a value; a throw means the
    /// store itself is damaged.
    public func entry(for id: AssetID) throws -> Entry?
    {
        let sidecar = typeURL(for: id)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return nil }

        let contentType = try String(contentsOf: sidecar, encoding: .utf8)
        let url = blobURL(for: id, contentType: contentType)
        // The sidecar is written last, so its presence promises the bytes. If it doesn't, we're damaged.
        guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else
        {
            throw AssetError.damagedStore(id: id, path: url.path)
        }
        return Entry(id: id, url: url, contentType: contentType, size: size)
    }

    public func contains(_ id: AssetID) throws -> Bool
    {
        try entry(for: id) != nil
    }

    /// The bytes we hold for `id`, or nil if we don't hold them.
    public func data(for id: AssetID) throws -> Data?
    {
        guard let entry = try entry(for: id) else { return nil }
        return try Data(contentsOf: entry.url)
    }

    /// Address a file we are not storing. Lives on the actor so callers on the main actor - every
    /// `AlloClient` - don't hash a mesh on the thread that draws.
    public func address(ofFileAt fileURL: URL) throws -> AssetID
    {
        try AssetID(hashingContentsOf: fileURL)
    }

    /// Store `data` under its own content address. Identical bytes are a no-op.
    @discardableResult
    public func store(_ data: Data, contentType: String) throws -> AssetID
    {
        let id = AssetID(hashing: data)
        guard try entry(for: id) == nil else { return id }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: blobURL(for: id, contentType: contentType), options: .atomic)
        try finish(id: id, contentType: contentType)
        return id
    }

    /// Consume `body` straight to disk, hashing as it arrives, and store it under the address of
    /// what actually turned up — the sender never gets to name it. Throws `tooLarge` the moment the
    /// stream exceeds `maxBytes`, so an oversized upload costs one chunk of memory, not all of it.
    @discardableResult
    public func store<Body: AsyncSequence & Sendable>(streaming body: Body, contentType: String, maxBytes: Int) async throws -> AssetID
        where Body.Element == Data
    {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let incoming = directory.appendingPathComponent("incoming-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: incoming.path, contents: nil) else
        {
            throw AssetError.cannotWrite(path: incoming.path)
        }

        let handle = try FileHandle(forWritingTo: incoming)
        var hasher = SHA256()
        var received = 0
        do
        {
            for try await chunk in body
            {
                received += chunk.count
                guard received <= maxBytes else { throw AssetError.tooLarge(bytes: received, max: maxBytes) }
                hasher.update(data: chunk)
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
        }
        catch
        {
            // Unwinding: the original failure is what the caller needs, not whatever cleanup says.
            try? handle.close()
            try? FileManager.default.removeItem(at: incoming)
            throw error
        }

        let id = AssetID(digest: hasher.finalize())
        guard try entry(for: id) == nil else
        {
            try FileManager.default.removeItem(at: incoming)
            return id
        }

        let blob = blobURL(for: id, contentType: contentType)
        // A crash between the blob and its sidecar leaves orphaned bytes; replace rather than fail.
        if FileManager.default.fileExists(atPath: blob.path)
        {
            try FileManager.default.removeItem(at: blob)
        }
        try FileManager.default.moveItem(at: incoming, to: blob)
        try finish(id: id, contentType: contentType)
        return id
    }

    /// Take over an already-downloaded file, but only if it is what was asked for. This is the
    /// consumer half of content addressing: the id can verify the bytes, and here is where it does.
    @discardableResult
    public func adopt(fileAt temporary: URL, expecting id: AssetID, contentType: String) throws -> Entry
    {
        let actual = try AssetID(hashingContentsOf: temporary)
        guard actual == id else
        {
            try FileManager.default.removeItem(at: temporary)
            throw AssetError.hashMismatch(expected: id, actual: actual)
        }

        if let existing = try entry(for: id)
        {
            try FileManager.default.removeItem(at: temporary)
            return existing
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blob = blobURL(for: id, contentType: contentType)
        if FileManager.default.fileExists(atPath: blob.path)
        {
            try FileManager.default.removeItem(at: blob)
        }
        try FileManager.default.moveItem(at: temporary, to: blob)
        try finish(id: id, contentType: contentType)

        guard let stored = try entry(for: id) else { throw AssetError.damagedStore(id: id, path: blob.path) }
        return stored
    }

    /// The sidecar goes last: it is what `entry(for:)` treats as the promise that the bytes landed.
    private func finish(id: AssetID, contentType: String) throws
    {
        try contentType.write(to: typeURL(for: id), atomically: true, encoding: .utf8)
    }

    nonisolated func typeURL(for id: AssetID) -> URL
    {
        directory.appendingPathComponent("\(id.hex).type")
    }

    nonisolated func blobURL(for id: AssetID, contentType: String) -> URL
    {
        guard let ext = AssetStore.filenameExtension(for: contentType) else
        {
            return directory.appendingPathComponent(id.hex)
        }
        return directory.appendingPathComponent("\(id.hex).\(ext)")
    }
}

// MARK: - Media types

public extension AssetStore
{
    /// Extension for a media type, so a stored file can be opened by loaders that dispatch on it.
    /// Hand-rolled rather than UniformTypeIdentifiers, which is Darwin-only. Unknown types get no
    /// extension — the bytes are still served and still verifiable, just not directly loadable.
    static func filenameExtension(for contentType: String) -> String?
    {
        switch bareType(of: contentType)
        {
        case "model/vnd.usdz+zip": return "usdz"
        case "model/vnd.usda": return "usda"
        case "model/gltf-binary": return "glb"
        case "model/gltf+json": return "gltf"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/ktx2": return "ktx2"
        case "audio/wav": return "wav"
        case "audio/mpeg": return "mp3"
        case "application/json": return "json"
        default: return nil
        }
    }

    /// Media type for a file extension, for publishing a file we were handed by name.
    static func contentType(forExtension ext: String) -> String?
    {
        switch ext.lowercased()
        {
        case "usdz": return "model/vnd.usdz+zip"
        case "usda": return "model/vnd.usda"
        case "glb": return "model/gltf-binary"
        case "gltf": return "model/gltf+json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "ktx2": return "image/ktx2"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "json": return "application/json"
        default: return nil
        }
    }

    /// "model/vnd.usdz+zip; charset=binary" -> "model/vnd.usdz+zip"
    static func bareType(of contentType: String) -> String
    {
        String(contentType.split(separator: ";").first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    static var defaultContentType: String { "application/octet-stream" }
}
