import AppKit
import Foundation

/// What kind of thing is playing right now.
enum ContentKind: String, Codable, CaseIterable, Identifiable {
    case music, podcast, audiobook, video, voiceCall, game, ad, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .music: "Music"
        case .podcast: "Podcast"
        case .audiobook: "Audiobook"
        case .video: "Video & web"
        case .voiceCall: "Voice & video calls"
        case .game: "Games"
        case .ad: "Ads"
        case .other: "Other apps"
        }
    }

    var symbol: String {
        switch self {
        case .music: "music.note"
        case .podcast: "mic"
        case .audiobook: "book"
        case .video: "play.rectangle"
        case .voiceCall: "phone"
        case .game: "gamecontroller"
        case .ad: "megaphone"
        case .other: "app.badge"
        }
    }
}

struct ListeningContext: Equatable {
    var kind: ContentKind?            // nil = nothing playing
    var appName = ""
    var bundleID = ""
    var title = ""
    var artist = ""
    var album = ""
    var trackID = ""
    var artworkURL = ""
    var genreText = ""
    var genreLookupDone = false

    var genreFamily: GenreFamily? {
        guard kind == .music, genreLookupDone, !genreText.isEmpty else { return nil }
        return GenreFamily.classify(genreText)
    }

    /// Changes when the thing being listened to changes (used to end a manual override).
    var identity: String { "\(kind?.rawValue ?? "-")|\(bundleID)|\(trackID)" }
}

/// Watches Spotify (primary) and every other app's audio output, and works out what kind of
/// content is playing plus — for music — its genre.
final class ContentDetector {
    var onChange: ((ListeningContext) -> Void)?
    var onSpotifyAccess: ((SpotifyClient.Access) -> Void)?
    /// User overrides: bundle ID → kind.
    var appKinds: [String: ContentKind] = [:]

    let spotify = SpotifyClient()
    let genres = GenreLookup()

    private(set) var context = ListeningContext() {
        didSet { if context != oldValue { onChange?(context) } }
    }
    private var spotifyNow = SpotifyClient.NowPlaying()
    /// Spotify itself says it's playing (not just holding its output open).
    var spotifyIsPlaying: Bool { spotifyNow.state == .playing }
    private var playingApps: [String] = []
    private var timer: Timer?
    private let scanQueue = DispatchQueue(label: "timbre.apps", qos: .utility)

