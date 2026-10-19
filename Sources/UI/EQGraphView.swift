import AppKit
import SwiftUI

/// The big picture: the EQ curve over a live spectrum of what's playing, with a draggable
/// handle per band. Drag up/down to boost or cut; on parametric presets drag sideways too.
struct EQGraphView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var live: LiveMeters
    var compact = false

    @State private var dragging: Int?
    @State private var hover: Int?
    @State private var dragStart: (freq: Double, gain: Double)?

    private let minF = 20.0, maxF = 20_000.0
    private var range: Double {
        let maxGain = (model.working.bands.map { abs($0.gain) } + [abs(model.tone.bass), abs(model.tone.air)]).max() ?? 0
        return maxGain > 14 ? 24 : 15
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(&ctx, size) }
                if let i = dragging ?? hover, model.working.bands.indices.contains(i) {
                    readout(i, size)
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(size))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = nearestHandle(to: p, size)
                case .ended: hover = nil
                }
            }
            .onTapGesture(count: 2) {
                if let i = hover ?? model.selectedBand { model.setGain(i, 0) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(UIStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(UIStyle.line))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Mapping

    private func x(_ f: Double, _ w: CGFloat) -> CGFloat { CGFloat(log(f / minF) / log(maxF / minF)) * w }
    private func f(_ x: CGFloat, _ w: CGFloat) -> Double { minF * pow(maxF / minF, Double(x / w)) }
    private func y(_ db: Double, _ h: CGFloat) -> CGFloat { h / 2 - CGFloat(db / range) * (h / 2 - 14) }
    private func db(_ y: CGFloat, _ h: CGFloat) -> Double { Double((h / 2 - y) / (h / 2 - 14)) * range }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height

        // Grid
        let gridFreqs: [Double] = [50, 100, 200, 500, 1000, 2000, 5000, 10_000]
        for gf in gridFreqs {
            var p = Path(); p.move(to: CGPoint(x: x(gf, w), y: 0)); p.addLine(to: CGPoint(x: x(gf, w), y: h))
            ctx.stroke(p, with: .color(UIStyle.line), lineWidth: 1)
            if !compact {
                ctx.draw(Text(Format.hz(gf)).font(UIStyle.mono(9)).foregroundStyle(UIStyle.ink.opacity(0.32)),
                         at: CGPoint(x: x(gf, w) + 3, y: h - 9), anchor: .leading)
            }
        }
        let step = range > 15 ? 6.0 : 5.0
        var g = -range + step
        while g < range {
            var p = Path(); p.move(to: CGPoint(x: 0, y: y(g, h))); p.addLine(to: CGPoint(x: w, y: y(g, h)))
            ctx.stroke(p, with: .color(g == 0 ? UIStyle.ink.opacity(0.22) : UIStyle.line), lineWidth: 1)
            if !compact, g != 0 {
                ctx.draw(Text(Format.db(g).replacingOccurrences(of: ".0", with: "")).font(UIStyle.mono(9)).foregroundStyle(UIStyle.ink.opacity(0.28)),
                         at: CGPoint(x: 6, y: y(g, h) - 7), anchor: .leading)
            }
            g += step
        }

        // Live spectrum
        let spec = live.spectrum
        if spec.count == live.frequencies.count, !spec.isEmpty {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: h))
            for (i, v) in spec.enumerated() {
                let norm = CGFloat(max(0, min(1, (Double(v) + 84) / 84)))
                p.addLine(to: CGPoint(x: x(live.frequencies[i], w), y: h - norm * h * 0.9))
            }
            p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath()
            ctx.fill(p, with: .linearGradient(Gradient(colors: [UIStyle.accent2.opacity(0.22), UIStyle.accent2.opacity(0.03)]),
                                              startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
        }

        // Curves
        let count = max(Int(w / 2), 64)
        let freqs = (0..<count).map { f(CGFloat($0) / CGFloat(count - 1) * w, w) }
        let total = EQResponse.curve(bands: model.working.bands + model.tone.bands, preamp: model.working.preamp, frequencies: freqs)
        let curvePath = path(freqs, total, w, h)

        if !model.tone.isNeutral {
            let presetOnly = EQResponse.curve(bands: model.working.bands, preamp: model.working.preamp, frequencies: freqs)
            ctx.stroke(path(freqs, presetOnly, w, h), with: .color(UIStyle.ink.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
        }

        var fill = curvePath
        fill.addLine(to: CGPoint(x: w, y: y(0, h))); fill.addLine(to: CGPoint(x: 0, y: y(0, h))); fill.closeSubpath()
        let on = model.isOn && !model.comparing
        let tint = on ? UIStyle.accent : UIStyle.ink.opacity(0.5)
        ctx.fill(fill, with: .color(tint.opacity(0.08)))
        var glow = ctx
        glow.addFilter(.blur(radius: 6))
        glow.stroke(curvePath, with: .color(tint.opacity(on ? 0.6 : 0.2)), lineWidth: 4)
        ctx.stroke(curvePath, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

        // Handles
        for (i, b) in model.working.bands.enumerated() where handleVisible(i, b) {
            let p = handlePoint(i, b, size)
            let selected = model.selectedBand == i || dragging == i
            let hot = hover == i
            let r: CGFloat = selected ? 7 : (hot ? 6 : 4.5)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            if selected {
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)), with: .color(UIStyle.accent.opacity(0.18)))
            }
            ctx.fill(Path(ellipseIn: rect), with: .color(selected ? UIStyle.accent : (b.enabled ? UIStyle.bg : UIStyle.surface3)))
            ctx.stroke(Path(ellipseIn: rect), with: .color(b.enabled ? (selected || hot ? UIStyle.accent : UIStyle.ink.opacity(0.75)) : UIStyle.inkFaint),
                       lineWidth: 1.5)
        }
    }

    private func path(_ freqs: [Double], _ gains: [Double], _ w: CGFloat, _ h: CGFloat) -> Path {
        var p = Path()
        for (i, fr) in freqs.enumerated() {
            let pt = CGPoint(x: x(fr, w), y: min(h + 4, max(-4, y(gains[i], h))))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }

    private func handleVisible(_ i: Int, _ b: EQBand) -> Bool {
        b.frequency >= minF * 0.9 && b.frequency <= maxF * 1.05
    }

    private func handlePoint(_ i: Int, _ b: EQBand, _ size: CGSize) -> CGPoint {
        let fx = min(max(b.frequency, minF), maxF)
        let gy = b.type.usesGain ? b.gain : 0
        return CGPoint(x: min(max(x(fx, size.width), 6), size.width - 6), y: y(gy, size.height))
    }

    private func nearestHandle(to p: CGPoint, _ size: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (i, b) in model.working.bands.enumerated() where handleVisible(i, b) {
            let hp = handlePoint(i, b, size)
            let d = hypot(hp.x - p.x, (hp.y - p.y) * 0.6)
            if d < 18, d < (best?.1 ?? .infinity) { best = (i, d) }
        }
        return best?.0
    }

    // MARK: Interaction

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragging == nil {
                    guard let i = nearestHandle(to: v.startLocation, size) else {
                        model.selectedBand = nil
                        return
                    }
                    dragging = i
                    model.selectedBand = i
                    dragStart = (model.working.bands[i].frequency, model.working.bands[i].gain)
                }
                guard let i = dragging, let start = dragStart, model.working.bands.indices.contains(i) else { return }
                var band = model.working.bands[i]
                // Fine control with ⌥ held.
                let fine = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1.0
                if band.type.usesGain {
                    let dy = db(y(start.gain, size.height) + v.translation.height * fine, size.height) - start.gain
                    band.gain = ((start.gain + dy) * 10).rounded() / 10
                    band.gain = min(24, max(-24, band.gain))
                }
                if !model.working.isGraphic31 {
                    let nx = x(start.freq, size.width) + v.translation.width * fine
                    band.frequency = min(maxF, max(minF, f(nx, size.width)))
                    band.frequency = band.frequency < 1000 ? band.frequency.rounded() : (band.frequency / 10).rounded() * 10
                }
                if band != model.working.bands[i] { model.working.bands[i] = band }
            }
            .onEnded { _ in
                dragging = nil
                dragStart = nil
            }
    }

    private func readout(_ i: Int, _ size: CGSize) -> some View {
        let b = model.working.bands[i]
        let p = handlePoint(i, b, size)
        let text = b.type.usesGain ? "\(Format.hz(b.frequency)) Hz  \(Format.db(b.gain)) dB" : "\(b.type.shortLabel) \(Format.hz(b.frequency)) Hz"
        return Text(text)
            .font(UIStyle.mono(10.5, .medium))
            .foregroundStyle(UIStyle.ink)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(UIStyle.surface3))
            .overlay(Capsule().strokeBorder(UIStyle.line))
            .fixedSize()
            .position(x: min(max(p.x, 60), size.width - 60), y: p.y < 34 ? p.y + 24 : p.y - 22)
            .allowsHitTesting(false)
    }
}

