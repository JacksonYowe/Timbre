import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Every preset, one click to swap. Drop EQ text files anywhere on it to import.
struct LibrarySidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: PresetLibrary
    @State private var search = ""
    @State private var dropTargeted = false
    @State private var renaming: String?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Timbre").font(UIStyle.serif(30)).foregroundStyle(UIStyle.ink)
                Text(".").font(UIStyle.serif(30)).foregroundStyle(UIStyle.accent)
            }
            .padding(.horizontal, 18).padding(.top, 38).padding(.bottom, 14)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(UIStyle.inkDim)
                TextField("Search presets", text: $search).textFieldStyle(.plain).font(UIStyle.sans(12.5))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(UIStyle.surface2))
            .padding(.horizontal, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let favs = model.favourites.compactMap { library.preset(id: $0) }.filter(matches)
                    if !favs.isEmpty {
                        section("Favourites", trailing: "⌃⌥⌘1–9")
                        ForEach(Array(favs.enumerated()), id: \.element.id) { i, p in row(p, slot: i + 1) }
                    }
                    section("Built in")
                    ForEach(library.builtIns.filter(matches)) { row($0) }

                    section("Your EQ files", trailing: nil, button: ("plus", "Import EQ files…", openImport))
                    let files = library.files.filter(matches)
                    if files.isEmpty && search.isEmpty {
                        emptyFiles
                    }
                    ForEach(files) { row($0) }
                    ForEach(library.fileErrors.sorted(by: { $0.key < $1.key }), id: \.key) { name, why in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(UIStyle.accent3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(UIStyle.sans(12, .semibold)).foregroundStyle(UIStyle.ink)
                                Text(why).font(UIStyle.sans(10.5)).foregroundStyle(UIStyle.inkDim).lineLimit(3)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 20)
            }

            HStack(spacing: 8) {
                AppButton(title: "Import", symbol: "square.and.arrow.down", action: openImport)
                AppButton(title: "Folder", symbol: "folder", style: .quiet) {
                    NSWorkspace.shared.activateFileViewerSelecting([library.folder])
                }
                .help("Open the presets folder. Anything you drop or edit there appears here instantly.")
            }
            .padding(14)
        }
        .frame(width: 236)
        .background(UIStyle.bg)
        .overlay(alignment: .trailing) { Rectangle().fill(UIStyle.line).frame(width: 1) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(UIStyle.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .background(RoundedRectangle(cornerRadius: 14).fill(UIStyle.accent.opacity(0.06)))
                    .overlay(Text("Drop to import").font(UIStyle.sans(14, .bold)).foregroundStyle(UIStyle.accent))
                    .padding(8)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDropped(providers)
            return true
        }
    }

    private var emptyFiles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drop .txt EQ files here").font(UIStyle.sans(12, .semibold)).foregroundStyle(UIStyle.inkDim)
            Text("AutoEQ, EqualizerAPO, Peace, Wavelet and REW exports all work. Find your headphones at autoeq.app.")
                .font(UIStyle.sans(11)).foregroundStyle(UIStyle.ink.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(UIStyle.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        .padding(.horizontal, 4).padding(.vertical, 4)
    }

    private func matches(_ p: EQPreset) -> Bool {
        search.isEmpty || p.name.localizedCaseInsensitiveContains(search)
    }

    private func section(_ title: String, trailing: String? = nil, button: (String, String, () -> Void)? = nil) -> some View {
        HStack {
            Eyebrow(title)
            Spacer()
            if let trailing { Text(trailing).font(UIStyle.mono(9)).foregroundStyle(UIStyle.ink.opacity(0.3)) }
            if let button {
                Button(action: button.2) { Image(systemName: button.0).font(.system(size: 11, weight: .bold)).foregroundStyle(UIStyle.inkDim) }
                    .buttonStyle(.plain).help(button.1)
            }
        }
        .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
    }

    @ViewBuilder
    private func row(_ p: EQPreset, slot: Int? = nil) -> some View {
        let active = p.id == model.activePresetID
        if renaming == p.id {
            TextField("Name", text: $renameText, onCommit: {
                model.renamePreset(p.id, to: renameText)
                renaming = nil
            })
            .textFieldStyle(.plain).font(UIStyle.sans(13)).padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(UIStyle.surface2))
        } else {
            PresetRow(preset: p, active: active, modified: active && model.isModified, slot: slot,
                      favourite: model.favourites.contains(p.id)) {
                withAnimation(UIStyle.ease) { model.select(p.id) }
            }
            .contextMenu {
                Button(model.favourites.contains(p.id) ? "Remove from Favourites" : "Add to Favourites") { model.toggleFavourite(p.id) }
                if p.origin == .file {
                    Button("Rename…") { renameText = p.name; renaming = p.id }
                    Button("Show in Finder") {
                        if let url = library.url(for: p.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Open in Text Editor") {
                        if let url = library.url(for: p.id) { NSWorkspace.shared.open(url) }
                    }
                    Divider()
                    Button("Move to Trash", role: .destructive) { model.deletePreset(p.id) }
                } else {
                    Button("Duplicate as editable file") {
                        model.select(p.id)
                        model.save(as: p.name + " (copy)")
                    }
                }
            }
        }
    }

    private func openImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .text, .data]
        panel.message = "Choose EQ files (EqualizerAPO / AutoEQ ParametricEQ or GraphicEQ .txt, or frequency-gain lists)"
        if panel.runModal() == .OK { model.importFiles(panel.urls) }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { model.importFiles(urls) } }
    }
}

private struct PresetRow: View {
    let preset: EQPreset
    let active: Bool
    let modified: Bool
    let slot: Int?
    let favourite: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MiniCurve(bands: preset.bands, active: active)
                    .frame(width: 34, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(preset.name).font(UIStyle.sans(13, active ? .bold : .medium))
                            .foregroundStyle(active ? UIStyle.ink : UIStyle.ink.opacity(0.82)).lineLimit(1)
                        if modified { Circle().fill(UIStyle.accent2).frame(width: 5, height: 5).help("Edited — not saved yet") }
                    }
                    if hovering, !preset.blurb.isEmpty {
                        Text(preset.blurb).font(UIStyle.sans(10.5)).foregroundStyle(UIStyle.inkDim).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let slot { Text("\(slot)").font(UIStyle.mono(9.5)).foregroundStyle(UIStyle.ink.opacity(0.35)) }
                else if favourite { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(UIStyle.ink.opacity(0.35)) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(active ? UIStyle.surface3 : (hovering ? UIStyle.surface : .clear)))
            .overlay(alignment: .leading) {
                if active { Capsule().fill(UIStyle.accent).frame(width: 3, height: 16).offset(x: -1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(UIStyle.ease) { hovering = h } }
    }
}

/// Tiny sparkline of a preset's curve.
struct MiniCurve: View {
    let bands: [EQBand]
    var active = false
    var body: some View {
        Canvas { ctx, size in
            let n = 24
            let freqs = EQResponse.logFrequencies(count: n)
            let gains = EQResponse.curve(bands: bands, frequencies: freqs)
            var p = Path()
            for i in 0..<n {
                let pt = CGPoint(x: CGFloat(i) / CGFloat(n - 1) * size.width,
                                 y: size.height / 2 - CGFloat(max(-12, min(12, gains[i])) / 12) * size.height / 2)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            ctx.stroke(p, with: .color(active ? UIStyle.accent : UIStyle.ink.opacity(0.45)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
    }
}
