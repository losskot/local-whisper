// aggregate-audio.swift
// Creates and manages a CoreAudio Multi-Output Device that fans out
// to the user's normal output AND BlackHole 2ch, so meeting mode can
// record system audio without manual Audio MIDI Setup steps.
//
// Build:   swiftc -O aggregate-audio.swift -o aggregate-audio
// Usage:   aggregate-audio <create|delete|set-default <uid>|default-uid|
//                          aggregate-uid|find-uid <name>|list>

import Foundation
import CoreAudio

let AGGREGATE_NAME = "local-whisper Output"
let AGGREGATE_UID  = "com.local-whisper.aggregate-output"
let BLACKHOLE_NAME = "BlackHole 2ch"

// ─── CoreAudio helpers ──────────────────────────────────────────────────────

func systemObject() -> AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

func allDevices() -> [AudioDeviceID] {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    if AudioObjectGetPropertyDataSize(systemObject(), &addr, 0, nil, &size) != noErr { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    let status = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
        guard let base = buf.baseAddress else { return -1 }
        return AudioObjectGetPropertyData(systemObject(), &addr, 0, nil, &size, base)
    }
    return status == noErr ? ids : []
}

func cfStringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope:    scope,
        mElement:  kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString? = nil
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    return status == noErr ? value as String? : nil
}

func deviceUID(_ id: AudioDeviceID) -> String? {
    cfStringProperty(id, selector: kAudioDevicePropertyDeviceUID)
}

func deviceName(_ id: AudioDeviceID) -> String? {
    cfStringProperty(id, selector: kAudioObjectPropertyName)
}

func hasOutputChannels(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope:    kAudioObjectPropertyScopeOutput,
        mElement:  kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    if AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) != noErr { return false }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { buf.deallocate() }
    if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) != noErr { return false }
    let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    var ch = 0
    for b in abl { ch += Int(b.mNumberChannels) }
    return ch > 0
}

func defaultOutputDevice() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var id: AudioDeviceID = 0
    let status = AudioObjectGetPropertyData(systemObject(), &addr, 0, nil, &size, &id)
    return status == noErr ? id : nil
}

func findDevice(byName name: String) -> AudioDeviceID? {
    for id in allDevices() where deviceName(id) == name { return id }
    return nil
}

func findDevice(byUID uid: String) -> AudioDeviceID? {
    for id in allDevices() where deviceUID(id) == uid { return id }
    return nil
}

// ─── Operations ─────────────────────────────────────────────────────────────

func setDefaultOutput(uid: String) -> Bool {
    guard var id = findDevice(byUID: uid) else { return false }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain)
    let status = AudioObjectSetPropertyData(systemObject(), &addr, 0, nil,
                                            UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    return status == noErr
}

func createAggregate() -> (uid: String, alreadyExisted: Bool)? {
    if let existing = findDevice(byName: AGGREGATE_NAME), let uid = deviceUID(existing) {
        return (uid, true)
    }
    guard let bhID = findDevice(byName: BLACKHOLE_NAME), let bhUID = deviceUID(bhID) else {
        FileHandle.standardError.write(Data("error: BlackHole 2ch not found. Install via 'brew install --cask blackhole-2ch'.\n".utf8))
        return nil
    }
    guard let outID = defaultOutputDevice(), let outUID = deviceUID(outID) else {
        FileHandle.standardError.write(Data("error: could not read system default output device\n".utf8))
        return nil
    }
    if outUID == AGGREGATE_UID {
        FileHandle.standardError.write(Data("error: system default output is already the aggregate; switch to your speakers/headphones first so we can use them as the audible side\n".utf8))
        return nil
    }
    let dict: [String: Any] = [
        kAudioAggregateDeviceNameKey            as String: AGGREGATE_NAME,
        kAudioAggregateDeviceUIDKey             as String: AGGREGATE_UID,
        kAudioAggregateDeviceMasterSubDeviceKey as String: outUID,
        kAudioAggregateDeviceIsStackedKey       as String: 1,            // stacked = Multi-Output
        kAudioAggregateDeviceSubDeviceListKey   as String: [
            [kAudioSubDeviceUIDKey as String: outUID],
            [kAudioSubDeviceUIDKey as String: bhUID],
        ],
    ]
    var newID: AudioDeviceID = 0
    let status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &newID)
    if status != noErr {
        FileHandle.standardError.write(Data("error: AudioHardwareCreateAggregateDevice failed (status \(status))\n".utf8))
        return nil
    }
    // Poll until the system's device list publishes the new aggregate.
    // Without this, an immediate set-default lookup can miss it.
    for _ in 0..<40 {
        if findDevice(byName: AGGREGATE_NAME) != nil { break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return (deviceUID(newID) ?? AGGREGATE_UID, false)
}

func deleteAggregate() -> Bool {
    guard let id = findDevice(byName: AGGREGATE_NAME) else { return false }
    return AudioHardwareDestroyAggregateDevice(id) == noErr
}

// ─── CLI ────────────────────────────────────────────────────────────────────

let args = CommandLine.arguments
let prog = (args.first as NSString?)?.lastPathComponent ?? "aggregate-audio"

func usageAndExit() -> Never {
    print("""
    Usage: \(prog) <command> [args]

    Commands:
      create                Create the 'local-whisper Output' Multi-Output Device.
      delete                Remove it.
      set-default <uid>     Make a device the system default output.
      default-uid           Print UID of current system default output.
      aggregate-uid         Print UID of the aggregate device (exits 1 if missing).
      find-uid <name>       Print UID of a device by name (exits 1 if missing).
      list                  List output devices (UID<TAB>name).
    """)
    exit(2)
}

guard args.count >= 2 else { usageAndExit() }

switch args[1] {
case "create":
    guard let r = createAggregate() else { exit(1) }
    print(r.uid)

case "delete":
    if !deleteAggregate() { exit(1) }
    print("ok")

case "recreate":
    // Tear down any existing aggregate, then create fresh against the
    // current default output. Used at meeting start so the aggregate
    // always reflects the user's current audible device (handles
    // disconnects, headphone changes, etc.).
    if deleteAggregate() {
        // Wait for the device list to publish the removal — without this,
        // createAggregate's "already exists" check finds a zombie and
        // skips the actual creation.
        for _ in 0..<40 {
            if findDevice(byName: AGGREGATE_NAME) == nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    guard let r = createAggregate() else { exit(1) }
    print(r.uid)

case "set-default":
    guard args.count == 3 else { usageAndExit() }
    if !setDefaultOutput(uid: args[2]) { exit(1) }
    print("ok")

case "default-uid":
    guard let id = defaultOutputDevice(), let uid = deviceUID(id) else { exit(1) }
    print(uid)

case "aggregate-uid":
    guard let id = findDevice(byName: AGGREGATE_NAME), let uid = deviceUID(id) else { exit(1) }
    print(uid)

case "find-uid":
    guard args.count == 3 else { usageAndExit() }
    guard let id = findDevice(byName: args[2]), let uid = deviceUID(id) else { exit(1) }
    print(uid)

case "list":
    for id in allDevices() where hasOutputChannels(id) {
        let name = deviceName(id) ?? "(unknown)"
        let uid  = deviceUID(id)  ?? "(no-uid)"
        print("\(uid)\t\(name)")
    }

default:
    usageAndExit()
}
