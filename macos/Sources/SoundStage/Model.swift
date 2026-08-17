import Foundation
import Combine
import CoreAudio

struct Settings: Codable {
    var enabled: [String: Bool] = [:]
    var gain: [String: Float] = [:]
    var delayMs: [String: Float] = [:]
    var mute: [String: Bool] = [:]
    var master: Float = 1
    var masterUid: String? = nil
    var wasRunning: Bool = false
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var running = false
    @Published var levels: [String: Float] = [:]
    @Published var errorMessage: String?
    @Published var settings = Settings()
    /// True when Gatekeeper is running us from a translocated (Downloads) copy.
    @Published var isTranslocated = false

    private let engine = Engine.shared
    private var meterTimer: Timer?
    private var captureHealthWork: [DispatchWorkItem] = []
    private var restartWork: DispatchWorkItem?
    let isPreview: Bool

    static let translocationMessage = """
        SoundStage was opened from Downloads/Desktop, so macOS isolated it (App Translocation) and System Audio Recording permission can’t stick.

        Fix: move SoundStage.app into /Applications, then:
        xattr -dr com.apple.quarantine /Applications/SoundStage.app
        Open it from /Applications and allow permission again.
        """

    static let silentCaptureMessage = """
        System audio isn’t reaching SoundStage (silent tap).

        Privacy can show SoundStage as allowed while the grant is stale — common after rebuilding/reinstalling (the code signature changed).

        Fix:
        1. System Settings › Privacy & Security › Screen & System Audio Recording
        2. Turn SoundStage OFF, then ON again (both lists if you see two)
        3. Quit SoundStage completely, open it from /Applications, play audio, press Start

        A Mac restart is usually not required.
        """

    static let deadAggregateMessage = """
        The mix didn’t start (audio engine never ran). On macOS 26 this often happens when an HDMI/DisplayPort display is included in the aggregate.

        SoundStage left display outputs off by default — enable them one at a time if you need them. Built-in + Bluetooth should work together.
        """

