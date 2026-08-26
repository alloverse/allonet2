//
//  PlayoutRateController.swift
//  allonet2
//

import Foundation

/// Steers one stream's buffered depth toward its target by playing slightly fast or slow,
/// instead of dropping or inserting audio - the trick FaceTime and libwebrtc's NetEQ use to
/// catch up without a click. Depth that primed too deep is latency until something spends it,
/// and this is what spends it.
///
/// Pure and synchronous. `DataChannelMediaStream` runs it on every pump tick and publishes the
/// result as `playoutRate`; `AlloAudio`'s `VoiceEngine` applies that to the rate node in front
/// of the spatialiser.
///
/// ```swift
/// var controller = PlayoutRateController()
/// let rate = controller.update(error: buffered - target, dt: 0.01)   // frames, seconds
/// ```
public struct PlayoutRateController: Sendable
{
    /// Rate change asked for per frame of depth error: one frame too many asks for 2 % faster
    /// playout, which gives that frame back in a second.
    public static let proportionalGain: Float = 0.02
    /// How far the rate may go, and therefore how fast a correction can be. Also the pitch
    /// budget, because playout resamples rather than time-stretches: 2 % is 34 cents. See
    /// docs/voice-implementation.md, Depth shrinks by playing faster.
    public static let rateLimits: ClosedRange<Float> = 0.98...1.02
    /// How fast the rate itself may move: 0.01 per 100 ms. Slow enough that the sawtooth of a
    /// pump that refills in whole frames averages out rather than making the rate hunt.
    public static let slewPerSecond: Float = 0.1
    /// Depth error below this is that same quantisation, not drift worth correcting.
    public static let deadband: Float = 0.5
    /// Longest gap one update may act on, sized to the pump's 10 ms tick. Without it a stalled
    /// pump cashes the whole stall in as a single step, and `rateLimits` is only 4 % wide: a
    /// 0.4 s gap already crosses the entire range, heard as a pitch step rather than a slew.
    public static let maximumUpdateInterval: TimeInterval = 0.01

    /// What playout should run at now. 1 is the sender's clock.
    public private(set) var rate: Float = 1

    public init() {}

    /// Fold one measurement in, and return the rate playout should use until the next.
    ///
    /// - Parameter error: buffered depth minus target depth, in 20 ms frames. Positive means
    ///   too much audio is queued, so playout should speed up to give it back.
    /// - Parameter dt: seconds since the previous update; bounds how far the rate may move. Taken
    ///   as at most `maximumUpdateInterval`, so a stalled pump resumes gently rather than jumping.
    @discardableResult
    public mutating func update(error: Float, dt: TimeInterval) -> Float
    {
        let desired = abs(error) < Self.deadband
            ? 1
            : min(max(1 + Self.proportionalGain * error, Self.rateLimits.lowerBound), Self.rateLimits.upperBound)
        let step = Self.slewPerSecond * Float(min(max(dt, 0), Self.maximumUpdateInterval))
        rate += min(max(desired - rate, -step), step)
        return rate
    }
}
