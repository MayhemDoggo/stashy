//
//  WebVTTSubtitles.swift
//  stashy
//
//  Parsing and model for sidecar WebVTT (*.vtt) subtitle tracks.
//
//  Scope note: a pragmatic subset of WebVTT — enough to render Stash caption
//  tracks with correct timing, a top/bottom placement hint (from the `line:`
//  setting), inline bold/italic/underline, and text/background color from
//  `STYLE` (`::cue`) rules plus inline `<c.class>` tags. Fine-grained
//  positioning (position/align/size, vertical text) and font-family/size
//  styling are parsed leniently but intentionally not modeled.
//

import Foundation

// MARK: - Model

/// Vertical placement of a subtitle cue, derived from the WebVTT `line:` setting.
/// Full positioning is reduced to the two placements that matter in practice.
enum SubtitlePlacement: Equatable {
    case top
    case bottom
}

/// An RGBA color in 0...1 components, parsed from a WebVTT `STYLE` block.
/// Kept Foundation-only (no UIColor) so the model stays platform-agnostic and
/// testable; the renderer maps it to a `UIColor`.
struct RGBAColor: Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double
}

/// A single styled run of text within a cue. Styling covers the WebVTT inline
/// toggles (`<b>`, `<i>`, `<u>`) plus text/background color resolved from
/// `STYLE` (`::cue`) rules and inline `<c.class>` tags.
struct SubtitleRun: Equatable {
    var text: String
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var color: RGBAColor? = nil
    var backgroundColor: RGBAColor? = nil
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
/// a top/bottom placement hint from the `line:` setting, inline `<b>`/`<i>`/`<u>`
/// styling, and color from `STYLE` (`::cue`) rules keyed by `<c.class>` tags.
/// `REGION`/`NOTE` blocks and unknown cue tags (`<v>`, `<ruby>`, inline
/// timestamps) are skipped or stripped rather than treated as errors, so a
/// malformed or richer file still yields usable captions.
enum WebVTTParser {

    static func parse(_ text: String) -> SubtitleTrack {
        // Normalize line endings (WebVTT permits LF, CRLF, and CR).
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var cues: [SubtitleCue] = []
        let stylesheet = WebVTTStyleSheet()
        var i = 0
        let n = lines.count

        // Blocks are separated by one or more blank lines. Scan block-by-block:
        // STYLE blocks feed the stylesheet; cue blocks are parsed against it;
        // other non-cue blocks (header / NOTE / REGION) are ignored.
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
            if block.first?.trimmingCharacters(in: .whitespaces).hasPrefix("STYLE") == true {
                stylesheet.ingest(block)
            } else if let cue = parseBlock(block, stylesheet: stylesheet) {
                cues.append(cue)
            }
        }

        cues.sort { $0.start < $1.start }
        return SubtitleTrack(cues: cues)
    }

