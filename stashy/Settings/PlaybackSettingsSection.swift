//
//  PlaybackSettingsSection.swift
//  stashy
//
//  Created by Daniel Goletz on 06.02.26.
//

import SwiftUI

struct PlaybackSettingsSection: View {
    @ObservedObject var appearanceManager = AppearanceManager.shared
    @ObservedObject var configManager = ServerConfigManager.shared
    @ObservedObject var tabManager = TabManager.shared
    @ObservedObject var subtitlePrefs = SubtitlePreferences.shared

    var body: some View {
        Section(header: Text("Playback")) {
            if let config = configManager.activeConfig {
                Picker(selection: Binding(
                    get: { config.defaultQuality },
                    set: { newValue in
                        var updated = config
                        updated.defaultQuality = newValue
                        ServerConfigManager.shared.saveConfig(updated)
                        ServerConfigManager.shared.addOrUpdateServer(updated)
                    }
                )) {
                    ForEach(StreamingQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                } label: {
                    Label("Library Quality", systemImage: "film")
                }

                Picker(selection: Binding(
                    get: { config.reelsQuality },
                    set: { newValue in
                        var updated = config
                        updated.reelsQuality = newValue
                        ServerConfigManager.shared.saveConfig(updated)
                        ServerConfigManager.shared.addOrUpdateServer(updated)
                    }
                )) {
                    ForEach(StreamingQuality.allCases, id: \.self) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                } label: {
                    Label("Feeds Quality", systemImage: "play.rectangle.on.rectangle")
                }
            } else {
                Text("Connect to a server to configure quality settings.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            
            #if !os(tvOS)
            Toggle(isOn: $tabManager.isPiPEnabled) {
                Label("Picture-in-Picture", systemImage: "pip")
            }
            .tint(appearanceManager.tintColor)

            Toggle(isOn: $subtitlePrefs.isEnabled) {
                Label("Subtitles", systemImage: "captions.bubble")
            }
            .tint(appearanceManager.tintColor)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Subtitle Text Size", systemImage: "textformat.size")
                    Spacer()
                    Text("\(Int((subtitlePrefs.textScale * 100).rounded()))%")
                        .foregroundColor(.secondary)
                        .font(.caption.monospacedDigit())
                }
                Slider(
                    value: $subtitlePrefs.textScale,
                    in: SubtitlePreferences.minTextScale...SubtitlePreferences.maxTextScale,
                    step: 0.1
                )
                .tint(appearanceManager.tintColor)
            }

            Toggle(isOn: $subtitlePrefs.showsBackground) {
                Label("Subtitle Background", systemImage: "rectangle.fill")
            }
            .tint(appearanceManager.tintColor)
            #endif
        }
        .listRowBackground(Color.secondaryAppBackground)

    }
}
