// Core Audio engine: global process tap (muted-when-tapped) -> private
// aggregate device over the selected outputs (drift-compensated) -> per-device
// gain/delay/metering in the IO callback.

import Foundation
import CoreAudio
import AudioToolbox

struct AudioDevice: Identifiable, Equatable {
    let uid: String
    let name: String
    let transport: String
    let channels: Int
    let sampleRate: Double
    let isDefault: Bool
    var id: String { uid }
}

// MARK: - Property helpers

func propAddress(_ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func getString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = propAddress(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString? = nil
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
    }
    guard status == noErr, let s = value else { return nil }
    return s as String
}

func getUInt32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var addr = propAddress(selector, scope)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var value: UInt32 = 0
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func getDouble(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
    var addr = propAddress(selector)
    var size = UInt32(MemoryLayout<Double>.size)
    var value: Double = 0
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func outputChannelCount(_ deviceID: AudioObjectID) -> Int {
    var addr = propAddress(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let ablMem = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { ablMem.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ablMem) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(ablMem.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func outputStreamCount(_ deviceID: AudioObjectID) -> Int {
    var addr = propAddress(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return 0 }
    return Int(size) / MemoryLayout<AudioStreamID>.size
}

func transportName(_ deviceID: AudioObjectID) -> String {
    guard let t = getUInt32(deviceID, kAudioDevicePropertyTransportType) else { return "unknown" }
    switch t {
    case kAudioDeviceTransportTypeBuiltIn:      return "builtin"
    case kAudioDeviceTransportTypeBluetooth,
         kAudioDeviceTransportTypeBluetoothLE:  return "bluetooth"
    case kAudioDeviceTransportTypeHDMI:         return "hdmi"
    case kAudioDeviceTransportTypeDisplayPort:  return "displayport"
    case kAudioDeviceTransportTypeUSB:          return "usb"
    case kAudioDeviceTransportTypeAirPlay:      return "airplay"
    case kAudioDeviceTransportTypeThunderbolt:  return "thunderbolt"
    case kAudioDeviceTransportTypeVirtual:      return "virtual"
    case kAudioDeviceTransportTypeAggregate:    return "aggregate"
    default:                                    return "other"
    }
}

func allDeviceIDs() -> [AudioObjectID] {
    var addr = propAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func defaultOutputDeviceID() -> AudioObjectID? {
    var addr = propAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var id: AudioObjectID = 0
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
    return id
}

func deviceIDForUID(_ uid: String) -> AudioObjectID? {
    for id in allDeviceIDs() where getString(id, kAudioDevicePropertyDeviceUID) == uid { return id }
    return nil
}

func listOutputDevices() -> [AudioDevice] {
    let defaultID = defaultOutputDeviceID()
    var result: [AudioDevice] = []
    for id in allDeviceIDs() {
        let channels = outputChannelCount(id)
        guard channels > 0 else { continue }
        let transport = transportName(id)
        guard transport != "virtual" && transport != "aggregate" else { continue }
        guard let uid = getString(id, kAudioDevicePropertyDeviceUID) else { continue }
        result.append(AudioDevice(
            uid: uid,
            name: getString(id, kAudioObjectPropertyName) ?? "Unknown",
            transport: transport,
            channels: channels,
            sampleRate: getDouble(id, kAudioDevicePropertyNominalSampleRate) ?? 0,
            isDefault: id == defaultID
        ))
    }
    return result
}

/// Gatekeeper App Translocation: quarantined apps opened from Downloads/Desktop
/// run from a random read-only path. TCC grants then fail to stick / apply.
func isRunningFromAppTranslocation() -> Bool {
    Bundle.main.bundlePath.contains("/AppTranslocation/")
}

/// True if some other process is actively playing audio (used to distinguish
/// "nothing is playing" from "tap is authorized but delivering silence").
func anyOtherProcessPlayingOutput() -> Bool {
    var addr = propAddress(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else {
        return false
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return false }

    let selfPid = ProcessInfo.processInfo.processIdentifier
    for id in ids {
        if let pid = getUInt32(id, kAudioProcessPropertyPID), pid_t(bitPattern: pid) == selfPid {
            continue
        }
        if let running = getUInt32(id, kAudioProcessPropertyIsRunningOutput), running != 0 {
            return true
        }
    }
    return false
}

// MARK: - Engine

struct EngineError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

final class Engine {
    static let shared = Engine()
    static let maxDelayMs = 750

    struct DeviceConfig {
        let uid: String
        let gain: Float
        let delayMs: Float
    }

    // Per-output-device realtime state. Written from the control thread,
    // read from the audio callback; aligned 32-bit loads/stores are atomic
    // on arm64, and a stale value for one buffer is harmless here.
    final class Slot {
        let uid: String
        let deviceID: AudioObjectID
        var streamCount: Int = 1
        let gain: UnsafeMutablePointer<Float>
        let delayFrames: UnsafeMutablePointer<Int32>
        let rms: UnsafeMutablePointer<Float>

        init(uid: String, deviceID: AudioObjectID) {
            self.uid = uid
            self.deviceID = deviceID
            gain = .allocate(capacity: 1); gain.pointee = 1
            delayFrames = .allocate(capacity: 1); delayFrames.pointee = 0
            rms = .allocate(capacity: 1); rms.pointee = 0
        }
        deinit { gain.deallocate(); delayFrames.deallocate(); rms.deallocate() }
    }

    private(set) var running = false
    private(set) var sampleRate: Double = 48000
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var slots: [Slot] = []
    let masterGain: UnsafeMutablePointer<Float> = .allocate(capacity: 1)
    let inputRms: UnsafeMutablePointer<Float> = .allocate(capacity: 1)
    /// Set from the audio thread when any non-zero tap sample arrives.
    /// Used to detect silent TCC denial (APIs succeed, buffers are all zeros).
    private let sawInputFlag: UnsafeMutablePointer<Int32> = .allocate(capacity: 1)
    /// IO callback invocations — 0 means the aggregate never entered the realtime loop
    /// (common when a broken HDMI/DP device is in the mix on macOS 26).
    private let callbackCount: UnsafeMutablePointer<Int32> = .allocate(capacity: 1)

    private var ring: UnsafeMutablePointer<Float>?
    private var ringFrames = 0
    private var writeIndex = 0   // audio-thread only

    private init() {
        masterGain.pointee = 1
        inputRms.pointee = 0
        sawInputFlag.pointee = 0
        callbackCount.pointee = 0
    }

    /// True once the tap has delivered at least one non-silent buffer this session.
    var hasReceivedAudio: Bool { sawInputFlag.pointee != 0 }

    /// True once the aggregate IO proc has fired at least once.
    var hasIOCallbacks: Bool { callbackCount.pointee > 0 }

    func start(deviceConfigs: [DeviceConfig], master: Float, masterUid: String?) throws {
        if running { stop() }
        sawInputFlag.pointee = 0
        callbackCount.pointee = 0

        slots = []
        for cfg in deviceConfigs {
            guard let id = deviceIDForUID(cfg.uid) else {
                throw EngineError("Device not found: \(cfg.uid)")
            }
            let slot = Slot(uid: cfg.uid, deviceID: id)
            slot.gain.pointee = cfg.gain
            slot.streamCount = max(1, outputStreamCount(id))
            slots.append(slot)
        }
        guard !slots.isEmpty else { throw EngineError("No output devices selected") }
        masterGain.pointee = master

        // 1. Global tap, excluding our own process, muted at the hardware.
        var ownPid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var ownProcessObj = AudioObjectID(kAudioObjectUnknown)
        var addr = propAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        _ = withUnsafePointer(to: &ownPid) { pidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &ownProcessObj)
        }
        var excluded: [AudioObjectID] = []
        if ownProcessObj != kAudioObjectUnknown { excluded.append(ownProcessObj) }

        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        tapDesc.name = "SoundStage Tap"
        tapDesc.muteBehavior = .mutedWhenTapped
        tapDesc.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw EngineError("Could not create the system audio tap (status \(status)). Grant System Audio Recording permission in System Settings › Privacy & Security.")
        }
        tapID = newTapID

        // 2. Best-effort: align nominal rates to the clock device.
        let masterDeviceUid = masterUid ?? slots[0].uid
        let masterID = deviceIDForUID(masterDeviceUid) ?? slots[0].deviceID
        let targetRate = getDouble(masterID, kAudioDevicePropertyNominalSampleRate) ?? 48000
        sampleRate = targetRate
        for slot in slots where slot.deviceID != masterID {
            var rate = targetRate
            var rateAddr = propAddress(kAudioDevicePropertyNominalSampleRate)
            _ = AudioObjectSetPropertyData(slot.deviceID, &rateAddr, 0, nil,
                                           UInt32(MemoryLayout<Double>.size), &rate)
        }

        // 3. Private aggregate: outputs (drift-compensated vs clock) + the tap.
        let subDevices: [[String: Any]] = slots.map {
            [kAudioSubDeviceUIDKey: $0.uid,
             kAudioSubDeviceDriftCompensationKey: $0.deviceID == masterID ? 0 : 1]
        }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundStage Output",
            kAudioAggregateDeviceUIDKey: "com.dn.soundstage.aggregate",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: masterDeviceUid,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: 1]
            ],
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        var newAggID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        guard status == noErr, newAggID != kAudioObjectUnknown else {
            cleanupTap()
            throw EngineError("Could not create the aggregate device (status \(status))")
        }
        aggregateID = newAggID

        if let aggRate = getDouble(aggregateID, kAudioDevicePropertyNominalSampleRate), aggRate > 0 {
            sampleRate = aggRate
        }

        // 4. Delay ring: max delay + headroom for one large IO buffer.
        ringFrames = Int(sampleRate * Double(Engine.maxDelayMs) / 1000.0) + 8192
        ring = .allocate(capacity: ringFrames * 2)
        ring!.initialize(repeating: 0, count: ringFrames * 2)
        writeIndex = 0
        for (i, cfg) in deviceConfigs.enumerated() {
            slots[i].delayFrames.pointee = Int32(Double(cfg.delayMs) * sampleRate / 1000.0)
        }

        // Output buffers appear in sub-device order, one per stream.
        var bufferSlot: [Int] = []
        for (slotIdx, slot) in slots.enumerated() {
            for s in 0..<slot.streamCount { bufferSlot.append(s == 0 ? slotIdx : -1) }
        }

        // 5. IO proc — realtime rules: no allocation, no locks.
        let ringPtr = ring!
        let ringLen = ringFrames
        let slotsRef = slots
        let masterPtr = masterGain
        let inputRmsPtr = inputRms

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            self.callbackCount.pointee &+= 1

            let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)

            // Tap input -> stereo ring
            var frames = 0
            if inABL.count >= 1, let d0 = inABL[0].mData {
                let ch = Int(inABL[0].mNumberChannels)
                if ch >= 2 {
                    let src = d0.assumingMemoryBound(to: Float.self)
                    frames = Int(inABL[0].mDataByteSize) / (4 * ch)
                    var sumSq: Float = 0
                    for f in 0..<frames {
                        let l = src[f * ch], r = src[f * ch + 1]
                        let w = ((self.writeIndex + f) % ringLen) * 2
                        ringPtr[w] = l; ringPtr[w + 1] = r
                        sumSq += l * l + r * r
                    }
                    if frames > 0 {
                        inputRmsPtr.pointee = (sumSq / Float(frames * 2)).squareRoot()
                        if sumSq > 0 { self.sawInputFlag.pointee = 1 }
                    }
                } else if ch == 1 && inABL.count >= 2, let d1 = inABL[1].mData {
                    let l = d0.assumingMemoryBound(to: Float.self)
                    let r = d1.assumingMemoryBound(to: Float.self)
                    frames = Int(inABL[0].mDataByteSize) / 4
                    var sumSq: Float = 0
                    for f in 0..<frames {
                        let w = ((self.writeIndex + f) % ringLen) * 2
                        ringPtr[w] = l[f]; ringPtr[w + 1] = r[f]
                        sumSq += l[f] * l[f] + r[f] * r[f]
                    }
                    if frames > 0 {
                        inputRmsPtr.pointee = (sumSq / Float(frames * 2)).squareRoot()
                        if sumSq > 0 { self.sawInputFlag.pointee = 1 }
                    }
                }
            }
            let base = self.writeIndex
            self.writeIndex = (self.writeIndex + frames) % ringLen
            let master = masterPtr.pointee

            // Ring -> each output with per-device delay/gain
            for (bufIdx, buf) in outABL.enumerated() {
                guard let data = buf.mData else { continue }
                let out = data.assumingMemoryBound(to: Float.self)
                let ch = max(1, Int(buf.mNumberChannels))
                let outFrames = Int(buf.mDataByteSize) / (4 * ch)
                let slotIdx = bufIdx < bufferSlot.count ? bufferSlot[bufIdx] : -1
                guard slotIdx >= 0, frames > 0 else {
                    memset(data, 0, Int(buf.mDataByteSize))
                    continue
                }
                let slot = slotsRef[slotIdx]
                let gain = slot.gain.pointee * master
                let delay = Int(slot.delayFrames.pointee)
                var sumSq: Float = 0
                let n = min(outFrames, frames)
                for f in 0..<n {
                    var idx = (base + f - delay) % ringLen
                    if idx < 0 { idx += ringLen }
                    let l = ringPtr[idx * 2] * gain
                    let r = ringPtr[idx * 2 + 1] * gain
                    if ch == 1 {
                        out[f] = (l + r) * 0.5
                        sumSq += out[f] * out[f]
                    } else {
                        out[f * ch] = l
                        out[f * ch + 1] = r
                        for c in 2..<ch { out[f * ch + c] = 0 }
                        sumSq += l * l + r * r
                    }
                }
                for f in n..<outFrames {
                    for c in 0..<ch { out[f * ch + c] = 0 }
                }
                if n > 0 { slot.rms.pointee = (sumSq / Float(n * min(ch, 2))).squareRoot() }
            }
        }
        guard status == noErr, ioProcID != nil else {
            cleanupAggregate(); cleanupTap()
            throw EngineError("Could not create the IO proc (status \(status))")
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanupProc(); cleanupAggregate(); cleanupTap()
            throw EngineError("Could not start the audio device (status \(status))")
        }

        running = true
    }

    func setDevice(uid: String, gain: Float? = nil, delayMs: Float? = nil) {
        guard let slot = slots.first(where: { $0.uid == uid }) else { return }
        if let g = gain { slot.gain.pointee = max(0, min(2, g)) }
        if let d = delayMs {
            let clamped = max(0, min(Float(Engine.maxDelayMs), d))
            slot.delayFrames.pointee = Int32(Double(clamped) * sampleRate / 1000.0)
        }
    }

    func setMaster(_ gain: Float) { masterGain.pointee = max(0, min(2, gain)) }

    func stop() {
        guard running || tapID != kAudioObjectUnknown else { return }
        cleanupProc()
        cleanupAggregate()
        cleanupTap()
        if let r = ring { r.deallocate(); ring = nil }
        for slot in slots { slot.rms.pointee = 0 }
        inputRms.pointee = 0
        sawInputFlag.pointee = 0
        callbackCount.pointee = 0
        running = false
    }

    private func cleanupProc() {
        if let proc = ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
    }
    private func cleanupAggregate() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }
    private func cleanupTap() {
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
