import SwiftUI

// MARK: - Simple: five tone controls

struct SimpleToneView: View {
    @ObservedObject var model: AppModel

    private struct Control { let key: WritableKeyPath<ToneLayer, Double>; let name: String; let hz: String; let help: String }
    private let controls: [Control] = [
        .init(key: \.bass, name: "Bass", hz: "below 100 Hz", help: "Thump and weight — kick drums, bass lines, explosions."),
        .init(key: \.warmth, name: "Warmth", hz: "around 280 Hz", help: "Fullness and body. Turn down if things sound muddy."),
        .init(key: \.vocals, name: "Vocals", hz: "around 2 kHz", help: "Brings voices and lead instruments forward."),
        .init(key: \.detail, name: "Detail", hz: "around 5 kHz", help: "Crispness and clarity. Turn down if it sounds harsh."),
        .init(key: \.air, name: "Air", hz: "above 10 kHz", help: "Sparkle and space — cymbals, breath, room sound."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your sound").font(UIStyle.sans(15, .bold)).foregroundStyle(UIStyle.ink)
                    Hint("These five controls sit on top of whatever preset is playing, so your taste follows you when Timbre switches presets for a new song.")
                }
                Spacer()
                if !model.tone.isNeutral {
                    AppButton(title: "Reset", symbol: "arrow.counterclockwise", style: .quiet) {
                        withAnimation(UIStyle.ease) { model.tone = ToneLayer() }
                    }
                }
            }
            HStack(spacing: 12) {
                ForEach(controls, id: \.name) { c in
                    ToneSlider(name: c.name, hz: c.hz, help: c.help, value: Binding(
                        get: { model.tone[keyPath: c.key] },
                        set: { model.tone[keyPath: c.key] = $0 }
                    ))
                }
            }
        }
    }
}

private struct ToneSlider: View {
    let name: String
    let hz: String
    let help: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name).font(UIStyle.sans(13.5, .bold)).foregroundStyle(UIStyle.ink)
                Spacer()
                Text(Format.db(value)).font(UIStyle.mono(11, .medium))
                    .foregroundStyle(abs(value) < 0.05 ? UIStyle.inkDim : UIStyle.accent)
            }
            HorizontalCentreSlider(value: $value, range: ToneLayer.range)
            Text(hz.uppercased()).font(UIStyle.mono(9, .medium)).tracking(1.1).foregroundStyle(UIStyle.ink.opacity(0.4))
            Text(help).font(UIStyle.sans(11.5)).foregroundStyle(UIStyle.inkDim).fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(UIStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(UIStyle.line))
    }
}

/// Slider whose fill grows out from the centre (0 dB) — makes boost vs cut obvious.
struct HorizontalCentreSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let t = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let mid = w / 2
            ZStack(alignment: .leading) {
                Capsule().fill(UIStyle.surface3).frame(height: 4)
                Rectangle().fill(UIStyle.ink.opacity(0.3)).frame(width: 1, height: 10).offset(x: mid)
                Capsule().fill(UIStyle.accent)
                    .frame(width: abs(t * w - mid), height: 4)
                    .offset(x: min(t * w, mid))
                Circle().fill(UIStyle.ink).frame(width: 16, height: 16)
                    .shadow(color: UIStyle.accent.opacity(abs(value) > 0.05 ? 0.6 : 0), radius: 6)
                    .offset(x: t * w - 8)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let frac = Double(min(max(g.location.x / w, 0), 1))
                var v = range.lowerBound + frac * (range.upperBound - range.lowerBound)
                if abs(v) < 0.35 { v = 0 }    // gentle snap to flat
                value = (v * 10).rounded() / 10
            })
            .onTapGesture(count: 2) { value = 0 }
        }
        .frame(height: 20)
    }
}

// MARK: - 31-band sliders

struct BandSlidersView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.working.isGraphic31 ? "31-band graphic EQ" : "\(model.working.bands.count) bands")
                        .font(UIStyle.sans(15, .bold)).foregroundStyle(UIStyle.ink)
                    Hint(model.working.isGraphic31
                         ? "Each slider is a 1/3-octave band — drag up to boost, down to cut. Double-click a slider to flatten it."
                         : "This preset uses custom bands from a parametric file. Convert it to the standard 31 bands to edit it like a graphic EQ — it'll sound the same.")
                }
                Spacer()
                if !model.working.isGraphic31 {
                    AppButton(title: "Convert to 31 bands", symbol: "slider.vertical.3") { model.convertTo31() }
                }
                AppButton(title: "Flatten", symbol: "minus", style: .quiet) { withAnimation(UIStyle.ease) { model.resetAll() } }
            }
            PreampRow(model: model)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(model.working.bands.indices, id: \.self) { i in
                    VerticalBandSlider(model: model, index: i)
                }
            }
            .frame(height: 210)
        }
    }
}

