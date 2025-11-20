//
//  File.swift
//  
//
//  Created by Nevyn Bengtsson on 2024-05-28.
//

import Foundation
import OpenCombineShim

func with<T>(_ value: T, using closure: (inout T) -> Void) -> T {
    var copy = value
    closure(&copy)
    return copy
}

extension Dictionary {
    subscript(key: Key, setDefault defaultValue: @autoclosure () -> Value) -> Value {
        mutating get {
            return self[key] ?? {
                let value = defaultValue()
                self[key] = value
                return value
            }()
        }
    }
}

extension EntityID
{
    static func random() -> EntityID
    {
        return UUID().uuidString
    }
}

public extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

public struct LazyMap<K: Hashable, V, V2>: Collection
{
    let storage: Dictionary<K, V>
    let mapper: (K, V) -> V2
    public init(storage: Dictionary<K, V>, mapper: @escaping ((K, V) -> V2)) {
        self.storage = storage
        self.mapper = mapper
    }
    
    // Collection conformance.
    public typealias Key = K
    public typealias Value = V2
    public typealias Element = (key: K, value: V2)
    public typealias Index = Dictionary<K, V>.Index

    public var startIndex: Index {
        storage.startIndex
    }

    public var endIndex: Index {
        storage.endIndex
    }

    public func index(after i: Index) -> Index {
        storage.index(after: i)
    }

    // Provide the lazy transformation.
    public subscript(position: Index) -> Element {
        let (key, value) = storage[position]
        return (key, mapper(key, value))
    }

    // Key-based subscript.
    public subscript(key: K) -> V2? {
        guard let v = storage[key] else { return nil }
        // Lazily transform only when requested.
        return mapper(key, v)
    }
    
    public var keys: [K] {
        [K](storage.keys)
    }
    
    public var values: [V2] {
        storage.map { mapper($0.key, $0.value) }
    }
}


extension Publisher
where Output: BidirectionalCollection & RangeReplaceableCollection,
      Output.Element: Equatable,
      Failure == Never
{
    /// Observe a published ordered collection and get element-level add/remove callbacks.
    public func sinkChanges(
        added: @escaping (Output.Element) -> Void,
        removed: @escaping (Output.Element) -> Void
    ) -> AnyCancellable {
        self
            // Keep (old, new) pair as we stream values.
            .scan((Output(), Output())) { ($0.1, $1) }
            // Build the diff as "what changed to get from old -> new".
            .map { old, new in new.difference(from: old) }
            .sink { diff in
                for change in diff {
                    switch change {
                    case let .insert(_, element, _):
                        added(element)
                    case let .remove(_, element, _):
                        removed(element)
                    }
                }
            }
    }
}

extension Publisher
where Output: SetAlgebra & Sequence,
      Output.Element: Hashable,
      Failure == Never
{
    /// Observe a published set-like collection and get element-level add/remove callbacks.
    public func sinkChanges(
        added: @escaping (Output.Element) -> Void,
        removed: @escaping (Output.Element) -> Void
    ) -> AnyCancellable {
        self
            // Keep (old, new) pair as we stream values.
            .scan((Output(), Output())) { ($0.1, $1) }
            // Compute added/removed as set differences.
            .map { old, new in
                (added: new.subtracting(old), removed: old.subtracting(new))
            }
            .sink { diff in
                for element in diff.added {
                    added(element)
                }
                for element in diff.removed {
                    removed(element)
                }
            }
    }
}

extension Publisher {
    /// Observe a published ordered key-value collection and get element-level add/remove callbacks.
    public func sinkChanges<Key: Hashable, Value>(
        added: @escaping (Key, Value) -> Void,
        removed: @escaping (Key, Value) -> Void
    ) -> AnyCancellable
    where Output == [Key: Value], Failure == Never
    {
        self
            .scan((Dictionary<Key, Value>(), Dictionary<Key, Value>())) { ($0.1, $1) }
            .sink { old, new in
                // Added
                for (k, vNew) in new where old[k] == nil {
                    added(k, vNew)
                }
                // Removed
                for (k, vOld) in old where new[k] == nil {
                    removed(k, vOld)
                }
            }
    }
}

// Utility for command line AlloApps. Run as last line to keep process running while app is processing requests.
// Will return when a `SIGINT` is received by the process.
public func parkToRunloop() async {
    await withUnsafeContinuation
    { continuation in
        signal(SIGINT, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler
        {
            signal(SIGINT, SIG_DFL)
            signalSource.cancel()
            continuation.resume()
        }
        signalSource.resume()
    }
}

public func configurePrintBuffering()
{
    setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered
    setvbuf(stderr, nil, _IONBF, 0)   // unbuffered
}
