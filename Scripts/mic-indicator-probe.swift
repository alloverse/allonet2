// Walks an AVAudioEngine through the input states VoiceEngine relies on and prints, for each,
// whether macOS counts this process as running input - the flag the menu bar microphone
// indicator follows. Needs a microphone-permitted terminal.
//
//     swiftc -O Scripts/mic-indicator-probe.swift -o /tmp/micprobe && /tmp/micprobe
//
// Measured on macOS 26.5: removing the tap leaves the process running input, so the
// indicator stays lit; only stop, isInputEnabled = false, start clears it, and playout keeps
// running through the restarted engine.

import AVFoundation
import CoreAudio

func processObject() -> AudioObjectID
{
    var pid = getpid(), object = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
    precondition(status == noErr, "no process object for this pid: \(status)")
    return object
}

func runningInput() -> Bool
{
    var value = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(processObject(), &address, 0, nil, &size, &value)
    precondition(status == noErr, "cannot read kAudioProcessPropertyIsRunningInput: \(status)")
    return value == 1
}

func report(_ label: String, _ engine: AVAudioEngine, inputTouched: Bool)
{
    Thread.sleep(forTimeInterval: 0.6)   // the HAL flag lags the engine call
    let unit = inputTouched ? "isInputEnabled=\(engine.inputNode.auAudioUnit.isInputEnabled)" : "inputNode untouched"
    print("\(label.padding(toLength: 44, withPad: " ", startingAt: 0)) runningInput=\(runningInput()) engine=\(engine.isRunning) \(unit)")
}

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: nil)
report("0 idle", engine, inputTouched: false)

try engine.start()
player.play()
report("1 playout only", engine, inputTouched: false)

var taps = 0
let format = engine.inputNode.outputFormat(forBus: 0)
engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: format) { _, _ in taps += 1 }
engine.stop()
try engine.start()
report("2 tap installed", engine, inputTouched: true)
Thread.sleep(forTimeInterval: 0.5)
print("   buffers in 0.5 s: \(taps)")

engine.inputNode.removeTap(onBus: 0)
report("3 tap removed, engine running", engine, inputTouched: true)

engine.stop()
engine.inputNode.auAudioUnit.isInputEnabled = false
try engine.start()
report("4 stop, isInputEnabled = false, start", engine, inputTouched: true)
print("   player still playing: \(player.isPlaying)")

engine.stop()
engine.inputNode.auAudioUnit.isInputEnabled = true
taps = 0
engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: format) { _, _ in taps += 1 }
try engine.start()
report("5 stop, isInputEnabled = true, tap, start", engine, inputTouched: true)
Thread.sleep(forTimeInterval: 0.5)
print("   buffers in 0.5 s: \(taps)")
engine.stop()
