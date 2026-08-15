import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Tear the tap down so system audio unmutes.
        Engine.shared.stop()
    }
}

@main
struct SoundStageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    init() {
        // Dev-only: `SoundStage --capture out.png [--hero]` renders the panel
        // offscreen to a PNG (used to generate the README screenshots).
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--capture"), args.count > idx + 1 {
            Self.capture(to: args[idx + 1], hero: args.contains("--hero"))
            exit(0)
        }
    }

    @MainActor
    private static func capture(to path: String, hero: Bool) {
        CaptureTheme.active = true
        let model = AppModel(preview: true)
        model.running = true
        // Deterministic demo state, independent of what's connected.
        model.devices = [
            AudioDevice(uid: "demo-builtin", name: "MacBook Pro Speakers", transport: "builtin",
                        channels: 2, sampleRate: 48000, isDefault: true),
            AudioDevice(uid: "demo-hdmi", name: "DELL S3225QS", transport: "hdmi",
                        channels: 2, sampleRate: 48000, isDefault: false),
            AudioDevice(uid: "demo-bt", name: "OB-4", transport: "bluetooth",
                        channels: 2, sampleRate: 48000, isDefault: false),
        ]
        model.settings = Settings()
        let demoLevels: [Float] = [0.09, 0.05, 0.07]
        for (i, d) in model.devices.enumerated() {
            model.settings.gain[d.uid] = [1.0, 0.85, 0.9][i]
            // Delay goes on the *fast* (wired) devices to match Bluetooth
            model.settings.delayMs[d.uid] = d.transport == "bluetooth" ? 0 : 180
            model.levels[d.uid] = demoLevels[i]
        }

        let panel = PanelView()
            .environmentObject(model)
            .background(Color(red: 0.165, green: 0.17, blue: 0.185))
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1))

        let content: AnyView = hero
            ? AnyView(panel
                .shadow(color: .black.opacity(0.55), radius: 28, y: 18)
                .padding(56)
                .background(LinearGradient(
                    colors: [Color(red: 0.09, green: 0.11, blue: 0.16),
                             Color(red: 0.04, green: 0.05, blue: 0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)))
            : AnyView(panel)

        let renderer = ImageRenderer(content: content.preferredColorScheme(.dark))
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            FileHandle.standardError.write(Data("capture failed\n".utf8))
            exit(1)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        print("wrote \(path)")
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}