    func start() {
        spotify.onUpdate = { [weak self] in self?.spotifyNow = $0; self?.recompute() }
        spotify.onBroadcast = { [weak self] now in
            guard let self else { return }
            var merged = now
            if merged.track?.id == self.spotifyNow.track?.id { merged.track?.artworkURL = self.spotifyNow.track?.artworkURL ?? "" }
            self.spotifyNow = merged
            self.recompute()
        }
        spotify.onAccess = { [weak self] in self?.onSpotifyAccess?($0) }
        spotify.start()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.scanApps() }
        scanApps()
    }

    private func scanApps() {
        scanQueue.async { [weak self] in
            let apps = CA.appsPlayingAudio().map { Self.owningApp($0.bundleID) }
            DispatchQueue.main.async {
                guard let self else { return }
                let unique = Array(NSOrderedSet(array: apps)) as? [String] ?? apps
                if unique != self.playingApps {
                    self.playingApps = unique
                    self.recompute()
                }
            }
        }
    }

    /// Helper processes report their own bundle IDs — fold them into the app the user sees.
    static func owningApp(_ bundle: String) -> String {
        let b = bundle
        if b.hasPrefix("com.apple.WebKit") { return "com.apple.Safari" }
        if let r = b.range(of: ".helper", options: .caseInsensitive) { return String(b[..<r.lowerBound]) }
        if b.hasPrefix("com.spotify.client") { return "com.spotify.client" }
        return b
    }

    func recompute() {
        var ctx = ListeningContext()
        let spotifyPlaying = spotifyNow.state == .playing && spotifyNow.track != nil

        let kinds = playingApps.map { ($0, kind(for: $0)) }
        if let call = kinds.first(where: { $0.1 == .voiceCall }) {
            ctx.kind = .voiceCall
            fillApp(&ctx, call.0)
        } else if spotifyPlaying, let track = spotifyNow.track {
            ctx.bundleID = SpotifyClient.bundleID
            ctx.appName = "Spotify"
            ctx.title = track.name
            ctx.artist = track.artist
            ctx.album = track.album
            ctx.trackID = track.id
            ctx.artworkURL = track.artworkURL
            ctx.kind = Self.spotifyKind(id: track.id, override: appKinds[SpotifyClient.bundleID])
        } else if let pick = Self.priority.lazy.compactMap({ k in kinds.first { $0.1 == k } }).first {
            ctx.kind = pick.1
            fillApp(&ctx, pick.0)
        }

        // Keep the genre we already looked up for this track; otherwise ask.
        if ctx.kind == .music, ctx.bundleID == SpotifyClient.bundleID {
            if context.trackID == ctx.trackID {
                ctx.genreText = context.genreText
                ctx.genreLookupDone = context.genreLookupDone
            }
            context = ctx
            if !ctx.genreLookupDone {
                let id = ctx.trackID
                genres.genre(artist: ctx.artist, title: ctx.title) { [weak self] genre in
                    guard let self, self.context.trackID == id else { return }
                    var c = self.context
                    c.genreText = genre
                    c.genreLookupDone = true
                    self.context = c
                }
            }
            return
        }
        context = ctx
    }

    /// Re-run the genre lookup for the current song (after the user changes an override).
    func refreshGenre() {
        var c = context
        c.genreLookupDone = false
        c.genreText = ""
        context = c
        recompute()
    }

    private static let priority: [ContentKind] = [.video, .game, .music, .podcast, .audiobook, .other]

    private func fillApp(_ ctx: inout ListeningContext, _ bundle: String) {
        ctx.bundleID = bundle
        ctx.appName = Self.appName(bundle)
    }

    static func spotifyKind(id: String, override: ContentKind?) -> ContentKind {
        if id.hasPrefix("spotify:episode:") || id.hasPrefix("spotify:show:") { return .podcast }
        if id.hasPrefix("spotify:ad:") { return .ad }
        if id.hasPrefix("spotify:audiobook:") || id.hasPrefix("spotify:chapter:") { return .audiobook }
        return override ?? .music
    }

    func kind(for bundle: String) -> ContentKind {
        if let k = appKinds[bundle] { return k }
        if Self.callApps.contains(bundle) { return .voiceCall }
        if Self.videoApps.contains(bundle) || Self.browsers.contains(bundle) { return .video }
        if Self.musicApps.contains(bundle) { return .music }
        if Self.podcastApps.contains(bundle) { return .podcast }
        if Self.bookApps.contains(bundle) { return .audiobook }
        if Self.isGame(bundle) { return .game }
        return .other
    }

    static func appName(_ bundle: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundle.split(separator: ".").last.map(String.init)?.capitalized ?? bundle
    }

    private static var gameCache: [String: Bool] = [:]
    static func isGame(_ bundle: String) -> Bool {
        if let hit = gameCache[bundle] { return hit }
        var game = false
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle),
           let category = Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String {
            game = category.contains("games")
        }
        if bundle.hasPrefix("com.valvesoftware") || bundle.contains("steam") || bundle.contains("epicgames") { game = true }
        gameCache[bundle] = game
        return game
    }

    static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime", "com.hnc.Discord",
        "com.tinyspeck.slackmacgap", "com.cisco.webexmeetingsapp", "com.webex.meetingmanager", "net.whatsapp.WhatsApp",
        "com.skype.skype", "com.google.meet", "ru.keepcoder.Telegram", "com.apple.TelephonyUtilities",
    ]
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen", "com.kagi.kagimacOS",
    ]
    static let videoApps: Set<String> = [
        "com.apple.TV", "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina", "io.mpv",
        "com.netflix.Netflix", "com.disney.disneyplus", "com.plexapp.plexmediaplayer", "tv.plex.desktop", "com.apple.FinalCut",
        "com.firecore.infuse", "org.jellyfin.JellyfinMediaPlayer",
    ]
    static let musicApps: Set<String> = [
        "com.spotify.client", "com.apple.Music", "com.tidal.desktop", "com.amazon.music", "com.deezer.deezer-desktop",
        "com.qobuz.QobuzDesktop", "com.roon.Roon", "com.apple.iTunes", "com.coppertino.Vox", "com.sonos.macController2",
        "com.ciderapp.Cider", "com.soundcloud.desktop",
    ]
    static let podcastApps: Set<String> = ["com.apple.podcasts", "fm.overcast.overcast", "au.com.shiftyjelly.PocketCasts"]
    static let bookApps: Set<String> = ["com.apple.iBooksX", "com.audible.mac", "com.apple.Books"]
}
