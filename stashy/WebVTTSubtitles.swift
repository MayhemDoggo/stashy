//
//  WebVTTSubtitles.swift
//  stashy
//
//  Parsing and model for sidecar WebVTT (*.vtt) subtitle tracks.
//
//  Scope note: this is a deliberately reduced subset of WebVTT — enough to
//  render Stash caption tracks with correct timing, a top/bottom placement
//  hint (from the `line:` setting), and inline bold/italic/underline styling.
//  Arbitrary color / background / font styling from `STYLE`/`::cue` blocks and
//  fine-grained positioning (position/align/size, vertical text) are parsed
//  leniently but intentionally not modeled.
//

import Foundation

// MARK: - Model

/// Vertical placement of a subtitle cue, derived from the WebVTT `line:` setting.
/// Full positioning is reduced to the two placements that matter in practice.
enum SubtitlePlacement: Equatable {
    case top
    case bottom
}

/// A single styled run of text within a cue. Styling is limited to the typeface
/// toggles WebVTT expresses with inline tags (`<b>`, `<i>`, `<u>`); color and
/// font styling are not modeled.
struct SubtitleRun: Equatable {
    var text: String
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
}

/// One caption cue: a time range plus its styled, possibly multi-line text.
struct SubtitleCue: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let placement: SubtitlePlacement
    /// Ordered styled runs. Hard line breaks are preserved as "\n" inside run text.
    let runs: [SubtitleRun]

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }

    /// Plain-text form (styling stripped), useful for logging / fallback.
    var plainText: String {
        runs.map(\.text).joined()
    }
}

/// A parsed subtitle track: cues sorted by start time.
struct SubtitleTrack: Equatable {
    let cues: [SubtitleCue]

    /// All cues active at `time` (WebVTT permits overlap; the renderer stacks them).
    func activeCues(at time: TimeInterval) -> [SubtitleCue] {
        cues.filter { $0.contains(time) }
    }

    var isEmpty: Bool { cues.isEmpty }
}

// MARK: - Parser

/// Minimal, forgiving WebVTT parser scoped to what Stashy renders: cue timings,
/// a top/bottom placement hint from the `line:` setting, and inline
/// `<b>`/`<i>`/`<u>` styling. `STYLE`, `REGION`, `NOTE` blocks and unknown cue
/// tags (`<c>`, `<v>`, `<ruby>`, inline timestamps) are skipped or stripped
/// rather than treated as errors, so a malformed or richer file still yields
/// usable captions.
enum WebVTTParser {