    /// `preview: true` builds a static model for offscreen rendering
    /// (--capture): no engine, no timers, no persistence side effects.
    init(preview: Bool = false) {
        isPreview = preview
        if let data = UserDefaults.standard.data(forKey: "settings"),
           let s = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = s
        }
        refreshDevices()
        guard !preview else { return }
        isTranslocated = isRunningFromAppTranslocation()
        if isTranslocated {
            errorMessage = Self.translocationMessage
        }
        watchDeviceList()

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.125, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollLevels() }
        }

        // Resume routing if it was live when the app last quit.
        if !isTranslocated && settings.wasRunning && !enabledDevices.isEmpty {
            start()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "settings")
        }
    }

    // MARK: - Derived

    var enabledDevices: [AudioDevice] {
        devices.filter { isEnabled($0) }
    }

    /// Explicit setting wins; otherwise on — except HDMI/DP, which often break
    /// private aggregates on macOS 26 (IO never starts). Those are opt-in.
    func isEnabled(_ device: AudioDevice) -> Bool {
        if let explicit = settings.enabled[device.uid] { return explicit }
        if device.transport == "hdmi" || device.transport == "displayport" {
            return false
        }
        return true
    }

    var effectiveMasterUid: String? {
        let enabled = enabledDevices
        if let uid = settings.masterUid, enabled.contains(where: { $0.uid == uid }) {
            return uid
        }
        // Prefer a wired clock: builtin > hdmi/dp/usb > anything
        let pick = enabled.first { $0.transport == "builtin" }
            ?? enabled.first { ["hdmi", "displayport", "usb"].contains($0.transport) }
            ?? enabled.first
        return pick?.uid
    }

    func effectiveGain(_ uid: String) -> Float {
        (settings.mute[uid] ?? false) ? 0 : (settings.gain[uid] ?? 1)
    }

    // MARK: - Engine control

    func start() {
        errorMessage = nil
        isTranslocated = isRunningFromAppTranslocation()
        if isTranslocated {
            errorMessage = Self.translocationMessage
            return
        }
        let list = enabledDevices
        guard !list.isEmpty else {
            errorMessage = "Select at least one output device."
            return
        }
        settings.wasRunning = true
        save()
        do {
            try engine.start(
                deviceConfigs: list.map {
                    Engine.DeviceConfig(uid: $0.uid,
                                        gain: effectiveGain($0.uid),
                                        delayMs: settings.delayMs[$0.uid] ?? 0)
                },
                master: settings.master,
                masterUid: effectiveMasterUid
            )
            running = true
            scheduleCaptureHealthCheck()
        } catch {
            cancelCaptureHealthCheck()
            engine.stop()
            running = false
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        cancelCaptureHealthCheck()
        settings.wasRunning = false
        save()
        engine.stop()
        running = false
        levels = [:]
    }

    func toggle() { running ? stop() : start() }

    func shutdown() {
        cancelCaptureHealthCheck()
        engine.stop()
    }

    /// Debounced restart after structural changes (device set, clock).
    func restartIfRunning() {
        guard running else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.start() }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: - Capture health (silent TCC / post-grant relaunch)

    private func scheduleCaptureHealthCheck() {
        cancelCaptureHealthCheck()
        // Two spaced checks: quiet tracks / slow IO can look silent for ~2s.
        let first = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.evaluateCaptureHealth(final: false) }
        }
        let second = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.evaluateCaptureHealth(final: true) }
        }
        captureHealthWork = [first, second]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: second)
    }

    private func cancelCaptureHealthCheck() {
        captureHealthWork.forEach { $0.cancel() }
        captureHealthWork = []
    }

    private func evaluateCaptureHealth(final: Bool) {
        guard running, engine.running else { return }
        if engine.hasReceivedAudio { return }

        // Aggregate never entered the realtime loop — usually a bad HDMI/DP
        // sub-device, not a Privacy issue. No reboot needed.
        if !engine.hasIOCallbacks {
            guard final else { return }
            engine.stop()
            running = false
            levels = [:]
            settings.wasRunning = false
            save()
            errorMessage = Self.deadAggregateMessage
            return
        }

        // Only treat silence as TCC failure when something else is clearly playing.
        guard anyOtherProcessPlayingOutput() else { return }
        guard final else { return }
        engine.stop()
        running = false
        levels = [:]
        settings.wasRunning = false
        save()
        errorMessage = Self.silentCaptureMessage
    }

    // MARK: - Live parameter updates

    func setGain(_ uid: String, _ value: Float) {
        settings.gain[uid] = value
        save()
        engine.setDevice(uid: uid, gain: effectiveGain(uid))
    }

    func setDelay(_ uid: String, _ ms: Float) {
        settings.delayMs[uid] = ms
        save()
        engine.setDevice(uid: uid, delayMs: ms)
    }

    func toggleMute(_ uid: String) {
        settings.mute[uid] = !(settings.mute[uid] ?? false)
        save()
        engine.setDevice(uid: uid, gain: effectiveGain(uid))
    }

    func setEnabled(_ uid: String, _ on: Bool) {
        settings.enabled[uid] = on
        save()
        restartIfRunning()
    }

    func setMaster(_ value: Float) {
        settings.master = value
        save()
        engine.setMaster(value)
    }

    func setClock(_ uid: String) {
        settings.masterUid = uid
        save()
        restartIfRunning()
    }

    // MARK: - Devices

    func refreshDevices() {
        devices = listOutputDevices()

        // Auto-rejoin: if the set of devices the engine should be driving
        // (enabled + currently present) no longer matches what it is driving —
        // a device reconnected or vanished — restart with the current set.
        if running {
            let want = Set(enabledDevices.map(\.uid))
            let have = Set(engine.slots.map(\.uid))
            if want != have && !want.isEmpty {
                restartIfRunning()
            }
        }
    }

    private func watchDeviceList() {
        var addr = propAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    private func pollLevels() {
        guard engine.running else { return }
        var l: [String: Float] = [:]
        for slot in engine.slots { l[slot.uid] = slot.rms.pointee }
        levels = l
    }
}
