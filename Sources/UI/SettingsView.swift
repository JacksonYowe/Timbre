import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var settingUpIEM = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings").font(UIStyle.serif(34)).foregroundStyle(UIStyle.ink)

                group("Your IEMs") {
                    row("Set up custom IEM",
                        "Add a picture of your IEMs' frequency-response graph. Timbre reads the curve and makes a “Flat · <your IEM>” preset that makes them sound neutral, plus a tuned copy of every auto-switch preset.") {
                        AppButton(title: "Set up…", symbol: "earbuds", style: .primary) { settingUpIEM = true }
                    }
                }

                group("Outputs — which headphones are on which output") {
                    VStack(alignment: .leading, spacing: 0) {
                        Hint("Timbre spots when you switch outputs. Bluetooth and USB devices are remembered by name; the 3.5 mm jack can't identify what's plugged in, so Timbre asks. Picking an IEM switches Flat, favourites and every auto-switch preset to that IEM's tuned versions.")
                            .padding(16)
                        OutputsSettings(model: model)
                    }
                }

                group("Sound") {
                    row("Prevent clipping",
                        "Boosting can push audio past its limit and crackle. Timbre turns the overall level down by just enough to stay clean (a safety limiter catches anything else).") {
                        Toggle("", isOn: $model.preventClipping).toggleStyle(.switch).labelsHidden()
                    }
                    row("Preset crossfade",
                        "How smoothly presets blend into each other when they change (\(Int(model.crossfadeMs)) ms).") {
                        Slider(value: $model.crossfadeMs, in: 10...500, step: 10).frame(width: 200)
                    }
                    row("Output", engineDetail) { EmptyView() }
                }

                group("Detection") {
                    row("Look up genres online",
                        "Spotify doesn't share genres with other apps, so Timbre asks Apple's public music catalogue (artist + song title only; nothing else is sent). Results are remembered.") {
                        Toggle("", isOn: $model.onlineGenres).toggleStyle(.switch).labelsHidden()
                    }
                    row("Spotify access", spotifyText) {
                        if model.spotifyAccess == .denied {
                            AppButton(title: "Open Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                            }
                        }
                    }
                }

                group("Presets") {
                    row("Presets folder", model.library.folder.path) {
                        AppButton(title: "Show in Finder", symbol: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.library.folder])
                        }
                    }
                    row("Hot-swap", "Edit or drop a .txt in that folder and Timbre picks it up within a second — if it's the preset playing, you hear the change straight away.") { EmptyView() }
                }

                group("General") {
                    row("Open at login", "Start Timbre (in the menu bar) when you log in.") {
                        Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })).toggleStyle(.switch).labelsHidden()
                    }
                    row("Show welcome again", "Re-run the first-time setup guide.") {
                        AppButton(title: "Show") { model.hasOnboarded = false }
                    }
                }

                group("Keyboard shortcuts (work in any app)") {
                    shortcut("⌃⌥⌘E", "Turn EQ on / off")
                    shortcut("⌃⌥⌘→  /  ⌃⌥⌘←", "Next / previous preset")
                    shortcut("⌃⌥⌘1 … 9", "Jump to favourite 1–9 (right-click a preset → Add to Favourites)")
                    shortcut("⌃⌥⌘A", "Auto-switch on / off")
                }

                group("About") {
                    Hint("Timbre 1.0 — a system-wide 31-band parametric equaliser for Apple silicon Macs. The audio capture and filter engine build on SystemEQ for Mac by denzam (GPLv3); Timbre is released under the same licence. Genre data from the iTunes Search API.")
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .sheet(isPresented: $settingUpIEM) { IEMSetupView(model: model) }
    }

    private var engineDetail: String {
        switch model.engineState {
        case .running(let d, let sr): "\(d) at \(String(format: "%.1f", sr / 1000)) kHz. Timbre follows whatever output you pick in Control Centre."
        case .off: "EQ is off — your Mac's sound is going straight to the speakers."
        case .starting: "Starting…"
        case .needsPermission: "Waiting for System Audio Recording permission."
        case .failed(let why): why
        }
    }

    private var spotifyText: String {
        switch model.spotifyAccess {
        case .granted: "Connected — Timbre can see what Spotify is playing."
        case .denied: "Blocked. Allow Timbre to control Spotify in System Settings → Privacy & Security → Automation."
        case .notRunning: "Spotify isn't open."
        case .unknown: "Timbre will ask the first time Spotify plays."
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(title).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 14).fill(UIStyle.surface))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UIStyle.line))
        }
    }

    private func row<C: View>(_ title: String, _ detail: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(UIStyle.sans(13.5, .semibold)).foregroundStyle(UIStyle.ink)
                Text(detail).font(UIStyle.sans(11.5)).foregroundStyle(UIStyle.inkDim).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(UIStyle.line).frame(height: 1).padding(.horizontal, 16) }
    }

    private func shortcut(_ keys: String, _ what: String) -> some View {
        HStack {
            Text(keys).font(UIStyle.mono(12, .medium)).foregroundStyle(UIStyle.accent).frame(width: 180, alignment: .leading)
            Text(what).font(UIStyle.sans(12.5)).foregroundStyle(UIStyle.ink)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }
}
