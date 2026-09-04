// lw-record — native macOS microphone recorder for local-whisper.
//
// Replaces `ffmpeg -f avfoundation` for LIVE CAPTURE ONLY. ffmpeg's avfoundation
// input device drops roughly 10% of the samples it is handed: a fixed 20s capture
// produced a file holding 18.04s of PCM, and every 1-second chunk it wrote came out
// 0.885–0.917s long. The loss is spread evenly (~100ms per second), which swallows
// short words whole and leaves whisper reconstructing the gaps — the transcript reads
// fluent but has words missing. Neither -thread_queue_size, -drop_late_frames false,
// -use_wallclock_as_timestamps, -capture_raw_data, a different device index, nor
// dropping the segmenter/resampler changed it.
//
// Capture goes through a raw AUHAL unit (kAudioUnitSubType_HALOutput with input
// enabled), NOT AVAudioEngine. AVAudioEngine's inputNode reliably taps only the current
// system-default input: pointing it at another device via kAudioOutputUnitProperty_
// CurrentDevice leaves the engine "running" and printing READY at the right sample rate,
// but the tap never receives a single buffer — CAPTURED 0.000 — because the IO is never
// actually retargeted. A bare AUHAL takes CurrentDevice directly and captures from any
// device, default or not, so pinning the built-in mic works even while a Bluetooth
// headset holds the system default input.
//
// The AUHAL hands us the device's NATIVE format; sample-rate conversion to 16 kHz is done
// by AVAudioConverter, not by the unit. AUHAL's own client-format SRC on the input bus is
// unreliable — asking it for 16 kHz off a 48 kHz device returned 48 kHz samples mislabelled
// as 16 kHz (three seconds of audio counted as eleven). ffmpeg is still used everywhere
// else (segment concat, and tools/transcribe.sh format conversion) — this binary only
// opens the microphone.
//
// Usage: lw-record <outDir|-> [chunkSecs] [sampleRate] [deviceUID]
// Writes chunk_000.wav, chunk_001.wav, … as 16-bit mono PCM WAV.
// An outDir of "-" streams raw 16-bit mono PCM to stdout instead: the wake-word daemon
// needs a continuous sample feed, not files, and must not pay a disk write every 80 ms.
// Prints "READY" on stdout once audio is actually flowing, then one line per chunk.
// On SIGINT/SIGTERM: flushes the partial final chunk and exits 0.
//
// deviceUID, when given, pins capture to that CoreAudio device (matched by its persistent
// UID) instead of the system default input — e.g. picking the built-in mic explicitly
// stops macOS from downgrading a paired Bluetooth output to its low-quality call profile
// (HFP) just because the same Bluetooth device would otherwise have been used as the mic.
// The system default input is never touched: the AUHAL captures the pinned device directly.

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Arguments

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: lw-record <outDir|-> [chunkSecs] [sampleRate] [deviceUID]\n".data(using: .utf8)!)
    exit(2)
}
let outDir = args[1]
// Streaming mode: stdout carries nothing but raw samples, so every status line that would
// normally go there (READY, chunk N, CAPTURED) moves to stderr or the reader sees garbage
// spliced into its audio.
let streamMode = (outDir == "-")
let chunkSecs = args.count > 2 ? (Double(args[2]) ?? 1.0) : 1.0
let sampleRate = args.count > 3 ? (Double(args[3]) ?? 16000.0) : 16000.0
let deviceUID: String? = (args.count > 4 && !args[4].isEmpty) ? args[4] : nil

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("lw-record: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) failed: OSStatus \(status)") }
}

if !streamMode {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
}

// MARK: - WAV writing

/// 44-byte canonical RIFF/WAVE header for 16-bit PCM.
func wavHeader(dataBytes: Int, rate: Double, channels: Int = 1) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let byteRate = UInt32(rate) * UInt32(channels) * 2
    d.append(contentsOf: Array("RIFF".utf8))
    u32(UInt32(36 + dataBytes))
    d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8))
    u32(16)                       // PCM fmt chunk size
    u16(1)                        // format = PCM
    u16(UInt16(channels))
    u32(UInt32(rate))
    u32(byteRate)
    u16(UInt16(channels * 2))     // block align
    u16(16)                       // bits per sample
    d.append(contentsOf: Array("data".utf8))
    u32(UInt32(dataBytes))
    return d
}

let writerQueue = DispatchQueue(label: "lw-record.writer")

