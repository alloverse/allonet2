//
//  Latency.swift
//  allonet2
//

import Foundation
import allonet2

/// Mouth-to-speaker latency for voicedemos sharing a machine.
///
/// The sender knows when a frame was captured, the receiver knows when that frame reached the
/// audio device, and the 9 byte frame header is frozen - so the two numbers meet in a file:
/// `VOICEDEMO_LATENCY_LOG=<path>`, one `capture` and one `render` line per frame, joined on
/// media id and sequence. One host means one wall clock, which is the whole reason this works;
/// across machines the difference would be clock skew, not latency.
///
/// `Scripts/voice-latency.sh` computes the same distribution over a finished log.
final class LatencyLog
{
    enum Failure: Error, CustomStringConvertible
    {
        case cannotOpen(path: String, code: Int32)

        var description: String
        {
            switch self
            {
            case .cannotOpen(let path, let code): "cannot open latency log \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    private let out: Int32
    private let input: FileHandle
    private var partialLine = ""
    private var captured: [String: Double] = [:]        // "<mediaId> <sequence>" -> capture time
    private var samples: [String: [Double]] = [:]

    init(path: String) throws
    {
        // O_APPEND makes each line atomic against the other voicedemo writing the same file.
        out = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard out >= 0 else { throw Failure.cannotOpen(path: path, code: errno) }
        guard let input = FileHandle(forReadingAtPath: path) else { throw Failure.cannotOpen(path: path, code: errno) }
        self.input = input
        try input.seekToEnd()   // a previous run's sequence numbers would join against nothing good
    }

    deinit { close(out) }

    /// Safe to call off the main actor: it only appends to the file descriptor.
    func note(capture mediaId: String, sequence: UInt32, at: Date)
    {
        append("capture \(mediaId) \(sequence) \(at.timeIntervalSince1970)")
    }

    func note(render mediaId: String, sequence: UInt32, at: Date)
    {
        append("render \(mediaId) \(sequence) \(at.timeIntervalSince1970)")
        ingestCaptures()
        guard let capturedAt = captured["\(mediaId) \(sequence)"] else { return }
        samples[mediaId, default: []].append(at.timeIntervalSince1970 - capturedAt)
    }

    /// Pipeline latency since the last call, in seconds.
    func report() -> [(stream: String, p50: Double, p95: Double, count: Int)]
    {
        defer { samples.removeAll() }
        return samples.map { mediaId, values in
            let sorted = values.sorted()
            func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
            return (mediaId, percentile(0.5), percentile(0.95), sorted.count)
        }
    }

    /// Take in every capture line written since the last call - by the other voicedemo, and by
    /// this one, which is harmless: media ids do not collide between clients.
    private func ingestCaptures()
    {
        var text = partialLine
        while case let chunk = input.availableData, !chunk.isEmpty
        {
            text += String(decoding: chunk, as: UTF8.self)
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        partialLine = String(lines.removeLast())

        for line in lines where line.hasPrefix("capture ")
        {
            let fields = line.split(separator: " ")
            guard fields.count == 4, let time = Double(fields[3]) else { continue }
            captured["\(fields[1]) \(fields[2])"] = time
        }
        if captured.count > 6000
        {
            let cutoff = Date().timeIntervalSince1970 - 10
            captured = captured.filter { $0.value > cutoff }
        }
    }

    private func append(_ line: String)
    {
        let bytes = Array((line + "\n").utf8)
        let written = bytes.withUnsafeBufferPointer { write(out, $0.baseAddress, $0.count) }
        if written != bytes.count
        {
            fputs("latency log write failed: \(String(cString: strerror(errno)))\n", stderr)
        }
    }
}
