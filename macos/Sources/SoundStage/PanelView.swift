import SwiftUI

/// ImageRenderer (--capture) has no backing window, so hierarchical styles
/// (.secondary/.tertiary/.quaternary) resolve nearly black. During capture we
/// substitute explicit colors; the live app keeps the native styles.
enum CaptureTheme {
    static var active = false
    static var secondary: AnyShapeStyle {
        active ? AnyShapeStyle(Color(white: 0.78)) : AnyShapeStyle(.secondary)
    }
    static var tertiary: AnyShapeStyle {
        active ? AnyShapeStyle(Color(white: 0.58)) : AnyShapeStyle(.tertiary)
    }
    static var faint: AnyShapeStyle {
        active ? AnyShapeStyle(Color(white: 0.30)) : AnyShapeStyle(.quaternary)
    }
}

struct PanelView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            ForEach(model.devices) { device in
                DeviceRow(device: device)
            }
            Divider()
            masterSection
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            controls
            if !CaptureTheme.active {
                Button("Menu Bar Settings…") {
                    AppDelegate.openMenuBarSettings()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(CaptureTheme.secondary)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Label("SoundStage", systemImage: "slider.vertical.3")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if model.running {
                Text("live · \(model.devices.isEmpty ? "" : String(format: "%.1f kHz", Engine.shared.sampleRate / 1000))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.green)
            } else {
                Text("stopped")
                    .font(.caption.monospaced())
                    .foregroundStyle(CaptureTheme.secondary)
            }
        }
    }

    private var masterSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Master")
                    .font(.caption)
                    .foregroundStyle(CaptureTheme.secondary)
                    .frame(width: 44, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { model.settings.master },
                        set: { model.setMaster($0) }
                    ),
                    in: 0...1.5
                )
                Text("\(Int(model.settings.master * 100))%")
                    .font(.caption.monospaced())
                    .foregroundStyle(CaptureTheme.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text("Clock")
                    .font(.caption)
                    .foregroundStyle(CaptureTheme.secondary)
                    .frame(width: 44, alignment: .leading)
                Picker("", selection: Binding(
                    get: { model.effectiveMasterUid ?? "" },
                    set: { model.setClock($0) }
                )) {
                    ForEach(model.enabledDevices) { d in
                        Text(d.name).tag(d.uid)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private var controls: some View {
        HStack {
            Button {
                model.toggle()
            } label: {
                Label(model.running ? "Stop" : "Start",
                      systemImage: model.running ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .tint(model.running ? .red : .green)
            .buttonStyle(.borderedProminent)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .controlSize(.large)
            .help("Quit SoundStage")
        }
    }
}

struct DeviceRow: View {
    @EnvironmentObject var model: AppModel
    let device: AudioDevice

    private var enabled: Bool { model.isEnabled(device) }
    private var muted: Bool { model.settings.mute[device.uid] ?? false }

    private var badge: String {
        switch device.transport {
        case "builtin": "Built-in"
        case "bluetooth": "Bluetooth"
        case "hdmi": "HDMI"
        case "displayport": "DisplayPort"
        case "usb": "USB"
        case "airplay": "AirPlay"
        default: device.transport.capitalized
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                if model.isPreview {
                    // NSSwitch doesn't render offscreen; draw a lookalike.
                    Capsule().fill(enabled ? Color.green : Color.gray.opacity(0.4))
                        .frame(width: 26, height: 15)
                        .overlay(alignment: enabled ? .trailing : .leading) {
                            Circle().fill(.white).frame(height: 13).padding(1)
                        }
                } else {
                    Toggle("", isOn: Binding(
                        get: { enabled },
                        set: { model.setEnabled(device.uid, $0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                }

                Text(device.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(badge)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(CaptureTheme.faint, in: Capsule())
                    .foregroundStyle(CaptureTheme.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("VOL")
                        .font(.system(size: 9, weight: .bold).monospaced())
                        .foregroundStyle(CaptureTheme.tertiary)
                    Slider(
                        value: Binding(
                            get: { model.settings.gain[device.uid] ?? 1 },
                            set: { model.setGain(device.uid, $0) }
                        ),
                        in: 0...1.5
                    )
                    .controlSize(.mini)
                    Text("\(Int((model.settings.gain[device.uid] ?? 1) * 100))%")
                        .font(.caption2.monospaced())
                        .foregroundStyle(CaptureTheme.secondary)
                        .frame(width: 36, alignment: .trailing)
                    Button {
                        model.toggleMute(device.uid)
                    } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(muted ? AnyShapeStyle(.red) : CaptureTheme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(muted ? "Unmute" : "Mute")
                }
                GridRow {
                    Text("DLY")
                        .font(.system(size: 9, weight: .bold).monospaced())
                        .foregroundStyle(CaptureTheme.tertiary)
                    Slider(
                        value: Binding(
                            get: { model.settings.delayMs[device.uid] ?? 0 },
                            set: { model.setDelay(device.uid, $0) }
                        ),
                        in: 0...Float(Engine.maxDelayMs)
                    )
                    .controlSize(.mini)
                    Text("\(Int(model.settings.delayMs[device.uid] ?? 0)) ms")
                        .font(.caption2.monospaced())
                        .foregroundStyle(CaptureTheme.secondary)
                        .frame(width: 46, alignment: .trailing)
                        .lineLimit(1)
                        .fixedSize()
                    Color.clear.frame(width: 12, height: 1)
                }
            }

            MeterBar(level: model.levels[device.uid] ?? 0)
        }
        .opacity(enabled ? 1 : 0.45)
    }
}

struct MeterBar: View {
    let level: Float  // rms 0...1

    private var fraction: CGFloat {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return CGFloat(min(1, max(0, (db + 54) / 54)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(CaptureTheme.faint)
                Capsule()
                    .fill(LinearGradient(
                        colors: [.green, .green, .yellow, .red],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * fraction)
                    .animation(.linear(duration: 0.1), value: fraction)
            }
        }
        .frame(height: 3)
    }
}
