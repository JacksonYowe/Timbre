import AppKit
import SwiftUI

/// The menu-bar popover: everything you need without opening the window.
struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Timbre").font(UIStyle.serif(24)).foregroundStyle(UIStyle.ink)
                    Text(".").font(UIStyle.serif(24)).foregroundStyle(UIStyle.accent)
                }
                Spacer()
                PowerSwitch(isOn: $model.isOn)
            }

            if let q = model.gearQuestion {
                GearQuestionBanner(model: model, output: q, compact: true)
            } else {
                OutputGearMenu(model: model)
            }

            if model.engineState == .needsPermission {
                Text("Needs System Audio Recording permission — open Timbre for help.")
                    .font(UIStyle.sans(11.5)).foregroundStyle(UIStyle.accent3)
            }

            HStack(spacing: 8) {
                Image(systemName: model.context.kind?.symbol ?? "waveform").foregroundStyle(UIStyle.inkDim)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.context.kind == nil ? "Nothing playing" : (model.context.title.isEmpty ? model.context.appName : model.context.title))
                        .font(UIStyle.sans(12.5, .semibold)).foregroundStyle(UIStyle.ink).lineLimit(1)
                    Text(subtitle).font(UIStyle.sans(11)).foregroundStyle(UIStyle.inkDim).lineLimit(1)
                }
            }

            EQGraphView(model: model, live: model.live, compact: true)
                .frame(height: 90)
                .allowsHitTesting(false)

            HStack {
                Text(model.working.name).font(UIStyle.sans(13, .bold)).foregroundStyle(UIStyle.ink)
                if model.isModified { Text("edited").font(UIStyle.serif(14, italic: true)).foregroundStyle(UIStyle.accent2) }
                Spacer()
                Toggle("Auto", isOn: $model.autoSwitch).toggleStyle(.switch).controlSize(.mini).font(UIStyle.sans(11.5))
            }

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(model.library.all) { p in
                        Button { model.select(p.id) } label: {
                            HStack {
                                MiniCurve(bands: p.bands, active: p.id == model.activePresetID).frame(width: 28, height: 14)
                                Text(p.name).font(UIStyle.sans(12.5, p.id == model.activePresetID ? .bold : .regular))
                                    .foregroundStyle(p.id == model.activePresetID ? UIStyle.ink : UIStyle.ink.opacity(0.8))
                                Spacer()
                                if let slot = model.favourites.firstIndex(of: p.id) {
                                    Text("⌃⌥⌘\(slot + 1)").font(UIStyle.mono(9)).foregroundStyle(UIStyle.ink.opacity(0.35))
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(p.id == model.activePresetID ? UIStyle.surface3 : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 200)

            HStack {
                CompareButton(model: model)
                Spacer()
                AppButton(title: "Open Timbre", style: .primary) {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").foregroundStyle(UIStyle.inkDim) }
                    .buttonStyle(.plain).help("Quit Timbre (your Mac's sound goes back to normal)")
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(UIStyle.bg)
        .preferredColorScheme(.dark)
        .tint(UIStyle.accent)
    }

    private var subtitle: String {
        let c = model.context
        guard let kind = c.kind else { return model.isOn ? "EQ ready" : "EQ off" }
        var parts = [kind.label]
        if kind == .music, !c.genreText.isEmpty { parts.append(c.genreText) }
        if !c.artist.isEmpty { parts.insert(c.artist, at: 0) }
        return parts.joined(separator: " · ")
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Welcome to Timbre").font(UIStyle.serif(40)).foregroundStyle(UIStyle.ink)
                Text(".").font(UIStyle.serif(40)).foregroundStyle(UIStyle.accent)
            }
            Hint("Timbre shapes the sound of everything your Mac plays — Spotify, YouTube, games, calls — and picks the right EQ for whatever's on.")
            step(1, "Turn it on", "macOS will ask if Timbre can record system audio. Click Allow — that's how it gets your sound to equalise it. Nothing is recorded or saved.")
            step(2, "Play something in Spotify", "macOS will ask if Timbre can control Spotify. Allow it so Timbre can tell songs from podcasts and look up the genre.")
            step(3, "Pick a sound — or let Timbre pick", "Try the presets on the left, nudge the five “Your sound” sliders, and hold “Hold to compare” to hear the difference. Drop AutoEQ .txt files for your headphones onto the list.")
            HStack {
                Spacer()
                AppButton(title: "Not now", style: .quiet) { model.hasOnboarded = true; dismiss() }
                AppButton(title: "Turn on EQ", symbol: "power", style: .primary) {
                    model.hasOnboarded = true
                    model.isOn = true
                    dismiss()
                }
            }
        }
        .padding(32)
        .frame(width: 560)
        .background(UIStyle.bg)
        .preferredColorScheme(.dark)
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(UIStyle.mono(13, .medium)).foregroundStyle(UIStyle.bg)
                .frame(width: 26, height: 26).background(Circle().fill(UIStyle.accent))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(UIStyle.sans(15, .bold)).foregroundStyle(UIStyle.ink)
                Hint(text)
            }
        }
    }
}
