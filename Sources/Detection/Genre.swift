import Foundation

/// Broad genre families — what rules match on. The raw genre text (e.g. "Alternative Folk")
/// is also kept so power users can match on it directly.
enum GenreFamily: String, Codable, CaseIterable, Identifiable {
    case pop, rock, metal, hipHop, electronic, rnb, jazz, classical, acoustic, country, latin, soundtrack, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pop: "Pop"
        case .rock: "Rock"
        case .metal: "Metal"
        case .hipHop: "Hip-Hop & Rap"
        case .electronic: "Electronic & Dance"
        case .rnb: "R&B & Soul"
        case .jazz: "Jazz & Blues"
        case .classical: "Classical"
        case .acoustic: "Acoustic & Folk"
        case .country: "Country"
        case .latin: "Latin"
        case .soundtrack: "Soundtrack"
        case .other: "Other"
        }
    }

    /// Ordered — the first family whose keyword appears wins ("Pop Punk" → rock via "punk").
    private static let keywords: [(GenreFamily, [String])] = [
        (.metal, ["metal", "metalcore", "deathcore", "grindcore", "djent"]),
        (.hipHop, ["hip-hop", "hip hop", "rap", "trap", "drill", "grime", "boom bap"]),
        (.electronic, ["electronic", "dance", "edm", "house", "techno", "trance", "dubstep", "drum & bass",
                       "drum and bass", "dnb", "electro", "garage", "ambient", "idm", "synthwave", "breakbeat", "hardstyle", "phonk"]),
        (.rnb, ["r&b", "rnb", "soul", "funk", "motown", "neo-soul", "gospel"]),
        (.jazz, ["jazz", "blues", "swing", "bebop", "bossa"]),
        (.classical, ["classical", "opera", "orchestral", "baroque", "romantic era", "chamber", "symphon", "piano"]),
        (.country, ["country", "americana", "bluegrass"]),
        (.latin, ["latin", "reggaeton", "salsa", "bachata", "cumbia", "urbano", "latino", "mpb", "samba", "flamenco"]),
        (.soundtrack, ["soundtrack", "score", "film", "anime", "video game", "musical", "cinematic"]),
        (.acoustic, ["folk", "acoustic", "singer/songwriter", "singer-songwriter", "indie folk", "celtic", "world"]),
        (.rock, ["rock", "punk", "grunge", "alternative", "indie", "emo", "shoegaze", "britpop", "hardcore"]),
        (.pop, ["pop", "k-pop", "j-pop", "dance pop", "teen", "disco"]),
    ]

    static func classify(_ text: String) -> GenreFamily {
        let t = text.lowercased()
        guard !t.isEmpty else { return .other }
        for (family, words) in keywords where words.contains(where: { t.contains($0) }) { return family }
        return .other
    }
}

/// Spotify's app doesn't expose genres, so Timbre asks Apple's public iTunes Search API
/// (no account or key needed) and caches the answer. Users can override any artist.
final class GenreLookup {
    private let defaults = UserDefaults.standard
    private let cacheKey = "genreCache.v1"
    private let overrideKey = "artistGenreOverrides.v1"
    private var cache: [String: String]
    private var inFlight: Set<String> = []

    var enabled = true

    init() {
        cache = defaults.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
    }

    var artistOverrides: [String: String] {
        get { defaults.dictionary(forKey: overrideKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: overrideKey) }
    }

    func setOverride(artist: String, genre: String?) {
        var o = artistOverrides
        o[Self.norm(artist)] = genre
        artistOverrides = o
    }

    func override(for artist: String) -> String? { artistOverrides[Self.norm(artist)] }

    /// Calls back on the main queue with the genre text ("" when unknown).
    func genre(artist: String, title: String, completion: @escaping (String) -> Void) {
        let primaryArtist = Self.primaryArtist(artist)
        if let o = override(for: primaryArtist) ?? override(for: artist) { return completion(o) }
        let key = Self.norm(primaryArtist) + "|" + Self.norm(title)
        if let hit = cache[key] { return completion(hit) }
        if inFlight.contains(key) { return }   // the request already running will answer
        guard enabled, !primaryArtist.isEmpty else {
            return completion(cache[Self.norm(primaryArtist) + "|*"] ?? "")
        }
        inFlight.insert(key)

        let cleanedTitle = Self.cleanTitle(title)
        search(term: "\(primaryArtist) \(cleanedTitle)", entity: "song", artist: primaryArtist) { [weak self] songGenre, answered in
            guard let self else { return }
            guard answered else {   // offline: answer from what we know, don't remember a blank
                self.inFlight.remove(key)
                completion(self.cache[Self.norm(primaryArtist) + "|*"] ?? "")
                return
            }
            if let songGenre {
                self.store(songGenre, key: key, artistKey: Self.norm(primaryArtist) + "|*")
                completion(songGenre)
                return
            }
            // Song not on Apple Music — fall back to the artist's main genre.
            self.search(term: primaryArtist, entity: "musicArtist", artist: primaryArtist) { artistGenre, answered in
                let g = artistGenre ?? self.cache[Self.norm(primaryArtist) + "|*"] ?? ""
                guard answered else { self.inFlight.remove(key); completion(g); return }
                self.store(g, key: key, artistKey: artistGenre != nil ? Self.norm(primaryArtist) + "|*" : nil)
                completion(g)
            }
        }
    }

    private func store(_ genre: String, key: String, artistKey: String?) {
        inFlight.remove(key)
        cache[key] = genre
        if let artistKey, !genre.isEmpty { cache[artistKey] = genre }
        if cache.count > 4000 { cache = Dictionary(uniqueKeysWithValues: cache.suffix(3000).map { ($0.key, $0.value) }) }
        defaults.set(cache, forKey: cacheKey)
    }

    /// `answered` is false when the request itself failed (offline) — those results aren't cached.
    private func search(term: String, entity: String, artist: String, completion: @escaping (String?, Bool) -> Void) {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: term),
            .init(name: "media", value: "music"),
            .init(name: "entity", value: entity),
            .init(name: "limit", value: "8"),
        ]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { data, response, _ in
            var result: String?
            let answered = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if answered, let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["results"] as? [[String: Any]] {
                let wanted = Self.norm(artist)
                let match = items.first { item in
                    let name = Self.norm(item["artistName"] as? String ?? "")
                    return !name.isEmpty && !wanted.isEmpty && (name.contains(wanted) || wanted.contains(name))
                }
                result = match?["primaryGenreName"] as? String
            }
            DispatchQueue.main.async { completion(result, answered) }
        }.resume()
    }

    static func norm(_ s: String) -> String {
        s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Artist A, Artist B" / "A feat. B" → "Artist A".
    static func primaryArtist(_ s: String) -> String {
        var a = s
        for sep in [",", " feat.", " ft.", " featuring ", " & ", " x ", " with "] {
            if let r = a.range(of: sep, options: .caseInsensitive) { a = String(a[..<r.lowerBound]) }
        }
        return a.trimmingCharacters(in: .whitespaces)
    }

    /// Drop "(Remastered 2011)", "- Live", "[feat. X]" so the search matches.
    static func cleanTitle(_ s: String) -> String {
        var t = s
        for open in ["(", "["] { if let r = t.range(of: open) { t = String(t[..<r.lowerBound]) } }
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