/// Plain-English names for parts of the frequency range, so beginners know where to look.
struct FrequencyZones: View {
    private let zones: [(String, Double, Double, String)] = [
        ("Sub-bass", 20, 60, "Rumble you feel more than hear — movie explosions, 808s, organ pedals."),
        ("Bass", 60, 250, "Kick drum and bass guitar. Too much sounds boomy; too little sounds thin."),
        ("Low mids", 250, 500, "Body and warmth. Too much sounds muddy or boxy."),
        ("Mids", 500, 2000, "The core of most instruments and voices. Too much sounds honky."),
        ("Presence", 2000, 6000, "Clarity of voices and attack of guitars. Too much sounds harsh."),
        ("Brilliance", 6000, 20000, "Sparkle, cymbals and ‘air’. Too much sounds hissy or sibilant."),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach(zones, id: \.0) { z in
                    let x0 = pos(z.1) * geo.size.width, x1 = pos(z.2) * geo.size.width
                    Text(z.0.uppercased())
                        .font(UIStyle.mono(9, .medium)).tracking(1.2)
                        .foregroundStyle(UIStyle.ink.opacity(0.4))
                        .frame(width: x1 - x0 - 2, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(UIStyle.surface))
                        .help(z.3)
                        .offset(x: x0 + 1)
                }
            }
        }
        .frame(height: 22)
    }

    private func pos(_ f: Double) -> CGFloat { CGFloat(log(f / 20) / log(1000)) }
}
