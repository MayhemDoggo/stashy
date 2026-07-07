//
//  SubtitlePreferences.swift
//  stashy
//
//  Global, persisted user preferences for subtitle rendering. Read by the
//  subtitle overlay renderer; written by the Settings UI and the in-player
//  toggle. Preferences are global (not per-server) and remembered across
//  scenes and launches.
//

import SwiftUI
import Combine

final class SubtitlePreferences: ObservableObject {
    static let shared = SubtitlePreferences()

    /// Bounds for the caption text-size multiplier.
    static let minTextScale = 0.7
    static let maxTextScale = 1.8

    /// Whether subtitles are shown when a track is available. Defaults to off;
    /// the in-player toggle updates it and the choice is remembered.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }

    /// Preferred caption language code (e.g. "en"). When it matches an available
    /// track the player selects it automatically; empty means "first available".
    @Published var preferredLanguageCode: String {
        didSet { defaults.set(preferredLanguageCode, forKey: Keys.language) }
    }

    /// Multiplier applied to the base caption font size.
    @Published var textScale: Double {
        didSet {
            let clamped = min(max(textScale, Self.minTextScale), Self.maxTextScale)
            if clamped != textScale { textScale = clamped; return }
            defaults.set(textScale, forKey: Keys.textScale)
        }
    }

    /// Whether to draw the translucent background pad behind cue text.
    @Published var showsBackground: Bool {
        didSet { defaults.set(showsBackground, forKey: Keys.showsBackground) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let enabled = "subtitles.enabled"
        static let language = "subtitles.preferredLanguage"
        static let textScale = "subtitles.textScale"
        static let showsBackground = "subtitles.showsBackground"
    }

    private init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)  // default false
        preferredLanguageCode = defaults.string(forKey: Keys.language) ?? ""

        let storedScale = defaults.double(forKey: Keys.textScale)
        textScale = storedScale == 0 ? 1.0 : min(max(storedScale, Self.minTextScale), Self.maxTextScale)

        // Background defaults to on when never set.
        showsBackground = defaults.object(forKey: Keys.showsBackground) == nil
            ? true
            : defaults.bool(forKey: Keys.showsBackground)
    }
}
