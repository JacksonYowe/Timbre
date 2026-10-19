import SwiftUI

/// What's playing, what Timbre thinks it is, and which preset it chose (and why).
struct NowPlayingCard: View {
    @ObservedObject var model: AppModel
    @State private var genreEdit = ""
    @State private var showingGenreEdit = false

    var body: some View {
        let ctx = model.context
        HStack(spacing: 14) {
            artwork(ctx)
            VStack(alignment: .leading, spacing: 4) {
                if ctx.kind == nil {
                    Text("Nothing playing").font(UIStyle.sans(14, .bold)).foregroundStyle(UIStyle.ink)
                    Text(model.spotifyAccess == .denied
                         ? "Spotify access is off — allow it in System Settings → Privacy & Security → Automation."
                         : "Play something in Spotify (or any app) and Timbre will work out what it is.")
                        .font(UIStyle.sans(11.5)).foregroundStyle(UIStyle.inkDim).lineLimit(2)
                } else {
                    Text(ctx.title.isEmpty ? ctx.appName : ctx.title)
                        .font(UIStyle.sans(14, .bold)).foregroundStyle(UIStyle.ink).lineLimit(1)
                    if !ctx.artist.isEmpty {
                        Text(ctx.artist).font(UIStyle.sans(12)).foregroundStyle(UIStyle.inkDim).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        tag(ctx.kind?.label ?? "", symbol: ctx.kind?.symbol)
                        if ctx.kind == .music {
                            if !ctx.genreLookupDone && ctx.bundleID == SpotifyClient.bundleID {
                                tag("Finding genre…", symbol: "ellipsis")
                            } else if !ctx.genreText.isEmpty {
                                tag(ctx.genreText, symbol: "tag")
                                    .help("Genre family: \(ctx.genreFamily?.label ?? "Other")")
                            } else if ctx.bundleID == SpotifyClient.bundleID {
                                tag("Genre unknown", symbol: "questionmark")
                            }
                        }
                        if !ctx.appName.isEmpty, ctx.title.isEmpty == false { tag(ctx.appName, symbol: nil) }
                    }
                }
            }
            Spacer(minLength: 8)
            autoColumn(ctx)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(UIStyle.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(UIStyle.line))
        .popover(isPresented: $showingGenreEdit) { genrePopover }
    }

    @ViewBuilder
    private func artwork(_ ctx: ListeningContext) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(UIStyle.surface3)
            if let url = URL(string: ctx.artworkURL), !ctx.artworkURL.isEmpty {
                AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
            } else {
                Image(systemName: ctx.kind?.symbol ?? "waveform").font(.system(size: 20)).foregroundStyle(UIStyle.inkDim)
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func autoColumn(_ ctx: ListeningContext) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Text("Auto-switch").font(UIStyle.sans(12, .semibold)).foregroundStyle(UIStyle.ink)
                Toggle("", isOn: $model.autoSwitch).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(UIStyle.accent)
            }
            .help("Pick the EQ automatically from what's playing (⌃⌥⌘A)")
            if model.autoSwitch {
                Text(model.autoReason.isEmpty ? "Waiting for audio" : model.autoReason)
                    .font(UIStyle.sans(11)).foregroundStyle(UIStyle.inkDim).lineLimit(1)
                HStack(spacing: 6) {
                    if model.manualOverride {
                        AppButton(title: "Resume auto", symbol: "arrow.triangle.2.circlepath", style: .quiet) { model.resumeAuto() }
                    }
                    if ctx.kind != nil { teachMenu(ctx) }
                }
            }
        }
    }

    private func teachMenu(_ ctx: ListeningContext) -> some View {
        Menu {
            Section("Always use “\(model.working.name)” for…") {
                if let kind = ctx.kind {
                    Button("All \(kind.label.lowercased())") { model.teachRule(field: .kind, value: kind.rawValue) }
                }
                if let family = ctx.genreFamily {
                    Button("\(family.label) music") { model.teachRule(field: .genreFamily, value: family.rawValue) }
                }
                if !ctx.genreText.isEmpty, ctx.genreText != ctx.genreFamily?.label {
                    Button("Genre “\(ctx.genreText)”") { model.teachRule(field: .genreText, value: ctx.genreText) }
                }
                if !ctx.artist.isEmpty {
                    let artist = GenreLookup.primaryArtist(ctx.artist)
                    Button("Songs by \(artist)") { model.teachRule(field: .artist, value: artist) }
                }
                if !ctx.bundleID.isEmpty {
                    Button("Anything from \(ctx.appName)") { model.teachRule(field: .app, value: ctx.bundleID) }
                }
            }
            if ctx.kind == .music, !ctx.artist.isEmpty {
                Divider()
                Button("Wrong genre? Set it for this artist…") {
                    genreEdit = ctx.genreText
                    showingGenreEdit = true
                }
            }
        } label: {
            Label("Remember this", systemImage: "wand.and.stars").font(UIStyle.sans(11.5, .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Teach Timbre to use the current preset for this kind of audio")
    }

    private var genrePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Genre for \(GenreLookup.primaryArtist(model.context.artist))").font(UIStyle.sans(13, .bold))
            Hint("Timbre will treat every song by this artist as this genre.")
            TextField("e.g. Indie Rock", text: $genreEdit).textFieldStyle(.roundedBorder).frame(width: 220)
            HStack {
                Menu("Pick a family") {
                    ForEach(GenreFamily.allCases.filter { $0 != .other }) { f in Button(f.label) { genreEdit = f.label } }
                }.fixedSize()
                Spacer()
                Button("Clear") { model.setArtistGenre(nil); showingGenreEdit = false }
                Button("Save") { model.setArtistGenre(genreEdit.isEmpty ? nil : genreEdit); showingGenreEdit = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func tag(_ text: String, symbol: String?) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(UIStyle.sans(10.5, .semibold)).lineLimit(1)
        }
        .foregroundStyle(UIStyle.ink.opacity(0.8))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(UIStyle.surface3))
    }
}