private struct VerticalBandSlider: View {
    @ObservedObject var model: AppModel
    let index: Int
    @State private var hovering = false

    var body: some View {
        if model.working.bands.indices.contains(index) { slider(model.working.bands[index]) }
    }

    @ViewBuilder
    private func slider(_ band: EQBand) -> some View {
        let selected = model.selectedBand == index
        VStack(spacing: 6) {
            Text(abs(band.gain) < 0.05 ? "0" : Format.db(band.gain))
                .font(UIStyle.mono(8.5, .medium))
                .foregroundStyle(selected || hovering ? UIStyle.accent : (abs(band.gain) < 0.05 ? UIStyle.ink.opacity(0.3) : UIStyle.inkDim))
                .lineLimit(1).minimumScaleFactor(0.6)
            GeometryReader { geo in
                let h = geo.size.height
                let range = 15.0
                let t = CGFloat((min(max(band.gain, -range), range) + range) / (2 * range))
                let y = h - t * h
                ZStack(alignment: .top) {
                    Capsule().fill(UIStyle.surface3).frame(width: 3)
                    Capsule().fill(band.enabled ? UIStyle.accent : UIStyle.inkFaint)
                        .frame(width: 3, height: abs(y - h / 2))
                        .offset(y: min(y, h / 2))
                    RoundedRectangle(cornerRadius: 3).fill(selected ? UIStyle.accent : UIStyle.ink)
                        .frame(width: 14, height: 6)
                        .offset(y: y - 3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    model.selectedBand = index
                    let frac = 1 - Double(min(max(g.location.y / h, 0), 1))
                    var v = -range + frac * 2 * range
                    if abs(v) < 0.3 { v = 0 }
                    model.setGain(index, (v * 10).rounded() / 10)
                })
                .onTapGesture(count: 2) { model.setGain(index, 0) }
            }
            Text(Format.hz(band.frequency))
                .font(UIStyle.mono(8.5)).foregroundStyle(selected ? UIStyle.accent : UIStyle.ink.opacity(0.45))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering || selected ? UIStyle.surface : .clear))
        .onHover { hovering = $0 }
        .help("\(Format.hz(band.frequency)) Hz · \(band.type.label)")
    }
}

struct PreampRow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 14) {
            Eyebrow("Preamp")
            HorizontalCentreSlider(value: Binding(get: { model.working.preamp }, set: { model.working.preamp = $0 }), range: -12...12)
                .frame(width: 180)
            Text(Format.db(model.working.preamp) + " dB").font(UIStyle.mono(11)).foregroundStyle(UIStyle.inkDim)
            if model.preventClipping, model.appliedPreamp < model.working.preamp - 0.05 {
                Label("Auto headroom \(Format.db(model.appliedPreamp - model.working.preamp)) dB", systemImage: "shield.lefthalf.filled")
                    .font(UIStyle.sans(11.5, .medium)).foregroundStyle(UIStyle.accent2)
                    .help("Boosting makes the signal louder than digital audio allows, which distorts. Timbre lowers the overall level by this much so it can't clip. Turn this off in Settings.")
            }
            Spacer()
        }
    }
}

// MARK: - Parametric table

struct ParametricView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parametric").font(UIStyle.sans(15, .bold)).foregroundStyle(UIStyle.ink)
                    Hint("Full control of every band: its shape, centre frequency, boost/cut and width (Q). Higher Q = narrower.")
                }
                Spacer()
                AppButton(title: "Add band", symbol: "plus") { model.addBand() }
                    .disabled(model.working.bands.count >= EQPreset.maxBands)
            }
            PreampRow(model: model)
            HStack(spacing: 0) {
                header("#", 30); header("On", 40); header("Shape", 150); header("Frequency", 120); header("Gain", 120); header("Q / width", 120)
                Spacer()
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.working.bands.indices, id: \.self) { i in
                        ParametricRow(model: model, index: i)
                    }
                }
            }
            .frame(minHeight: 160)
        }
    }

    private func header(_ t: String, _ w: CGFloat) -> some View {
        Eyebrow(t).frame(width: w, alignment: .leading)
    }
}

private struct ParametricRow: View {
    @ObservedObject var model: AppModel
    let index: Int

