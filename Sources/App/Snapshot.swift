import AppKit
import SwiftUI

/// `Timbre --snapshot <dir>` — renders the main window offscreen to PNGs (dev aid; no permissions needed).
enum Snapshot {
    static func run(dir: String) {
        let model = AppModel.shared
        model.persistenceDisabled = true
        model.hasOnboarded = true
        model.tone.bass = 3
        let demo = OutputInfo(uid: "demo-jack", name: "External Headphones", kind: .headphoneJack)
        model.currentOutput = demo
        model.knownOutputs = [demo.uid: demo, "demo-bt": OutputInfo(uid: "demo-bt", name: "Bluetooth Earbuds", kind: .bluetooth)]
        model.outputGear = [demo.uid: "Example IEM", "demo-bt": ""]
        model.gearQuestion = demo
        model.selectedBand = 6
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        render(MainView(model: model), size: CGSize(width: 1180, height: 1180), to: dir + "/main.png")
        render(MenuBarView(model: model), size: CGSize(width: 320, height: 560), to: dir + "/menubar.png")
        render(AutoSwitchView(model: model).background(UIStyle.bg), size: CGSize(width: 944, height: 1000), to: dir + "/auto.png")
        render(SettingsView(model: model).background(UIStyle.bg), size: CGSize(width: 944, height: 1000), to: dir + "/settings.png")
        render(BandSlidersView(model: model).padding(24).background(UIStyle.bg), size: CGSize(width: 944, height: 340), to: dir + "/bands.png")
        render(ParametricView(model: model).padding(24).background(UIStyle.bg), size: CGSize(width: 944, height: 420), to: dir + "/parametric.png")
        render(OnboardingView(model: model), size: CGSize(width: 560, height: 470), to: dir + "/onboarding.png")
    }

    private static func render<V: View>(_ view: V, size: CGSize, to path: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
