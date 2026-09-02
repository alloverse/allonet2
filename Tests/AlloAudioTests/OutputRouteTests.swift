import Testing
import CoreAudio
@testable import AlloAudio

/// The route decision is what turns the voice processor (and its system-wide ducking) on and
/// off, so the classification is pinned: a wrong answer either ducks a headphone user's music
/// or leaves a speaker user echoing.
@Suite struct OutputRouteTests
{
    @Test func bluetoothIsAssumedWorn()
    {
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil) == .headphones)
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeBluetoothLE, dataSource: nil) == .headphones)
    }

    @Test func builtInIsSpeakersUnlessTheJackSaysOtherwise()
    {
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: nil) == .builtInSpeakers)
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: OutputRoute.headphoneJack) == .headphones)
        // 'ispk', the internal speaker data source.
        #expect(OutputRoute.classify(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6973706B) == .builtInSpeakers)
    }

    @Test func everythingElseIsAssumedToFillTheRoom()
    {
        for transport in [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeHDMI,
                          kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeVirtual]
        {
            #expect(OutputRoute.classify(transport: transport, dataSource: nil) == .external)
        }
        #expect(OutputRoute.classify(transport: nil, dataSource: nil) == .external,
                "an unreadable transport keeps the cautious default: echo cancellation on")
    }

    @Test func onlyHeadphonesSkipEchoCancellation()
    {
        #expect(!OutputRoute.headphones.needsEchoCancellation)
        #expect(OutputRoute.builtInSpeakers.needsEchoCancellation)
        #expect(OutputRoute.external.needsEchoCancellation)
    }
}