func writeChunk(index: Int, samples: [Int16]) {
    if streamMode {
        var raw = Data()
        samples.withUnsafeBufferPointer { raw.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
        do {
            try FileHandle.standardOutput.write(contentsOf: raw)
        } catch {
            // The reader is gone (daemon exited or was killed). Route through the normal
            // signal path so the audio unit is stopped and the microphone released, rather
            // than holding the device open streaming to nobody.
            kill(getpid(), SIGTERM)
        }
        return
    }
    let path = String(format: "%@/chunk_%03d.wav", outDir, index)
    var data = wavHeader(dataBytes: samples.count * 2, rate: sampleRate)
    samples.withUnsafeBufferPointer { data.append(UnsafeRawBufferPointer($0).bindMemory(to: UInt8.self)) }
    // Write to a temp name and rename: init.lua polls this directory while we record,
    // and must never see a half-written header.
    let tmp = path + ".part"
    if FileManager.default.createFile(atPath: tmp, contents: data) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.moveItem(atPath: tmp, toPath: path)
        print("chunk \(index) \(samples.count)")
        fflush(stdout)
    } else {
        FileHandle.standardError.write("lw-record: failed to write \(path)\n".data(using: .utf8)!)
    }
}

// MARK: - Capture state

let stateLock = NSLock()
var pending: [Int16] = []       // converted samples not yet written
var chunkIndex = 0
var totalFrames = 0             // every sample we captured, for the health check
let chunkFrames = Int(sampleRate * chunkSecs)

// MARK: - Device selection

/// Finds a CoreAudio device ID by its persistent UID (stable across reboots, unlike a
/// device index). Returns nil if nothing currently connected matches.
func findAudioDevice(uid target: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
        return nil
    }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
        return nil
    }

    for deviceID in deviceIDs {
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uidRef: CFString? = nil
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uidRef) { ptr in
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
        }
        if status == noErr, let deviceUID = uidRef as String?, deviceUID == target {
            return deviceID
        }
    }
    return nil
}

/// The current system-default input device — used only when no UID is pinned.
func defaultInputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr ? device : nil
}

let deviceID: AudioDeviceID = {
    if let uid = deviceUID {
        guard let d = findAudioDevice(uid: uid) else {
            fail("input device with UID \(uid) not found — is it connected?")
        }
        return d
    }
    guard let d = defaultInputDevice() else {
        fail("no system default input device — check microphone permission")
    }
    return d
}()

// MARK: - AUHAL + converter setup

// Globals the C render callback reads. Assigned during setup below, before the unit starts,
// and only touched afterwards on the single real-time render thread.
var auHAL: AudioUnit!
var converter: AVAudioConverter!
var hwBuffer: AVAudioPCMBuffer!   // AUHAL renders the device's native format into this
var outBuffer: AVAudioPCMBuffer!  // converter writes 16 kHz mono int16 here

guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                    sampleRate: sampleRate,
                                    channels: 1,
                                    interleaved: true) else {
    fail("could not build output format")
}

var acd = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0,
    componentFlagsMask: 0)
guard let comp = AudioComponentFindNext(nil, &acd) else { fail("HALOutput component not found") }
var unitOpt: AudioUnit?
check(AudioComponentInstanceNew(comp, &unitOpt), "create audio unit")
guard let unit = unitOpt else { fail("audio unit is nil") }
auHAL = unit

// Enable input (bus 1), disable output (bus 0): this is a capture-only unit.
var enable: UInt32 = 1
check(AudioUnitSetProperty(auHAL, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                           &enable, UInt32(MemoryLayout<UInt32>.size)), "enable input")
var disable: UInt32 = 0
check(AudioUnitSetProperty(auHAL, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                           &disable, UInt32(MemoryLayout<UInt32>.size)), "disable output")

// Pin the device directly on the unit — the step AVAudioEngine could not make stick.
var dev = deviceID
check(AudioUnitSetProperty(auHAL, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                           &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "set current device")

// The device's native input format. We take it as-is (identity on the client/output scope of
// bus 1) and let AVAudioConverter do the rate/channel/type conversion — see the header note.
var hwFormat = AudioStreamBasicDescription()
var hwSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
check(AudioUnitGetProperty(auHAL, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                           &hwFormat, &hwSize), "get hardware format")
check(AudioUnitSetProperty(auHAL, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                           &hwFormat, hwSize), "set client format")

guard let hwAV = AVAudioFormat(streamDescription: &hwFormat) else {
    fail("could not build AVAudioFormat from device format")
}
guard let conv = AVAudioConverter(from: hwAV, to: outFormat) else {
    fail("could not build converter \(hwAV) -> \(outFormat)")
}
converter = conv

// Size the render buffer to the unit's maximum slice so AudioUnitRender never overflows it.
var maxFrames: UInt32 = 4096
var maxFramesSize = UInt32(MemoryLayout<UInt32>.size)
_ = AudioUnitGetProperty(auHAL, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                         &maxFrames, &maxFramesSize)
if maxFrames == 0 { maxFrames = 4096 }

guard let hb = AVAudioPCMBuffer(pcmFormat: hwAV, frameCapacity: maxFrames) else {
    fail("could not allocate hardware buffer")
}
hwBuffer = hb
// Output capacity: the rate-scaled frame count plus headroom for the resampler's delay.
let outCapacity = AVAudioFrameCount(Double(maxFrames) * sampleRate / hwFormat.mSampleRate) + 4096
guard let ob = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
    fail("could not allocate output buffer")
}
outBuffer = ob