    /// Parse one block into a cue, or nil if it isn't a cue.
    private static func parseBlock(_ block: [String], stylesheet: WebVTTStyleSheet) -> SubtitleCue? {
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
        let runs = parsePayload(payloadLines, stylesheet: stylesheet)
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
    /// (including nesting), tracking `<c.class>` classes, and resolving each
    /// run's color from the stylesheet. Unknown tags (`<v>`, `<ruby>`, inline
    /// timestamps) are stripped. Lines are joined with "\n".
    private static func parsePayload(_ lines: [String], stylesheet: WebVTTStyleSheet) -> [SubtitleRun] {
        let joined = lines.joined(separator: "\n")
        var runs: [SubtitleRun] = []
        var bold = 0, italic = 0, underline = 0
        var classStack: [[String]] = []   // one entry per open <c ...> tag
        var buffer = ""

        func flush() {
            let decoded = decodeEntities(buffer)
            buffer = ""
            guard !decoded.isEmpty else { return }
            let resolved = stylesheet.style(bold: bold > 0, italic: italic > 0, classes: classStack.flatMap { $0 })
            runs.append(SubtitleRun(
                text: decoded,
                bold: bold > 0,
                italic: italic > 0,
                underline: underline > 0,
                color: resolved.color,
                backgroundColor: resolved.backgroundColor
            ))
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
                let raw = String(joined[joined.index(after: idx)..<close]).trimmingCharacters(in: .whitespaces)
                let (name, classes, isClose) = parseTag(raw)
                switch name {
                case "b": flush(); bold += isClose ? -1 : 1
                case "i": flush(); italic += isClose ? -1 : 1
                case "u": flush(); underline += isClose ? -1 : 1
                case "c":
                    flush()
                    if isClose {
                        if !classStack.isEmpty { classStack.removeLast() }
                    } else {
                        classStack.append(classes)
                    }
                default: break  // <v>, <ruby>, inline timestamps, etc. → stripped
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

    /// Parse a tag body into its base name, any `.class` names, and whether it
    /// is a closing tag. e.g. "c.speaker1.loud" → ("c", ["speaker1","loud"], false),
    /// "v Bob" → ("v", [], false), "/c" → ("c", [], true).
    private static func parseTag(_ tag: String) -> (name: String, classes: [String], isClose: Bool) {
        var t = tag
        let isClose = t.hasPrefix("/")
        if isClose { t.removeFirst() }
        // Drop any annotation after whitespace (e.g. <v Bob>, <lang en>).
        let head = t.prefix { $0 != " " && $0 != "\t" }
        let parts = head.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
        let name = parts.first?.lowercased() ?? ""
        return (name, Array(parts.dropFirst()), isClose)
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

// MARK: - Stylesheet (STYLE / ::cue)

/// Accumulates color styling from WebVTT `STYLE` blocks and resolves the color
/// for a run given its active inline tags and classes. Supports `::cue`,
/// `::cue(.class)`, and `::cue(tag)` selectors with `color` / `background-color`.
final class WebVTTStyleSheet {
    struct RunStyle: Equatable {
        var color: RGBAColor?
        var backgroundColor: RGBAColor?
        /// Overlay this style on top of `base`; own non-nil fields win.
        func merged(over base: RunStyle) -> RunStyle {
            RunStyle(color: color ?? base.color,
                     backgroundColor: backgroundColor ?? base.backgroundColor)
        }
    }

    private var defaultStyle = RunStyle()
    private var classStyles: [String: RunStyle] = [:]
    private var tagStyles: [String: RunStyle] = [:]

    /// Feed a `STYLE` block (its raw lines, including the leading "STYLE" line).
    func ingest(_ blockLines: [String]) {
        parseRules(blockLines.dropFirst().joined(separator: "\n"))
    }

    /// Resolve the effective color style for a run. Precedence, least to most
    /// specific: `::cue` default → tag rules (b/i/u) → class rules (in order).
    func style(bold: Bool, italic: Bool, classes: [String]) -> RunStyle {
        var result = defaultStyle
        if bold, let t = tagStyles["b"] { result = t.merged(over: result) }
        if italic, let t = tagStyles["i"] { result = t.merged(over: result) }
        for cls in classes {
            if let c = classStyles[cls] { result = c.merged(over: result) }
        }
        return result
    }

    // MARK: Rule parsing

    private func parseRules(_ css: String) {
        var remainder = Substring(css)
        while let braceOpen = remainder.firstIndex(of: "{"),
              let braceClose = remainder[braceOpen...].firstIndex(of: "}") {
            let selector = remainder[..<braceOpen].trimmingCharacters(in: .whitespacesAndNewlines)
            let decls = String(remainder[remainder.index(after: braceOpen)..<braceClose])
            applyRule(selector: selector, declarations: decls)
            remainder = remainder[remainder.index(after: braceClose)...]
        }
    }

    private func applyRule(selector: String, declarations: String) {
        let style = parseDeclarations(declarations)
        guard let cueRange = selector.range(of: "::cue") else { return }
        let arg = selector[cueRange.upperBound...].trimmingCharacters(in: .whitespaces)
        if arg.isEmpty {
            defaultStyle = style.merged(over: defaultStyle)
            return
        }
        guard arg.hasPrefix("("), arg.hasSuffix(")") else { return }
        let inner = arg.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix(".") {
            let cls = String(inner.dropFirst())
            classStyles[cls] = style.merged(over: classStyles[cls] ?? RunStyle())
        } else if !inner.isEmpty {
            let tag = inner.lowercased()
            tagStyles[tag] = style.merged(over: tagStyles[tag] ?? RunStyle())
        }
    }

    private func parseDeclarations(_ decls: String) -> RunStyle {
        var style = RunStyle()
        for decl in decls.split(separator: ";") {
            let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "color": style.color = CSSColor.parse(kv[1])
            case "background", "background-color": style.backgroundColor = CSSColor.parse(kv[1])
            default: break
            }
        }
        return style
    }
}

// MARK: - CSS color parsing

enum CSSColor {
    /// Parse a CSS color value: named color, `#rgb`/`#rgba`/`#rrggbb`/`#rrggbbaa`,
    /// or `rgb()`/`rgba()`. Returns nil if unrecognized.
    static func parse(_ raw: String) -> RGBAColor? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") { return parseHex(String(s.dropFirst())) }
        if s.hasPrefix("rgb") { return parseRGB(s) }
        return named[s]
    }

    private static func parseHex(_ hex: String) -> RGBAColor? {
        let chars = Array(hex)
        func nibble(_ c: Character) -> Double? {
            guard let v = Int(String(c), radix: 16) else { return nil }
            return Double(v * 17) / 255.0
        }
        func byte(_ a: Int) -> Double? {
            guard a + 1 < chars.count, let v = Int(String(chars[a...a+1]), radix: 16) else { return nil }
            return Double(v) / 255.0
        }
        switch chars.count {
        case 3, 4:
            guard let r = nibble(chars[0]), let g = nibble(chars[1]), let b = nibble(chars[2]) else { return nil }
            let a = chars.count == 4 ? (nibble(chars[3]) ?? 1) : 1
            return RGBAColor(r: r, g: g, b: b, a: a)
        case 6, 8:
            guard let r = byte(0), let g = byte(2), let b = byte(4) else { return nil }
            let a = chars.count == 8 ? (byte(6) ?? 1) : 1
            return RGBAColor(r: r, g: g, b: b, a: a)
        default:
            return nil
        }
    }

    private static func parseRGB(_ s: String) -> RGBAColor? {
        guard let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")") else { return nil }
        let comps = s[s.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard comps.count >= 3 else { return nil }
        func channel(_ str: String) -> Double? {
            if str.hasSuffix("%") { return Double(str.dropLast()).map { $0 / 100.0 } }
            return Double(str).map { $0 / 255.0 }
        }
        guard let r = channel(comps[0]), let g = channel(comps[1]), let b = channel(comps[2]) else { return nil }
        let a = comps.count >= 4 ? (Double(comps[3]) ?? 1) : 1
        return RGBAColor(r: r, g: g, b: b, a: a)
    }

    /// Common CSS named colors used by subtitle authors (subset of the full set).
    private static let named: [String: RGBAColor] = {
        func c(_ r: Int, _ g: Int, _ b: Int) -> RGBAColor {
            RGBAColor(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255, a: 1)
        }
        return [
            "white": c(255, 255, 255), "black": c(0, 0, 0), "red": c(255, 0, 0),
            "lime": c(0, 255, 0), "green": c(0, 128, 0), "blue": c(0, 0, 255),
            "yellow": c(255, 255, 0), "cyan": c(0, 255, 255), "aqua": c(0, 255, 255),
            "magenta": c(255, 0, 255), "fuchsia": c(255, 0, 255), "gray": c(128, 128, 128),
            "grey": c(128, 128, 128), "silver": c(192, 192, 192), "maroon": c(128, 0, 0),
            "olive": c(128, 128, 0), "navy": c(0, 0, 128), "teal": c(0, 128, 128),
            "purple": c(128, 0, 128), "orange": c(255, 165, 0), "pink": c(255, 192, 203)
        ]
    }()
}
