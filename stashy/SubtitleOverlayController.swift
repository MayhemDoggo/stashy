//
//  SubtitleOverlayController.swift
//  stashy
//
//  Renders subtitle cues as a styled UIKit overlay above video, driven by an
//  AVPlayer's playback time. Designed to live in
//  `AVPlayerViewController.contentOverlayView` so it sits above the video and
//  below the transport controls, and follows fullscreen automatically on both
//  iOS and tvOS.
//

import UIKit
import SwiftUI
import AVFoundation
import Combine

/// A UILabel that draws a padded, rounded translucent background behind its text.
final class SubtitleCueLabel: UILabel {
    var contentInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 0
        textAlignment = .center
        isUserInteractionEnabled = false
        layer.cornerRadius = 6
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }

    override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(width: base.width + contentInsets.left + contentInsets.right,
                      height: base.height + contentInsets.top + contentInsets.bottom)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let insetBounds = bounds.inset(by: contentInsets)
        let rect = super.textRect(forBounds: insetBounds, limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(top: -contentInsets.top, left: -contentInsets.left,
                                           bottom: -contentInsets.bottom, right: -contentInsets.right))
    }
}

final class SubtitleOverlayController {
    /// Add this into `AVPlayerViewController.contentOverlayView`.
    let containerView: UIView

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var track: SubtitleTrack?
    private var lastRenderKey = ""

    private let topLabel = SubtitleCueLabel()
    private let bottomLabel = SubtitleCueLabel()

    private let prefs = SubtitlePreferences.shared
    private var cancellables = Set<AnyCancellable>()

    /// Base caption font size before the user's text-scale multiplier.
    private var baseFontSize: CGFloat {
        #if os(tvOS)
        return 40
        #else
        return 22
        #endif
    }

    init(player: AVPlayer) {
        self.player = player
        containerView = UIView()
        containerView.isUserInteractionEnabled = false
        containerView.backgroundColor = .clear
        setupLabels()
        addTimeObserver()

        // Re-render on live preference changes (e.g. toggling background while paused).
        prefs.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.lastRenderKey = ""
                self?.renderCurrent()
            }
            .store(in: &cancellables)
    }

    deinit { removeTimeObserver() }

    // MARK: Setup

    private func setupLabels() {
        for label in [topLabel, bottomLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isHidden = true
            containerView.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: containerView.widthAnchor, multiplier: 0.9)
            ])
        }
        let margin: CGFloat = 40
        NSLayoutConstraint.activate([
            topLabel.topAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.topAnchor, constant: margin),
            bottomLabel.bottomAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.bottomAnchor, constant: -margin)
        ])
    }

    // MARK: Track control

    /// Set the active parsed track (or nil to hide subtitles).
    func setTrack(_ track: SubtitleTrack?) {
        self.track = track
        lastRenderKey = ""
        renderCurrent()
    }

    // MARK: Time-driven rendering

    private func addTimeObserver() {
        guard let player else { return }
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.renderCurrent()
        }
    }

    private func removeTimeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func renderCurrent() {
        guard let track, let player else {
            hideAll(key: "")
            return
        }
        let time = player.currentTime().seconds
        guard time.isFinite else { return }

        let active = track.activeCues(at: time)
        let topCues = active.filter { $0.placement == .top }
        let bottomCues = active.filter { $0.placement == .bottom }

        // Skip work when nothing changed since the last tick.
        let key = "\(topCues.map(\.plainText).joined(separator: "\u{1}"))|\(bottomCues.map(\.plainText).joined(separator: "\u{1}"))|\(prefs.textScale)|\(prefs.showsBackground)"
        if key == lastRenderKey { return }
        lastRenderKey = key

        apply(cues: topCues, to: topLabel)
        apply(cues: bottomCues, to: bottomLabel)
    }

    private func hideAll(key: String) {
        lastRenderKey = key
        topLabel.isHidden = true
        bottomLabel.isHidden = true
    }

    private func apply(cues: [SubtitleCue], to label: SubtitleCueLabel) {
        guard !cues.isEmpty else {
            label.isHidden = true
            return
        }
        let fontSize = baseFontSize * CGFloat(prefs.textScale)
        let combined = NSMutableAttributedString()
        for (i, cue) in cues.enumerated() {
            if i > 0 { combined.append(NSAttributedString(string: "\n")) }
            combined.append(attributedString(for: cue, fontSize: fontSize))
        }
        label.attributedText = combined
        label.backgroundColor = prefs.showsBackground ? UIColor.black.withAlphaComponent(0.6) : .clear
        label.isHidden = false
    }

    private func attributedString(for cue: SubtitleCue, fontSize: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = CGSize(width: 0, height: 1)

        let result = NSMutableAttributedString()
        for run in cue.runs {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if run.bold { traits.insert(.traitBold) }
            if run.italic { traits.insert(.traitItalic) }

            let base = UIFont.systemFont(ofSize: fontSize, weight: run.bold ? .bold : .semibold)
            let font: UIFont
            if !traits.isEmpty, let desc = base.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: desc, size: fontSize)
            } else {
                font = base
            }

            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
                .shadow: shadow
            ]
            if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: run.text, attributes: attrs))
        }
        return result
    }
}

// MARK: - SwiftUI bridge

/// Hosts a `SubtitleOverlayController` in SwiftUI so captions can be rendered
/// inside a `VideoPlayer`'s overlay closure (preserving native transport
/// controls). Loads the selected track and drives the overlay.
struct SubtitleOverlayRepresentable: UIViewRepresentable {
    let player: AVPlayer
    let selectedCaption: CaptionTrack?

    func makeCoordinator() -> Coordinator { Coordinator(player: player) }

    func makeUIView(context: Context) -> UIView {
        let view = context.coordinator.overlay.containerView
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(selection: selectedCaption)
    }

    final class Coordinator {
        let overlay: SubtitleOverlayController
        private var loadedTrackID: String?

        init(player: AVPlayer) {
            overlay = SubtitleOverlayController(player: player)
        }

        func update(selection: CaptionTrack?) {
            guard let track = selection else {
                overlay.setTrack(nil)
                loadedTrackID = nil
                return
            }
            if loadedTrackID == track.id { return }
            loadedTrackID = track.id
            SubtitleLoader.load(track) { [weak self] parsed in
                guard self?.loadedTrackID == track.id else { return }
                self?.overlay.setTrack(parsed)
            }
        }
    }
}