// MARK: - Render callback

// Runs on a real-time audio thread. Render the device's native samples, convert them to
// 16 kHz mono int16, then hand them to the writer — never touch the disk here.
func inputCallback(inRefCon: UnsafeMutableRawPointer,
                   ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                   inTimeStamp: UnsafePointer<AudioTimeStamp>,
                   inBusNumber: UInt32,
                   inNumberFrames: UInt32,
                   ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    hwBuffer.frameLength = inNumberFrames
    let status = AudioUnitRender(auHAL, ioActionFlags, inTimeStamp, 1, inNumberFrames,
                                 hwBuffer.mutableAudioBufferList)
    if status != noErr { return status }

    // Feed the captured buffer to the converter exactly once; .noDataNow afterwards makes
    // convert() return .inputRanDry instead of spinning on the same input forever.
    var consumed = false
    var convErr: NSError?
    let convStatus = converter.convert(to: outBuffer, error: &convErr) { _, outStatus in
        if consumed {
            outStatus.pointee = .noDataNow
            return nil
        }
        consumed = true
        outStatus.pointee = .haveData
        return hwBuffer
    }
    if convStatus == .error { return noErr }
    guard outBuffer.frameLength > 0, let ch = outBuffer.int16ChannelData else { return noErr }

    let n = Int(outBuffer.frameLength)
    let src = UnsafeBufferPointer(start: ch[0], count: n)

    var ready: [(Int, [Int16])] = []
    stateLock.lock()
    pending.append(contentsOf: src)
    totalFrames += n
    while pending.count >= chunkFrames {
        ready.append((chunkIndex, Array(pending[0..<chunkFrames])))
        pending.removeFirst(chunkFrames)
        chunkIndex += 1
    }
    stateLock.unlock()

    for (idx, samples) in ready {
        writerQueue.async { writeChunk(index: idx, samples: samples) }
    }
    return noErr
}

var callback = AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: nil)
check(AudioUnitSetProperty(auHAL, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                           &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
      "set input callback")

FileHandle.standardError.write(
    "lw-record: input \(hwFormat.mSampleRate)Hz \(hwFormat.mChannelsPerFrame)ch -> \(Int(sampleRate))Hz mono, chunk=\(chunkSecs)s, device=\(deviceUID ?? "default")\n"
        .data(using: .utf8)!)

// MARK: - Shutdown

var finishing = false

func finish() -> Never {
    // Idempotent: SIGINT and SIGTERM can both arrive.
    stateLock.lock()
    if finishing { stateLock.unlock(); sleep(2); exit(0) }
    finishing = true
    stateLock.unlock()

    AudioOutputUnitStop(auHAL)
    AudioUnitUninitialize(auHAL)
    AudioComponentInstanceDispose(auHAL)

    stateLock.lock()
    let tail = pending
    let idx = chunkIndex
    let captured = totalFrames
    pending = []
    stateLock.unlock()

    if !tail.isEmpty {
        writerQueue.sync { writeChunk(index: idx, samples: tail) }
    }
    writerQueue.sync {}  // drain anything still queued from the callback

    let secs = Double(captured) / sampleRate
    FileHandle.standardError.write(String(format: "lw-record: captured %.3fs (%d frames)\n", secs, captured).data(using: .utf8)!)
    if streamMode {
        FileHandle.standardError.write(String(format: "CAPTURED %.3f\n", secs).data(using: .utf8)!)
    } else {
        print(String(format: "CAPTURED %.3f", secs))
        fflush(stdout)
    }
    exit(0)
}

// DispatchSourceSignal runs the handler on a normal queue, so it is safe to do real
// work in it — unlike a raw signal(2) handler. SIG_IGN stops the default kill first.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigint.setEventHandler { finish() }
sigterm.setEventHandler { finish() }
sigint.resume()
sigterm.resume()

// MARK: - Go

check(AudioUnitInitialize(auHAL), "initialize audio unit")
let startStatus = AudioOutputUnitStart(auHAL)
if startStatus != noErr {
    fail("start failed: OSStatus \(startStatus) — check microphone permission for the parent app")
}

if streamMode {
    FileHandle.standardError.write("READY\n".data(using: .utf8)!)
} else {
    print("READY")
    fflush(stdout)
}

dispatchMain()
