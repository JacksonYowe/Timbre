import SwiftUI

/// "What are you listening on?" — shown when a new output appears, or something is plugged
/// into the headphone jack (which can't identify itself).
struct GearQuestionBanner: View {
    @ObservedObject var model: AppModel
    let output: OutputInfo
    var compact = false

    var body: some View {
        let gears = Gear.all(in: model.library)
        let saved = model.outputGear[output.uid]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: output.kind.symbol).font(.system(size: compact ? 14 : 18)).foregroundStyle(UIStyle.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(output.kind.cantIdentify ? (compact ? "What's in the headphone jack?" : "What's plugged into the headphone jack?") : "New output: \(output.name)")
                        .font(UIStyle.sans(compact ? 12.5 : 13.5, .bold)).foregroundStyle(UIStyle.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(output.kind.cantIdentify
                         ? "The 3.5 mm jack can't tell Timbre which headphones these are."
                         : "\(output.kind.label) · Timbre will remember your answer for this device.")
                        .font(UIStyle.sans(11.5)).foregroundStyle(UIStyle.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !compact {
                    Button { model.gearQuestion = nil } label: { Image(systemName: "xmark").foregroundStyle(UIStyle.inkDim) }.buttonStyle(.plain)
                }
            }
            FlowChips(items: gears.map { ($0, "earbuds") } + [("No correction", "speaker.wave.2")],
                      selected: saved.map { $0.isEmpty ? "No correction" : $0 }) { choice in
                model.assignGear(choice == "No correction" ? nil : choice, to: output)
            }
            if gears.isEmpty {
                Text("Set up your IEMs in Settings → Set up custom IEM to get tuned presets.")
                    .font(UIStyle.sans(11)).foregroundStyle(UIStyle.inkDim)
            }
        }
        .padding(compact ? 10 : 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(UIStyle.accent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(UIStyle.accent.opacity(0.35)))
    }
}

private struct FlowChips: View {
    let items: [(String, String)]
    let selected: String?
    let pick: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.0) { item in
                    Chip(title: item.0, symbol: item.1, active: item.0 == selected) { pick(item.0) }
                }
            }
        }
    }
}

/// Compact "Output · Gear ▾" control for the menu bar and the top of the window.
struct OutputGearMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let out = model.currentOutput {
            let gear = model.outputGear[out.uid].flatMap { $0.isEmpty ? nil : $0 }
            Menu {
                Section("Listening on \(out.name)") {
                    ForEach(Gear.all(in: model.library), id: \.self) { g in
                        Button { model.assignGear(g, to: out) } label: {
                            if g == gear { Label(g, systemImage: "checkmark") } else { Text(g) }
                        }
                    }
                    Button { model.assignGear(nil, to: out) } label: {
                        if gear == nil, model.outputGear[out.uid] != nil { Label("No correction", systemImage: "checkmark") } else { Text("No correction") }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: out.kind.symbol).font(.system(size: 11))
                    Text("\(out.name) · \(gear ?? "no correction")").font(UIStyle.sans(11.5, .semibold)).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which headphones/IEMs this output is — Timbre switches to their tuned presets")
        }
    }
}

/// Settings → Outputs.
struct OutputsSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let gears = Gear.all(in: model.library)
        VStack(spacing: 0) {
            let outs = model.knownOutputs.values.sorted { ($0.uid == model.currentOutput?.uid ? 0 : 1, $0.name) < ($1.uid == model.currentOutput?.uid ? 0 : 1, $1.name) }
            if outs.isEmpty {
                Text("Outputs you use will appear here.").font(UIStyle.sans(12)).foregroundStyle(UIStyle.inkDim).padding(16)
            }
            ForEach(outs) { out in
                HStack(spacing: 12) {
                    Image(systemName: out.kind.symbol).foregroundStyle(out.uid == model.currentOutput?.uid ? UIStyle.accent : UIStyle.inkDim).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(out.name).font(UIStyle.sans(13.5, .semibold)).foregroundStyle(UIStyle.ink)
                            if out.uid == model.currentOutput?.uid { Text("PLAYING").font(UIStyle.mono(9, .medium)).tracking(1.2).foregroundStyle(UIStyle.accent) }
                        }
                        Text(out.kind.cantIdentify ? "\(out.kind.label) · asks each time you plug in" : out.kind.label)
                            .font(UIStyle.sans(11.5)).foregroundStyle(UIStyle.inkDim)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.outputGear[out.uid] ?? "" },
                        set: { model.assignGear($0.isEmpty ? nil : $0, to: out) })) {
                        Text("No correction").tag("")
                        ForEach(gears, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                    Button { model.knownOutputs[out.uid] = nil; model.outputGear[out.uid] = nil } label: {
                        Image(systemName: "trash").foregroundStyle(UIStyle.inkDim)
                    }.buttonStyle(.plain).help("Forget this output")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .overlay(alignment: .bottom) { Rectangle().fill(UIStyle.line).frame(height: 1).padding(.horizontal, 16) }
            }
        }
    }
}
