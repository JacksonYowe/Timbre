import Foundation

/// "When ___ is playing, use ___." Rules are checked top to bottom; the first match wins.
struct AutoRule: Codable, Identifiable, Hashable {
    enum Field: String, Codable, CaseIterable, Identifiable {
        case kind, genreFamily, genreText, artist, app

        var id: String { rawValue }

        var label: String {
            switch self {
            case .kind: "Type of audio is"
            case .genreFamily: "Genre is"
            case .genreText: "Genre name contains"
            case .artist: "Artist is"
            case .app: "App is"
            }
        }
    }

    var id = UUID()
    var enabled = true
    var field: Field
    var value: String
    var presetID: String

    func matches(_ ctx: ListeningContext) -> Bool {
        guard enabled, let kind = ctx.kind else { return false }
        switch field {
        case .kind:
            return kind.rawValue == value
        case .genreFamily:
            return ctx.genreFamily?.rawValue == value
        case .genreText:
            return kind == .music && !value.isEmpty && ctx.genreText.localizedCaseInsensitiveContains(value)
        case .artist:
            return !value.isEmpty && GenreLookup.norm(ctx.artist).contains(GenreLookup.norm(value))
        case .app:
            return ctx.bundleID == value
        }
    }

    /// Plain-English summary, e.g. "Rock music → Rock".
    func describe(presetName: String) -> String {
        "\(conditionText) → \(presetName)"
    }

    var conditionText: String {
        switch field {
        case .kind: (ContentKind(rawValue: value)?.label ?? value)
        case .genreFamily: "\(GenreFamily(rawValue: value)?.label ?? value) music"
        case .genreText: "Genre contains “\(value)”"
        case .artist: value
        case .app: ContentDetector.appName(value)
        }
    }

    static let defaults: [AutoRule] = [
        AutoRule(field: .kind, value: ContentKind.voiceCall.rawValue, presetID: "builtin:voice"),
        AutoRule(field: .kind, value: ContentKind.podcast.rawValue, presetID: "builtin:voice"),
        AutoRule(field: .kind, value: ContentKind.audiobook.rawValue, presetID: "builtin:voice"),
        AutoRule(field: .kind, value: ContentKind.video.rawValue, presetID: "builtin:movie"),
        AutoRule(field: .kind, value: ContentKind.game.rawValue, presetID: "builtin:movie"),
        AutoRule(field: .genreFamily, value: GenreFamily.rock.rawValue, presetID: "builtin:rock"),
        AutoRule(field: .genreFamily, value: GenreFamily.metal.rawValue, presetID: "builtin:rock"),
        AutoRule(field: .genreFamily, value: GenreFamily.hipHop.rawValue, presetID: "builtin:hiphop"),
        AutoRule(field: .genreFamily, value: GenreFamily.electronic.rawValue, presetID: "builtin:electronic"),
        AutoRule(field: .genreFamily, value: GenreFamily.pop.rawValue, presetID: "builtin:pop"),
        AutoRule(field: .genreFamily, value: GenreFamily.rnb.rawValue, presetID: "builtin:hiphop"),
        AutoRule(field: .genreFamily, value: GenreFamily.latin.rawValue, presetID: "builtin:pop"),
        AutoRule(field: .genreFamily, value: GenreFamily.jazz.rawValue, presetID: "builtin:classical"),
        AutoRule(field: .genreFamily, value: GenreFamily.classical.rawValue, presetID: "builtin:classical"),
        AutoRule(field: .genreFamily, value: GenreFamily.acoustic.rawValue, presetID: "builtin:acoustic"),
        AutoRule(field: .genreFamily, value: GenreFamily.country.rawValue, presetID: "builtin:acoustic"),
        AutoRule(field: .genreFamily, value: GenreFamily.soundtrack.rawValue, presetID: "builtin:movie"),
    ]
}
