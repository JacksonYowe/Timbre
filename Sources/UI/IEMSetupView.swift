import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Set up custom IEM. Picture of a frequency-response graph in, tuned presets out.
struct IEMSetupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var step = 1
    @State private var image: NSImage?
    @State private var bitmap: GraphTracer.Bitmap?
    @State private var box = CGRect.zero              // plot area, image pixels
    @State private var dragStartBox: CGRect?          // box when the current drag began
    @State private var colour: NSColor?
    @State private var fLow = "20"
    @State private var fHigh = "20000"
    @State private var dbTop = ""
    @State private var dbBottom = ""
    @State private var trace: [CGPoint] = []
    @State private var name = ""
    @State private var target: IEMTarget = .neutral
    @State private var useForAuto = true
    @State private var dropping = false
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch step {
            case 1: pickImage
            case 2: calibrate
            default: finish
            }
        }
        .padding(28)
        .frame(width: 860, height: 700)
        .background(UIStyle.bg)
        .preferredColorScheme(.dark)
        .tint(UIStyle.accent)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("Set up custom IEM · step \(step) of 3")
                Text(["Add a picture of the graph", "Line up the graph", "Make it sound right"][step - 1])
                    .font(UIStyle.serif(32)).foregroundStyle(UIStyle.ink)
            }
            Spacer()
            AppButton(title: "Cancel", style: .quiet) { dismiss() }
        }
    }

    // MARK: Step 1

    private var pickImage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Hint("Find your IEMs' frequency-response graph — on squig.link, a review site, or the box — and take a screenshot (⇧⌘4). One line on the graph should be your IEMs.")
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(UIStyle.accent)
                Text("Drop the graph picture here").font(UIStyle.sans(16, .bold)).foregroundStyle(UIStyle.ink)
                HStack {
                    AppButton(title: "Choose picture…", symbol: "folder", style: .primary, action: choose)
                    AppButton(title: "Paste screenshot", symbol: "doc.on.clipboard") {
                        if let img = NSImage(pasteboard: .general) { load(img) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 18).fill(dropping ? UIStyle.accent.opacity(0.06) : UIStyle.surface))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(dropping ? UIStyle.accent : UIStyle.line, style: StrokeStyle(lineWidth: 1.5, dash: [7, 6])))
            .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
                guard let p = providers.first else { return false }
                if p.canLoadObject(ofClass: NSImage.self) {
                    _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                        if let img = img as? NSImage { DispatchQueue.main.async { load(img) } }
                    }
                } else {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url, let img = NSImage(contentsOf: url) { DispatchQueue.main.async { load(img) } }
                    }
                }
                return true
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) { load(img) }
    }

    private func load(_ img: NSImage) {
        guard let bmp = GraphTracer.bitmap(img) else { return }
        image = img
        bitmap = bmp
        let w = CGFloat(bmp.width), h = CGFloat(bmp.height)
        box = CGRect(x: w * 0.1, y: h * 0.1, width: w * 0.8, height: h * 0.75)
        colour = GraphTracer.dominantColour(bmp, in: box)
        retrace()
        step = 2
    }

    // MARK: Step 2

    private var calibrate: some View {
        HStack(alignment: .top, spacing: 18) {
            GeometryReader { geo in
                if let image, let bitmap {
                    let s = min(geo.size.width / CGFloat(bitmap.width), geo.size.height / CGFloat(bitmap.height))
                    let o = CGPoint(x: (geo.size.width - CGFloat(bitmap.width) * s) / 2, y: (geo.size.height - CGFloat(bitmap.height) * s) / 2)
                    let toView = { (p: CGPoint) in CGPoint(x: o.x + p.x * s, y: o.y + p.y * s) }
                    let toImage = { (p: CGPoint) in CGPoint(x: (p.x - o.x) / s, y: (p.y - o.y) / s) }
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: CGFloat(bitmap.width) * s, height: CGFloat(bitmap.height) * s)
                            .offset(x: o.x, y: o.y)
                            .onTapGesture(coordinateSpace: .local) { loc in
                                let p = toImage(CGPoint(x: loc.x + o.x, y: loc.y + o.y))
                                pickColour(at: p)
                            }
                        let viewBox = CGRect(origin: toView(box.origin), size: CGSize(width: box.width * s, height: box.height * s))
                        Rectangle()
                            .stroke(UIStyle.accent2, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            .frame(width: viewBox.width, height: viewBox.height)
                            .contentShape(Rectangle().stroke(lineWidth: 14))   // grab anywhere along the dotted edge
                            .position(x: viewBox.midX, y: viewBox.midY)
                            .onHover { inside in inside ? NSCursor.openHand.push() : NSCursor.pop() }
                            .gesture(DragGesture(coordinateSpace: .named("graph")).onChanged { g in
                                let start = dragStartBox ?? box
                                dragStartBox = start
                                box = start.offsetBy(dx: g.translation.width / s, dy: g.translation.height / s)
                            }.onEnded { _ in dragStartBox = nil; retrace() })
                        Path { path in
                            for (i, p) in trace.enumerated() { i == 0 ? path.move(to: toView(p)) : path.addLine(to: toView(p)) }
                        }
                        .stroke(UIStyle.accent, lineWidth: 2.5)
                        .shadow(color: .black, radius: 2)
                        .allowsHitTesting(false)
                        ForEach(0..<4, id: \.self) { corner in
                            handle(corner, toView: toView, scale: s)
                        }
                    }
                    .coordinateSpace(name: "graph")
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.03)))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 14) {
                Hint("1. Drag the four purple corners onto the edges of the graph's grid. Drag the dotted edge to move the whole box.")
                Hint("2. Type the numbers printed at those edges.")
                HStack {
                    field("Left edge (Hz)", $fLow)
                    field("Right edge (Hz)", $fHigh)
                }
                HStack {
                    field("Top edge (dB)", $dbTop)
                    field("Bottom edge (dB)", $dbBottom)
                }
                Hint("3. Click your IEMs' line in the picture so Timbre knows which colour to follow. The cyan line shows what it found.")
                HStack(spacing: 8) {
                    Circle().fill(Color(nsColor: colour ?? .gray)).frame(width: 18, height: 18).overlay(Circle().strokeBorder(UIStyle.line))
                    Text(trace.isEmpty ? "Line not found yet — click it" : "Following this colour (\(trace.count) points)")
                        .font(UIStyle.sans(12)).foregroundStyle(trace.isEmpty ? UIStyle.accent3 : UIStyle.inkDim)
                }
                Spacer()
                HStack {
                    AppButton(title: "Back", style: .quiet) { step = 1 }
                    Spacer()
                    AppButton(title: "Next", symbol: "arrow.right", style: .primary) { step = 3 }
                        .disabled(measured.count < 20)
                        .opacity(measured.count < 20 ? 0.4 : 1)
                }
            }
            .frame(width: 270)
        }
        .onChange(of: fLow) { _, _ in retrace() }
        .onChange(of: fHigh) { _, _ in retrace() }
    }

    private func handle(_ corner: Int, toView: @escaping (CGPoint) -> CGPoint, scale s: CGFloat) -> some View {
        let pt = CGPoint(x: corner % 2 == 0 ? box.minX : box.maxX, y: corner < 2 ? box.minY : box.maxY)
        let v = toView(pt)
        return Circle().fill(UIStyle.accent2).frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(UIStyle.bg, lineWidth: 2))
            .position(v)
            .gesture(DragGesture(coordinateSpace: .named("graph")).onChanged { g in
                // Measure from where the drag started, so the corner stays under the pointer.
                let start = dragStartBox ?? box
                dragStartBox = start
                let origin = CGPoint(x: corner % 2 == 0 ? start.minX : start.maxX, y: corner < 2 ? start.minY : start.maxY)
                let nx = origin.x + g.translation.width / s, ny = origin.y + g.translation.height / s
                var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
                if corner % 2 == 0 { minX = min(nx, maxX - 20) } else { maxX = max(nx, minX + 20) }
                if corner < 2 { minY = min(ny, maxY - 20) } else { maxY = max(ny, minY + 20) }
                box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }.onEnded { _ in dragStartBox = nil; retrace() })
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(label)
            TextField("", text: text).textFieldStyle(.roundedBorder).font(UIStyle.mono(12))
        }
    }

    private func pickColour(at p: CGPoint) {
        guard let bitmap, p.x >= 0, p.y >= 0, Int(p.x) < bitmap.width, Int(p.y) < bitmap.height else { return }
        // Look in a small neighbourhood for the most saturated pixel (lines are thin).
        var best: (Double, NSColor)?
        for dy in -4...4 { for dx in -4...4 {
            let x = Int(p.x) + dx, y = Int(p.y) + dy
            guard x >= 0, y >= 0, x < bitmap.width, y < bitmap.height else { continue }
            let (r, g, b) = bitmap.rgb(x, y)
            let sat = max(r, g, b) - min(r, g, b) + (255 - (r + g + b) / 3) * 0.3
            if sat > (best?.0 ?? -1) { best = (sat, NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)) }
        } }
        colour = best?.1
        retrace()
    }

    private func retrace() {
        guard let bitmap, let colour else { trace = []; return }
        trace = GraphTracer.trace(bitmap, in: box.insetBy(dx: 2, dy: 2), colour: colour)
    }

    private var measured: [(Double, Double)] {
        guard let lo = Double(fLow), let hi = Double(fHigh), let top = Double(dbTop), let bottom = Double(dbBottom), top != bottom else { return [] }
        return GraphTracer.response(trace, box: box, fLow: lo, fHigh: hi, dbTop: top, dbBottom: bottom)
    }

    // MARK: Step 3

    private var finish: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    field("IEM name", $name)
                    Eyebrow("Make them sound")
                    Picker("", selection: $target) { ForEach(IEMTarget.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.radioGroup).labelsHidden()
                    Hint(target.explanation)
                    Toggle(isOn: $useForAuto) {
                        Text("Use for Flat, favourites and every auto-switch preset").font(UIStyle.sans(12.5)).foregroundStyle(UIStyle.ink)
                    }
                }
                .frame(width: 290)
                CorrectionPreview(measured: measured, target: target)
                    .frame(maxWidth: .infinity).frame(height: 330)
            }
            if let result { Text(result).font(UIStyle.sans(13, .semibold)).foregroundStyle(UIStyle.accent) }
            Spacer()
            HStack {
                AppButton(title: "Back", style: .quiet) { step = 2; result = nil }
                Spacer()
                if result == nil {
                    AppButton(title: "Create presets", symbol: "wand.and.stars", style: .primary, action: create)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                } else {
                    AppButton(title: "Done", style: .primary) { dismiss() }
                }
            }
        }
    }

    private func create() {
        do {
            let r = try model.setUpIEM(name: name, measured: measured, target: target, useForAutoSwitch: useForAuto)
            result = String(format: "Made %d presets for %@ — within %.1f dB of the target. %@", r.created, name, r.residual,
                            useForAuto ? "Flat and auto-switch now use them." : "Find them under Your EQ files.")
        } catch {
            result = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Measured vs target vs corrected, for the last wizard step.
private struct CorrectionPreview: View {
    let measured: [(Double, Double)]
    let target: IEMTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Canvas { ctx, size in
                let w = size.width, h = size.height - 18
                let freqs = EQResponse.logFrequencies(count: 160)
                let sorted = measured.sorted { $0.0 < $1.0 }
                guard sorted.count > 2 else { return }
                let m = freqs.map { GraphicFit.interpolate(sorted, at: $0) }
                let t = freqs.map { target.value(at: $0) }
                let eq = EQResponse.curve(bands: IEMCorrection.bands(measured: sorted, target: target), frequencies: freqs)
                let mids = freqs.indices.filter { freqs[$0] > 300 && freqs[$0] < 3000 }
                let off = mids.map { t[$0] - m[$0] }.reduce(0, +) / Double(mids.count)
                let mm = m.map { $0 + off }
                let heard = zip(mm, eq).map { $0 + $1 }
                let all = mm + t + heard
                let lo = (all.min()! / 5).rounded(.down) * 5 - 5, hi = (all.max()! / 5).rounded(.up) * 5 + 5
                func x(_ f: Double) -> CGFloat { CGFloat(log(f / 20) / log(1000)) * w }
                func y(_ d: Double) -> CGFloat { h - CGFloat((d - lo) / (hi - lo)) * h }
                for gf in [100.0, 1000, 10_000] {
                    var p = Path(); p.move(to: CGPoint(x: x(gf), y: 0)); p.addLine(to: CGPoint(x: x(gf), y: h))
                    ctx.stroke(p, with: .color(UIStyle.line))
                    ctx.draw(Text(Format.hz(gf)).font(UIStyle.mono(9)).foregroundStyle(UIStyle.ink.opacity(0.35)), at: CGPoint(x: x(gf), y: h + 9))
                }
                func line(_ v: [Double]) -> Path {
                    var p = Path()
                    for i in freqs.indices { let pt = CGPoint(x: x(freqs[i]), y: y(v[i])); i == 0 ? p.move(to: pt) : p.addLine(to: pt) }
                    return p
                }
                ctx.stroke(line(mm), with: .color(UIStyle.ink.opacity(0.55)), lineWidth: 1.6)
                ctx.stroke(line(t), with: .color(UIStyle.accent2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                ctx.stroke(line(heard), with: .color(UIStyle.accent), lineWidth: 2.2)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(UIStyle.surface))
            HStack(spacing: 14) {
                key(UIStyle.ink.opacity(0.55), "Your IEMs (traced)")
                key(UIStyle.accent2, "Target")
                key(UIStyle.accent, "With Timbre")
            }
        }
    }

    private func key(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) { Capsule().fill(c).frame(width: 16, height: 3); Text(t).font(UIStyle.sans(11)).foregroundStyle(UIStyle.inkDim) }
    }
}