    var body: some View {
        if model.working.bands.indices.contains(index) {
            let selected = model.selectedBand == index
            HStack(spacing: 0) {
                Text("\(index + 1)").font(UIStyle.mono(11)).foregroundStyle(UIStyle.inkDim).frame(width: 30, alignment: .leading)
                Toggle("", isOn: bind(\.enabled)).toggleStyle(.switch).controlSize(.mini).labelsHidden().frame(width: 40, alignment: .leading)
                Picker("", selection: bind(\.type)) {
                    ForEach(FilterType.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 140).padding(.trailing, 10)
                NumberField(value: bind(\.frequency), unit: "Hz", step: 1, range: 10...22_000, log: true).frame(width: 120, alignment: .leading)
                NumberField(value: bind(\.gain), unit: "dB", step: 0.1, range: -24...24, log: false)
                    .frame(width: 120, alignment: .leading)
                    .opacity(model.working.bands[index].type.usesGain ? 1 : 0.3)
                NumberField(value: bind(\.q), unit: "Q", step: 0.01, range: 0.05...60, log: true).frame(width: 120, alignment: .leading)
                Spacer()
                Button { model.removeBand(index) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(UIStyle.inkDim)
                }.buttonStyle(.plain).help("Remove band")
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? UIStyle.surface2 : UIStyle.surface.opacity(0.5)))
            .onTapGesture { model.selectedBand = index }
        }
    }

    private func bind<T>(_ key: WritableKeyPath<EQBand, T>) -> Binding<T> {
        Binding(get: { model.working.bands[index][keyPath: key] },
                set: { if model.working.bands.indices.contains(index) { model.working.bands[index][keyPath: key] = $0 } })
    }
}

/// Editable number with drag-to-scrub on the unit label.
struct NumberField: View {
    @Binding var value: Double
    let unit: String
    let step: Double
    let range: ClosedRange<Double>
    let log: Bool
    @State private var text = ""
    @State private var dragStartValue: Double?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(UIStyle.mono(11.5))
                .foregroundStyle(UIStyle.ink)
                .frame(width: 62)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(UIStyle.surface2))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
            Text(unit).font(UIStyle.mono(10)).foregroundStyle(UIStyle.inkDim)
                .padding(4)
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { g in
                    let start = dragStartValue ?? value
                    dragStartValue = start
                    let d = Double(-g.translation.height + g.translation.width)
                    let v = log ? start * pow(2, d / 120) : start + d * step * 0.5
                    value = min(range.upperBound, max(range.lowerBound, (v / step).rounded() * step))
                }.onEnded { _ in dragStartValue = nil })
                .help("Drag to adjust")
        }
        .onAppear { text = display(value) }
        .onChange(of: value) { _, v in if !focused { text = display(v) } }
    }

    private func display(_ v: Double) -> String {
        if unit == "Hz" { return v < 100 ? String(format: "%.1f", v) : String(format: "%.0f", v) }
        if unit == "Q" { return String(format: "%.2f", v) }
        return String(format: "%.1f", v)
    }

    private func commit() {
        var t = text.lowercased().replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        var mult = 1.0
        if t.hasSuffix("k") { mult = 1000; t.removeLast() }
        if let v = Double(t) { value = min(range.upperBound, max(range.lowerBound, v * mult)) }
        text = display(value)
    }
}

// MARK: - Selected-band inspector

struct BandInspector: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let i = model.selectedBand, model.working.bands.indices.contains(i) {
            let b = model.working.bands[i]
            HStack(spacing: 18) {
                Eyebrow("Band \(i + 1)", color: UIStyle.accent)
                Picker("", selection: bind(i, \.type)) {
                    ForEach(FilterType.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 150)
                .disabled(model.working.isGraphic31)
                .help(model.working.isGraphic31 ? "Shapes are fixed on the 31-band layout — use the Parametric tab to customise." : "")
                labeled("Freq") { NumberField(value: bind(i, \.frequency), unit: "Hz", step: 1, range: 10...22_000, log: true) }
                    .disabled(model.working.isGraphic31)
                if b.type.usesGain {
                    labeled("Gain") { NumberField(value: bind(i, \.gain), unit: "dB", step: 0.1, range: -24...24, log: false) }
                }
                labeled("Width") {
                    HStack(spacing: 6) {
                        Text("wide").font(UIStyle.mono(9)).foregroundStyle(UIStyle.inkDim)
                        Slider(value: Binding(get: { Foundation.log(min(max(b.q, 0.3), 16)) },
                                              set: { model.working.bands[i].q = (exp($0) * 100).rounded() / 100 }),
                               in: Foundation.log(0.3)...Foundation.log(16.0))
                            .frame(width: 110).controlSize(.small)
                            .disabled(model.working.isGraphic31)
                        Text("narrow").font(UIStyle.mono(9)).foregroundStyle(UIStyle.inkDim)
                    }
                }
                Spacer()
                AppButton(title: "Flat", style: .quiet) { model.setGain(i, 0) }
                Button { model.selectedBand = nil } label: { Image(systemName: "xmark").foregroundStyle(UIStyle.inkDim) }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(UIStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UIStyle.accent.opacity(0.25)))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func labeled<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 6) { Eyebrow(t); c() }
    }

    private func bind<T>(_ i: Int, _ key: WritableKeyPath<EQBand, T>) -> Binding<T> {
        Binding(get: { model.working.bands[i][keyPath: key] },
                set: { if model.working.bands.indices.contains(i) { model.working.bands[i][keyPath: key] = $0 } })
    }
}