    static func parse(_ text: String) -> SubtitleTrack {
        // Normalize line endings (WebVTT permits LF, CRLF, and CR).
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var cues: [SubtitleCue] = []
        var i = 0
        let n = lines.count

        // Blocks are separated by one or more blank lines. Scan block-by-block;
        // non-cue blocks (header / STYLE / NOTE / REGION) are ignored.
        while i < n {
            if lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }
            var block: [String] = []
            while i < n && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                block.append(lines[i])
                i += 1
            }
            if let cue = parseBlock(block) {
                cues.append(cue)
            }
        }

        cues.sort { $0.start < $1.start }
        return SubtitleTrack(cues: cues)
    }

    /// Parse one block into a cue, or nil if it isn't a cue.
    private static func parseBlock(_ block: [String]) -> SubtitleCue? {
        guard !block.isEmpty else { return nil }

        let first = block[0].trimmingCharacters(in: .whitespaces)
        if first.hasPrefix("WEBVTT") || first.hasPrefix("STYLE")
            || first.hasPrefix("NOTE") || first.hasPrefix("REGION") {
            return nil
        }

        // The timing line is the first line containing "-->"; an optional cue
        // identifier may precede it.
        guard let timingIndex = block.firstIndex(where: { $0.contains("-->") }),
              let timing = parseTiming(block[timingIndex]) else {
            return nil
        }

        let payloadLines = Array(block[(timingIndex + 1)...])
        let runs = parsePayload(payloadLines)
        guard !runs.isEmpty else { return nil }

        return SubtitleCue(start: timing.start,
                           end: timing.end,
                           placement: timing.placement,
                           runs: runs)
    }

    // MARK: Timing + settings

    private struct Timing {
        let start: TimeInterval
        let end: TimeInterval
        let placement: SubtitlePlacement
    }

    private static func parseTiming(_ line: String) -> Timing? {
        // "HH:MM:SS.mmm --> HH:MM:SS.mmm  setting:value setting:value"
        guard let arrowRange = line.range(of: "-->") else { return nil }
        let startStr = String(line[..<arrowRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let after = String(line[arrowRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let afterParts = after.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        guard let endStr = afterParts.first,
              let start = parseTimestamp(startStr),
              let end = parseTimestamp(endStr) else { return nil }

        // Cue settings such as "line:0%", "position:50%", "align:start".
        var placement: SubtitlePlacement = .bottom
        for token in afterParts.dropFirst() {
            let kv = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard kv.count == 2, kv[0] == "line" else { continue }
            placement = placementForLineSetting(kv[1])
        }
        return Timing(start: start, end: end, placement: placement)
    }

    /// Map a WebVTT `line:` value to top/bottom.
    /// - Percentage `p%`: top half (`< 50%`) → `.top`, otherwise `.bottom`.
    /// - Integer line number: non-negative counts from the top → `.top`;
    ///   negative counts from the bottom → `.bottom`.
    private static func placementForLineSetting(_ value: String) -> SubtitlePlacement {
        // Values may carry an alignment suffix ("0,start"); take the number part.
        let numberPart = value.split(separator: ",").first.map(String.init) ?? value
        if numberPart.hasSuffix("%") {
            if let pct = Double(numberPart.dropLast()) { return pct < 50 ? .top : .bottom }
            return .bottom
        }
        if let lineNum = Int(numberPart) {
            return lineNum >= 0 ? .top : .bottom
        }
        return .bottom
    }

    /// Parse "HH:MM:SS.mmm" or "MM:SS.mmm" into seconds.
    private static func parseTimestamp(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        func frac(_ str: String) -> Double? { Double(str.replacingOccurrences(of: ",", with: ".")) }
        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let sec = frac(parts[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        } else {
            guard let m = Double(parts[0]), let sec = frac(parts[1]) else { return nil }
            return m * 60 + sec
        }
    }

    // MARK: Payload (inline styling)

    /// Convert cue payload lines into styled runs, honoring `<b>`/`<i>`/`<u>`
    /// (including nesting) and stripping every other tag. Lines are joined with "\n".
    private static func parsePayload(_ lines: [String]) -> [SubtitleRun] {
        let joined = lines.joined(separator: "\n")
        var runs: [SubtitleRun] = []
        var bold = 0, italic = 0, underline = 0
        var buffer = ""

        func flush() {
            let decoded = decodeEntities(buffer)
            buffer = ""
            guard !decoded.isEmpty else { return }
            runs.append(SubtitleRun(text: decoded, bold: bold > 0, italic: italic > 0, underline: underline > 0))
        }

        var idx = joined.startIndex
        while idx < joined.endIndex {
            let ch = joined[idx]
            if ch == "<" {
                guard let close = joined[idx...].firstIndex(of: ">") else {
                    buffer.append(ch)  // unterminated "<": treat literally
                    idx = joined.index(after: idx)
                    continue
                }
                let tag = String(joined[joined.index(after: idx)..<close]).trimmingCharacters(in: .whitespaces)
                let (name, isClose) = tagName(tag.lowercased())
                switch name {
                case "b": flush(); bold += isClose ? -1 : 1
                case "i": flush(); italic += isClose ? -1 : 1
                case "u": flush(); underline += isClose ? -1 : 1
                default: break  // <c>, <v>, <ruby>, inline timestamps, etc. → stripped
                }
                bold = max(0, bold); italic = max(0, italic); underline = max(0, underline)
                idx = joined.index(after: close)
            } else {
                buffer.append(ch)
                idx = joined.index(after: idx)
            }
        }
        flush()
        return runs
    }

    /// Extract a tag's base name (before any "." class or " " annotation) and
    /// whether it is a closing tag.
    private static func tagName(_ tag: String) -> (name: String, isClose: Bool) {
        var t = tag
        let isClose = t.hasPrefix("/")
        if isClose { t.removeFirst() }
        let base = t.prefix { $0 != "." && $0 != " " }
        return (String(base), isClose)
    }

    /// Decode the small set of WebVTT-relevant HTML entities. `&amp;` is decoded
    /// last so escaped entities (e.g. "&amp;lt;") are not double-decoded.
    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lrm;", with: "\u{200E}")
            .replacingOccurrences(of: "&rlm;", with: "\u{200F}")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
