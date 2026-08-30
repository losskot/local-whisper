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
// AVAudioEngine's input tap hands us every buffer the device produces, so nothing is
// dropped. ffmpeg is still used everywhere else (segment concat, and tools/transcribe.sh
// format conversion) — this binary only opens the microphone.
//
// Usage: lw-record <outDir> [chunkSecs] [sampleRate] [deviceUID]
// Writes chunk_000.wav, chunk_001.wav, … as 16-bit mono PCM WAV.
// Prints "READY" on stdout once audio is actually flowing, then one line per chunk.
// On SIGINT/SIGTERM: flushes the partial final chunk and exits 0.
//
// deviceUID, when given, pins capture to that CoreAudio device instead of the system
// default input — e.g. picking the built-in mic explicitly stops macOS from downgrading a
// paired Bluetooth output to its low-quality call profile (HFP) just because the same
// Bluetooth device would otherwise have been used as the mic.

import AVFoundation
import CoreAudio
import Foundation

// MARK: - Arguments

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: lw-record <outDir> [chunkSecs] [sampleRate] [deviceUID]\n".data(using: .utf8)!)
    exit(2)
}
let outDir = args[1]
let chunkSecs = args.count > 2 ? (Double(args[2]) ?? 1.0) : 1.0
let sampleRate = args.count > 3 ? (Double(args[3]) ?? 16000.0) : 16000.0
let deviceUID: String? = (args.count > 4 && !args[4].isEmpty) ? args[4] : nil

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("lw-record: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

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

let engine = AVAudioEngine()
let input = engine.inputNode

if let uid = deviceUID {
    guard let deviceID = findAudioDevice(uid: uid) else {
        fail("input device with UID \(uid) not found — is it connected?")
    }
    guard let audioUnit = input.audioUnit else {
        fail("could not access input audio unit to select device")
    }
    var mutableDeviceID = deviceID
    let status = AudioUnitSetProperty(audioUnit,
                                       kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global,
                                       0,
                                       &mutableDeviceID,
                                       UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else {
        fail("failed to select input device \(uid): OSStatus \(status)")
    }
    FileHandle.standardError.write("lw-record: pinned input device to \(uid)\n".data(using: .utf8)!)
}

let inFormat = input.inputFormat(forBus: 0)

guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
    fail("input device unavailable (sampleRate=\(inFormat.sampleRate), channels=\(inFormat.channelCount)) — check microphone permission")
}

guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                    sampleRate: sampleRate,
                                    channels: 1,
                                    interleaved: true) else {
    fail("could not build output format")
}
guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
    fail("could not build converter \(inFormat) -> \(outFormat)")
}

FileHandle.standardError.write(
    "lw-record: input \(inFormat.sampleRate)Hz \(inFormat.channelCount)ch -> \(Int(sampleRate))Hz mono, chunk=\(chunkSecs)s\n"
        .data(using: .utf8)!)

// The tap runs on a real-time audio thread: convert and hand off, never touch the disk here.
input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
    // Ratio-sized output buffer, plus headroom for the resampler's internal delay.
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRate / inFormat.sampleRate) + 4096
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

    // Feed this buffer exactly once; .noDataNow afterwards makes convert() return
    // .inputRanDry instead of spinning on the same input forever.
    var consumed = false
    var convErr: NSError?
    let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
        if consumed {
            outStatus.pointee = .noDataNow
            return nil
        }
        consumed = true
        outStatus.pointee = .haveData
        return buffer
    }
    if status == .error {
        FileHandle.standardError.write("lw-record: convert error \(convErr?.localizedDescription ?? "?")\n".data(using: .utf8)!)
        return
    }
    guard outBuf.frameLength > 0, let ch = outBuf.int16ChannelData else { return }

    let n = Int(outBuf.frameLength)
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
}

// MARK: - Shutdown

var finishing = false

func finish() -> Never {
    // Idempotent: SIGINT and SIGTERM can both arrive.
    stateLock.lock()
    if finishing { stateLock.unlock(); sleep(2); exit(0) }
    finishing = true
    stateLock.unlock()

    engine.inputNode.removeTap(onBus: 0)
    engine.stop()

    stateLock.lock()
    let tail = pending
    let idx = chunkIndex
    let captured = totalFrames
    pending = []
    stateLock.unlock()

    if !tail.isEmpty {
        writerQueue.sync { writeChunk(index: idx, samples: tail) }
    }
    writerQueue.sync {}  // drain anything still queued from the tap

    let secs = Double(captured) / sampleRate
    FileHandle.standardError.write(String(format: "lw-record: captured %.3fs (%d frames)\n", secs, captured).data(using: .utf8)!)
    print(String(format: "CAPTURED %.3f", secs))
    fflush(stdout)
    exit(0)
}

// DispatchSourceSignal runs the handler on a normal queue, so it is safe to do real
// work in it — unlike a raw signal(2) handler. SIG_IGN stops the default kill first.
//
// These fire on .main deliberately, which means a signal arriving before dispatchMain()
// is reached — i.e. during engine.start() — kills the process outright instead of running
// finish(). That is the right trade: the only caller that signals us that early is the
// warmup-cancel path, which throws the audio away regardless, and moving the handlers to a
// global queue would let finish() call engine.stop() concurrently with engine.start().
// Normal stops arrive as SIGINT long after startup and exit cleanly through finish().
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigint.setEventHandler { finish() }
sigterm.setEventHandler { finish() }
sigint.resume()
sigterm.resume()

// MARK: - Go

do {
    engine.prepare()
    try engine.start()
} catch {
    fail("engine start failed: \(error.localizedDescription) — check microphone permission for the parent app")
}

print("READY")
fflush(stdout)

dispatchMain()
