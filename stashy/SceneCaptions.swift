//
//  SceneCaptions.swift
//  stashy
//
//  Fetching and resolution of a scene's sidecar caption tracks, and loading a
//  chosen track's WebVTT payload into a parsed `SubtitleTrack` for rendering.
//
//  Caption tracks are fetched on demand (mirroring `fetchSceneStreams`) rather
//  than threaded through the `Scene` model, since the list rarely changes and
//  is only needed once the player opens.
//

import Foundation

// MARK: - GraphQL decoding

/// Decodes `sceneCaptions.graphql`: the available caption tracks plus the base
/// caption URL for a scene.
struct SceneCaptionsResponse: Codable {
    let data: SceneCaptionsData?
}

struct SceneCaptionsData: Codable {
    let findScene: SceneCaptionsScene?
}

struct SceneCaptionsScene: Codable {
    let paths: SceneCaptionsPaths?
    let captions: [SceneCaption]?
}

struct SceneCaptionsPaths: Codable {
    let caption: String?
}

/// One caption entry as reported by Stash (`Scene.captions`).
struct SceneCaption: Codable, Equatable {
    let language_code: String?
    let caption_type: String?
}

// MARK: - Resolved track

/// An available subtitle track resolved to a fetchable URL.
struct CaptionTrack: Identifiable, Equatable {
    let languageCode: String
    let captionType: String
    /// Fetchable URL for the caption payload (before apikey signing).
    let url: URL

    var id: String { "\(languageCode).\(captionType)" }

    /// Human-readable language label for a picker; falls back to the raw code.
    var displayName: String {
        if languageCode.isEmpty || languageCode.lowercased() == "und" { return "Unknown" }
        return Locale(identifier: "en").localizedString(forLanguageCode: languageCode)
            ?? languageCode.uppercased()
    }

    /// Build the tracks for a scene from its base caption path and caption list.
    /// Stash serves a specific caption at `<base>?lang=<code>&type=<type>`; any
    /// query already present on the base URL (e.g. an apikey) is preserved.
    static func tracks(base: String?, captions: [SceneCaption]?) -> [CaptionTrack] {
        guard let base, let captions, !captions.isEmpty,
              let comps = URLComponents(string: base) else { return [] }
        let existing = comps.queryItems ?? []

        return captions.compactMap { caption in
            let lang = caption.language_code ?? ""
            let type = caption.caption_type ?? "vtt"
            var built = comps
            built.queryItems = existing + [
                URLQueryItem(name: "lang", value: lang),
                URLQueryItem(name: "type", value: type)
            ]
            guard let url = built.url else { return nil }
            return CaptionTrack(languageCode: lang, captionType: type, url: url)
        }
    }
}

// MARK: - Loading + parsing

/// Downloads a caption track and parses it into a `SubtitleTrack`.
///
/// Applies Stash apikey auth (query param via `signedURL` + `ApiKey` header),
/// consistent with the app's other authenticated media requests. WebVTT is the
/// supported format; a track that fails to parse resolves to `nil` rather than
/// surfacing an error.
enum SubtitleLoader {
    /// Small in-memory cache keyed by absolute URL. Caption files are tiny and
    /// stable for a session, while the player may re-request on every open/toggle.
    private static var cache: [String: SubtitleTrack] = [:]
    private static let cacheQueue = DispatchQueue(label: "SubtitleLoader.cache")

    static func load(_ track: CaptionTrack, completion: @escaping (SubtitleTrack?) -> Void) {
        let key = track.url.absoluteString
        if let hit = cacheQueue.sync(execute: { cache[key] }) {
            DispatchQueue.main.async { completion(hit) }
            return
        }

        let requestURL = signedURL(track.url) ?? track.url
        var request = URLRequest(url: requestURL)
        if let config = ServerConfigManager.shared.loadConfig(),
           let apiKey = config.secureApiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "ApiKey")
        }

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data, let text = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let parsed = WebVTTParser.parse(text)
            let result: SubtitleTrack? = parsed.isEmpty ? nil : parsed
            if let result {
                cacheQueue.sync { cache[key] = result }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}
