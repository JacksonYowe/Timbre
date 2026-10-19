import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var page: Page = .equaliser
    @State private var editor: Editor = .simple
    @State private var savingAs = false
    @State private var saveName = ""

    enum Page: String, CaseIterable { case equaliser = "Equaliser", auto = "Auto-switch", settings = "Settings" }
    enum Editor: String, CaseIterable { case simple = "Simple", graphic = "31 bands", parametric = "Parametric" }

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(model: model, library: model.library)
            VStack(spacing: 0) {
                topBar
                Group {
                    switch page {
                    case .equaliser: equaliserPage
                    case .auto: AutoSwitchView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(UIStyle.bg)
        }
        .background(UIStyle.bg)
        .overlay(alignment: .bottom) { toast }
        .preferredColorScheme(.dark)
        .tint(UIStyle.accent)
        .sheet(isPresented: Binding(get: { !model.hasOnboarded }, set: { if !$0 { model.hasOnboarded = true } })) {
            OnboardingView(model: model)
        }
        .alert("Name this preset", isPresented: $savingAs) {
            TextField("Name", text: $saveName)
            Button("Save") { if !saveName.isEmpty { model.save(as: saveName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's saved as a .txt EQ file you can share or edit.")
        }
        .alert("Some files couldn't be imported", isPresented: Binding(get: { !model.fileProblems.isEmpty }, set: { if !$0 { model.fileProblems = [] } })) {
            Button("OK") { model.fileProblems = [] }
        } message: {
            Text(model.fileProblems.joined(separator: "\n\n"))
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 16) {
            PowerSwitch(isOn: $model.isOn)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.isOn ? "EQ is on" : "EQ is off").font(UIStyle.sans(13, .bold)).foregroundStyle(UIStyle.ink)
                Text(engineLine).font(UIStyle.sans(11)).foregroundStyle(UIStyle.inkDim).lineLimit(1)
            }
            OutputGearMenu(model: model).padding(.leading, 6)
            Spacer()
            HStack(spacing: 4) {
                ForEach(Page.allCases, id: \.self) { p in
                    Chip(title: p.rawValue, active: page == p) { withAnimation(UIStyle.ease) { page = p } }
                }
            }
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
    }

    private var engineLine: String {
        switch model.engineState {
        case .off: "Your Mac's sound is untouched"
        case .starting: "Starting…"
        case .running(let device, let sr): "Playing through \(device) · \(Int(sr / 1000)) kHz"
        case .needsPermission: "Needs permission to hear your Mac's audio"
        case .failed(let why): why
        }
    }

    // MARK: Equaliser page

    private var equaliserPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.engineState == .needsPermission { PermissionBanner() }
                if let q = model.gearQuestion { GearQuestionBanner(model: model, output: q) }
                NowPlayingCard(model: model)
                presetHeader
                EQGraphView(model: model, live: model.live)
                    .frame(height: 270)
                FrequencyZones()
                BandInspector(model: model)
                editorTabs
                Group {
                    switch editor {
                    case .simple: SimpleToneView(model: model)
                    case .graphic: BandSlidersView(model: model)
                    case .parametric: ParametricView(model: model)
                    }
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .animation(UIStyle.ease, value: model.selectedBand)
        }
    }

    private var presetHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(model.working.origin == .file ? "EQ file" : "Preset")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.working.name).font(UIStyle.serif(34)).foregroundStyle(UIStyle.ink).lineLimit(1)
                    if model.isModified { Text("edited").font(UIStyle.serif(20, italic: true)).foregroundStyle(UIStyle.accent2) }
                }
                if !model.working.blurb.isEmpty {
                    Text(model.working.blurb).font(UIStyle.sans(12)).foregroundStyle(UIStyle.inkDim).lineLimit(1)
                }
            }
            Spacer()
            CompareButton(model: model)
            if model.isModified {
                AppButton(title: "Revert", style: .quiet) { model.revert() }
                if model.working.origin == .file {
                    AppButton(title: "Save", symbol: "checkmark", style: .primary) { model.save() }
                }
            }
            AppButton(title: model.working.origin == .file && model.isModified ? "Save as…" : "Save as…", symbol: "square.and.arrow.down") {
                saveName = model.working.name + (model.working.origin == .builtIn ? " (custom)" : "")
                savingAs = true
            }
        }
    }

    private var editorTabs: some View {
        HStack(spacing: 4) {
            ForEach(Editor.allCases, id: \.self) { e in
                Chip(title: e.rawValue, active: editor == e) { withAnimation(UIStyle.ease) { editor = e } }
            }
            Spacer()
            if editor != .simple, !model.tone.isNeutral {
                Label("Your sound adds extra tone on top", systemImage: "info.circle")
                    .font(UIStyle.sans(11)).foregroundStyle(UIStyle.inkDim)
            }
        }
        .padding(.top, 4)
    }

    private var toast: some View {
        Group {
            if let t = model.toast {
                Text(t).font(UIStyle.sans(13, .semibold)).foregroundStyle(UIStyle.bg)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(UIStyle.accent))
                    .shadow(color: UIStyle.accent.opacity(0.4), radius: 16)
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// Press and hold to hear the music without any EQ — the easiest way to judge a change.
struct CompareButton: View {
    @ObservedObject var model: AppModel
    @State private var pressed = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: pressed ? "ear.fill" : "ear").font(.system(size: 11, weight: .semibold))
            Text(pressed ? "Hearing original" : "Hold to compare").font(UIStyle.sans(12.5, .semibold))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .foregroundStyle(pressed ? UIStyle.bg : UIStyle.ink)
        .background(RoundedRectangle(cornerRadius: 10).fill(pressed ? UIStyle.accent2 : UIStyle.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(UIStyle.line))
        .opacity(model.isOn ? 1 : 0.4)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !pressed, model.isOn { pressed = true; model.comparing = true } }
            .onEnded { _ in pressed = false; model.comparing = false })
        .help("Hold to hear your audio without EQ, release to hear it with EQ")
    }
}

struct PermissionBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 20)).foregroundStyle(UIStyle.accent3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Timbre needs permission to hear your Mac's audio").font(UIStyle.sans(13.5, .bold)).foregroundStyle(UIStyle.ink)
                Hint("Open System Settings → Privacy & Security → Screen & System Audio Recording, turn on Timbre under “System Audio Recording Only”, then switch the EQ back on. Your sound was given back so you're never left in silence.")
            }
            Spacer()
            AppButton(title: "Open Settings", style: .primary) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(UIStyle.accent3.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UIStyle.accent3.opacity(0.35)))
    }
}
