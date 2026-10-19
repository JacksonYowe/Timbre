import AppKit
import SwiftUI

@main
struct TimbreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("Timbre", id: "main") {
            MainView(model: model)
                .frame(minWidth: 1060, minHeight: 720)
                .onAppear { model.live.visible = true }
                .onDisappear { model.live.visible = false }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("EQ") {
                Button(model.isOn ? "Turn EQ Off" : "Turn EQ On") { model.isOn.toggle() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Next Preset") { model.step(1) }.keyboardShortcut("]", modifiers: .command)
                Button("Previous Preset") { model.step(-1) }.keyboardShortcut("[", modifiers: .command)
                Divider()
                Button("Save") { model.save() }.keyboardShortcut("s").disabled(!model.isModified || model.working.origin != .file)
                Button("Revert to Saved") { model.revert() }.disabled(!model.isModified)
            }
        }

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: model.isOn ? "slider.vertical.3" : "slider.horizontal.below.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        #if DEBUG
        // Dev-only tools below; they write real presets/settings, so they aren't in release builds.
        if let i = CommandLine.arguments.firstIndex(of: "--trace-test"), i + 2 < CommandLine.arguments.count {
            let a = CommandLine.arguments
            let rows = (try? String(contentsOfFile: a[i + 1], encoding: .utf8))?.components(separatedBy: .newlines).dropFirst()
                .compactMap { l -> (Double, Double)? in
                    let c = l.split(separator: ",").compactMap { Double($0) }
                    return c.count >= 2 ? (c[0], c[1]) : nil
                } ?? []
            let err = SelfTest.traceError(rows, save: a[i + 2])
            let truthSorted = rows.sorted { $0.0 < $1.0 }
            let corr = IEMCorrection.bands(measured: truthSorted, target: .neutral)
            print(String(format: "trace max error %.2f dB; correction gains %@", err, corr.map { String(format: "%.1f", $0.gain) }.joined(separator: " ")))
            // Compare with an EqualizerAPO file if given (e.g. AutoEQ's own correction).
            if i + 3 < a.count, let ref = try? EQFile.load(url: URL(fileURLWithPath: a[i + 3])) {
                let fs = EQResponse.logFrequencies(count: 120, high: 12_000)
                let mine = EQResponse.curve(bands: corr, frequencies: fs), theirs = EQResponse.curve(bands: ref.bands, frequencies: fs)
                let d = zip(mine, theirs).map { $0 - $1 }; let mean = d.reduce(0, +) / Double(d.count)
                print(String(format: "vs reference: RMS %.2f dB, worst %.2f dB", sqrt(d.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(d.count)), d.map { abs($0 - mean) }.max()!))
                func near(_ f: Double) -> String { let k = fs.indices.min { abs(log(fs[$0] / f)) < abs(log(fs[$1] / f)) }!; return String(format: "%@ mine %+.1f ref %+.1f", Format.hz(f), mine[k] - mean, theirs[k]) }
                print([50.0, 200, 1000, 3000, 6000, 9000].map(near).joined(separator: " | "))
            }
            exit(0)
        }
        // Dev: run the Set up custom IEM pipeline headlessly.
        // --trace-image <png> <out.png> x0 y0 x1 y1 fLow fHigh dbTop dbBottom [IEM name to create presets]
        if let i = CommandLine.arguments.firstIndex(of: "--trace-image"), i + 10 < CommandLine.arguments.count {
            let a = Array(CommandLine.arguments[(i + 1)...])
            let n = a[2...9].compactMap { Double($0) }
            guard n.count == 8, let img = NSImage(contentsOfFile: a[0]), let bmp = GraphTracer.bitmap(img) else { print("bad args"); exit(1) }
            let box = CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
            let colour = GraphTracer.dominantColour(bmp, in: box) ?? .red
            let pts = GraphTracer.trace(bmp, in: box.insetBy(dx: 2, dy: 2), colour: colour)
            let resp = GraphTracer.response(pts, box: box, fLow: n[4], fHigh: n[5], dbTop: n[6], dbBottom: n[7]).sorted { $0.0 < $1.0 }
            print("colour \(colour.usingColorSpace(.sRGB).map { String(format: "%.0f %.0f %.0f", $0.redComponent * 255, $0.greenComponent * 255, $0.blueComponent * 255) } ?? "?") · \(pts.count) points")
            print([20.0, 50, 100, 300, 1000, 3000, 5000, 7000, 8500, 10000, 15000, 20000].map { String(format: "%@ %.1f", Format.hz($0), GraphicFit.interpolate(resp, at: $0)) }.joined(separator: " | "))
            // Overlay the trace on the picture so it can be checked by eye.
            let out = NSImage(size: NSSize(width: bmp.width, height: bmp.height))
            out.lockFocusFlipped(true)
            img.draw(in: CGRect(x: 0, y: 0, width: bmp.width, height: bmp.height), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            let path = NSBezierPath(); for (k, p) in pts.enumerated() { k == 0 ? path.move(to: p) : path.line(to: p) }
            NSColor.cyan.setStroke(); path.lineWidth = 2; path.stroke()
            NSColor.blue.setStroke(); NSBezierPath(rect: box).stroke()
            out.unlockFocus()
            if let t = out.tiffRepresentation, let r = NSBitmapImageRep(data: t) { try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[1])) }
            let bands = IEMCorrection.bands(measured: resp, target: .neutral)
            print("correction: " + zip(EQPreset.isoCentres, bands).map { String(format: "%@ %+.1f", Format.hz($0), $1.gain) }.joined(separator: ", "))
            if a.count > 10 {
                let r = try? AppModel.shared.setUpIEM(name: a[10], measured: resp, target: .neutral, useForAutoSwitch: true)
                print(r.map { String(format: "created %d presets, %.2f dB from target", $0.created, $0.residual) } ?? "save failed")
                RunLoop.main.run(until: Date().addingTimeInterval(1))   // let settings save
            }
            exit(0)
        }
        // Dev: create an IEM preset set from a measurement CSV (frequency,raw).
        // --setup-iem-csv <csv> <IEM name>
        if let i = CommandLine.arguments.firstIndex(of: "--setup-iem-csv"), i + 2 < CommandLine.arguments.count {
            let a = CommandLine.arguments
            let rows = (try? String(contentsOfFile: a[i + 1], encoding: .utf8))?.components(separatedBy: .newlines).dropFirst()
                .compactMap { l -> (Double, Double)? in
                    let c = l.split(separator: ",").compactMap { Double($0) }
                    return c.count >= 2 ? (c[0], c[1]) : nil
                } ?? []
            let r = try? AppModel.shared.setUpIEM(name: a[i + 2], measured: rows, target: .neutral, useForAutoSwitch: true)
            print(r.map { String(format: "created %d presets, %.2f dB from target", $0.created, $0.residual) } ?? "failed")
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(dir: CommandLine.arguments[i + 1])
            exit(0)
        }
        #endif
        AppModel.shared.startServices()
    }

    // Keep running in the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.engine.stop()   // always hand the Mac's audio back
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.importFiles(urls)
    }
}
