//
//  OutputRoute.swift
//  allonet2
//

import Foundation
#if os(macOS)
import CoreAudio
#endif

/// Where the system's default output points, as far as echo risk goes: the voice processor -
/// and the system-wide ducking it brings - is only worth having when the microphone can hear
/// the speakers. See docs/voice-implementation.md, Route changes.
public enum OutputRoute: Equatable, CustomStringConvertible
{
    /// Open air the microphone hears: echo cancellation needed.
    case builtInSpeakers
    /// Sealed to the ears, wired jack or Bluetooth: nothing to cancel, nothing worth ducking.
    case headphones
    /// USB, HDMI, AirPlay and the rest: assumed to be speakers filling the room.
    case external

    public var needsEchoCancellation: Bool { self != .headphones }

    public var description: String
    {
        switch self
        {
        case .builtInSpeakers: "built-in speakers"
        case .headphones: "headphones"
        case .external: "external output"
        }
    }

    /// The route of the current default output device. A HAL property read; call it off the
    /// main thread. Non-macOS platforms have no device to inspect and answer `.external`,
    /// which keeps the voice processor on.
    public static func current() -> OutputRoute
    {
#if os(macOS)
        guard let device = defaultOutputDevice() else { return .external }
        return classify(transport: read(kAudioDevicePropertyTransportType, of: device),
                        dataSource: read(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, of: device))
#else
        return .external
#endif
    }

#if os(macOS)
    /// 'hdpn': the built-in device's data source with headphones in the jack.
    static let headphoneJack: UInt32 = 0x6864706E

    /// The decision, separated from the HAL so it can be tested. Bluetooth is assumed to be
    /// worn - AirPods dominate, and a Bluetooth-speaker user can live with echo cancellation
    /// off - the built-in device is speakers unless the jack says headphones, and an unknown
    /// or absent transport keeps the cautious default.
    static func classify(transport: UInt32?, dataSource: UInt32?) -> OutputRoute
    {
        switch transport
        {
        case kAudioDeviceTransportTypeBluetooth?, kAudioDeviceTransportTypeBluetoothLE?:
            .headphones
        case kAudioDeviceTransportTypeBuiltIn?:
            dataSource == headphoneJack ? .headphones : .builtInSpeakers
        default:
            .external
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID?
    {
        let device: AudioDeviceID? = read(kAudioHardwarePropertyDefaultOutputDevice, of: AudioObjectID(kAudioObjectSystemObject))
        return device == kAudioObjectUnknown ? nil : device
    }

    private static func read<T>(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                of object: AudioObjectID) -> T?
    {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }
#endif
}
