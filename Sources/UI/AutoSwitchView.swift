import SwiftUI

/// Plain-language rule editor: "When <genre is Rock>, use <Rock>".
struct AutoSwitchView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Auto-switch").font(UIStyle.serif(34)).foregroundStyle(UIStyle.ink)
                        Hint("Timbre watches what's playing — Spotify songs, podcasts, videos, calls and games — and picks a preset for it. Rules are checked from the top; the first one that fits wins. Picking a preset yourself pauses auto-switch until the next song.")
                            .frame(maxWidth: 560, alignment: .leading)
                    }
                    Spacer()
                    Toggle("", isOn: $model.autoSwitch).toggleStyle(.switch).labelsHidden().tint(UIStyle.accent)
                }

                NowPlayingCard(model: model)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Eyebrow("Rules")
                        Spacer()
                        AppButton(title: "Reset to defaults", style: .quiet) { model.rules = AutoRule.defaults }
                        AppButton(title: "Add rule", symbol: "plus", style: .primary) {
                            model.rules.insert(AutoRule(field: .genreFamily, value: GenreFamily.pop.rawValue, presetID: model.activePresetID), at: 0)
                        }
                    }
                    ForEach($model.rules) { $rule in
                        RuleRow(rule: $rule, model: model, isMatch: model.autoSwitch && rule.matches(model.context) &&
                                model.rules.first(where: { $0.matches(model.context) })?.id == rule.id)
                    }
                    HStack(spacing: 10) {
                        Text("If nothing matches").font(UIStyle.sans(13, .semibold)).foregroundStyle(UIStyle.ink)
                        Picker("", selection: $model.fallbackPresetID) {
                            Text("Keep the current preset").tag(String?.none)
                            Divider()
                            ForEach(model.library.all) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden().frame(width: 220)
                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(UIStyle.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                }

                AppKindsSection(model: model)
            }
            .padding(24)
        }
    }
}

private struct RuleRow: View {
    @Binding var rule: AutoRule
    @ObservedObject var model: AppModel
    let isMatch: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $rule.enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            Text("When").font(UIStyle.sans(12.5)).foregroundStyle(UIStyle.inkDim)
            Picker("", selection: $rule.field) {
                ForEach(AutoRule.Field.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 170)
            .onChange(of: rule.field) { _, f in rule.value = defaultValue(f) }
            valueEditor.frame(width: 190, alignment: .leading)
            Text("use").font(UIStyle.sans(12.5)).foregroundStyle(UIStyle.inkDim)
            Picker("", selection: $rule.presetID) {
                ForEach(model.library.all) { Text($0.name).tag($0.id) }
                if model.library.preset(id: rule.presetID) == nil { Text("Missing preset").tag(rule.presetID) }
            }
            .labelsHidden().frame(width: 180)
            Spacer()
            if isMatch {
                Text("PLAYING NOW").font(UIStyle.mono(9, .medium)).tracking(1.2).foregroundStyle(UIStyle.accent)
            }
            Button { move(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).foregroundStyle(UIStyle.inkDim).help("Move up")
            Button { move(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).foregroundStyle(UIStyle.inkDim).help("Move down")
            Button { model.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(UIStyle.inkDim).help("Delete rule")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(isMatch ? UIStyle.accent.opacity(0.07) : UIStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isMatch ? UIStyle.accent.opacity(0.5) : UIStyle.line))
        .opacity(rule.enabled ? 1 : 0.5)
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch rule.field {
        case .kind:
            Picker("", selection: $rule.value) {
                ForEach(ContentKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
            }.labelsHidden()
        case .genreFamily:
            Picker("", selection: $rule.value) {
                ForEach(GenreFamily.allCases) { Text($0.label).tag($0.rawValue) }
            }.labelsHidden()
        case .genreText:
            TextField("e.g. lo-fi", text: $rule.value).textFieldStyle(.roundedBorder)
        case .artist:
            TextField("Artist name", text: $rule.value).textFieldStyle(.roundedBorder)
        case .app:
            Picker("", selection: $rule.value) {
                ForEach(knownApps, id: \.self) { Text(ContentDetector.appName($0)).tag($0) }
            }.labelsHidden()
        }
    }

    private var knownApps: [String] {
        var apps = Set(model.appKinds.keys)
        apps.formUnion(["com.spotify.client", "com.apple.Music", "com.apple.Safari", "com.google.Chrome", "us.zoom.xos", "com.hnc.Discord"])
        if !model.context.bundleID.isEmpty { apps.insert(model.context.bundleID) }
        if !rule.value.isEmpty { apps.insert(rule.value) }
        return apps.sorted { ContentDetector.appName($0) < ContentDetector.appName($1) }
    }

    private func defaultValue(_ f: AutoRule.Field) -> String {
        switch f {
        case .kind: ContentKind.music.rawValue
        case .genreFamily: GenreFamily.pop.rawValue
        case .genreText, .artist: ""
        case .app: model.context.bundleID.isEmpty ? "com.spotify.client" : model.context.bundleID
        }
    }

    private func move(_ d: Int) {
        guard let i = model.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let j = i + d
        guard model.rules.indices.contains(j) else { return }
        model.rules.swapAt(i, j)
    }
}

/// Lets the user correct what kind of audio an app makes ("Chrome is music for me").
private struct AppKindsSection: View {
    @ObservedObject var model: AppModel
    @State private var newApp = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("How Timbre treats your apps")
            Hint("Timbre guesses from the app: browsers count as video, Zoom/Discord/FaceTime as calls, games as games. Change any app here.")
            let current = model.context.bundleID
            let apps = Array(Set(model.appKinds.keys).union(current.isEmpty || current == SpotifyClient.bundleID ? [] : [current])).sorted()
            if apps.isEmpty {
                Text("Apps you play sound from will show up here.").font(UIStyle.sans(12)).foregroundStyle(UIStyle.ink.opacity(0.4))
            }
            ForEach(apps, id: \.self) { bundle in
                HStack {
                    Text(ContentDetector.appName(bundle)).font(UIStyle.sans(13, .semibold)).foregroundStyle(UIStyle.ink).frame(width: 180, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { model.appKinds[bundle] ?? model.detector.kind(for: bundle) },
                        set: { model.appKinds[bundle] = $0 })) {
                        ForEach(ContentKind.allCases.filter { $0 != .ad }) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                    if model.appKinds[bundle] != nil {
                        AppButton(title: "Use automatic", style: .quiet) { model.appKinds[bundle] = nil }
                    }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(UIStyle.surface))
            }
        }
    }
}
