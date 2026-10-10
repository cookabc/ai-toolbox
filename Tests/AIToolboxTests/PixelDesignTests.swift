import AppKit
import SwiftUI
import XCTest

@testable import AIToolbox

/// The pixel design system's guarantees: whole-point geometry that does not
/// distort data, glyphs on their grids, a full-bleed icon, a bundled font that
/// covers every string the interface shows, copy without stray English, and inks
/// that meet the contrast minimums.
@MainActor
final class PixelDesignTests: XCTestCase {
  // MARK: - Chart geometry

  func testSegmentsSumExactlyAndKeepSlivers() {
    let widths = PixelMath.segments([860, 40, 100], total: 354)
    XCTAssertEqual(widths.reduce(0, +), 354, "segments must fill the bar exactly")
    XCTAssertEqual(widths, [305, 14, 35], "the spare point goes to the largest remainder")

    // A sliver keeps one point, taken from the largest segment.
    let sliver = PixelMath.segments([10_000, 1, 0], total: 100)
    XCTAssertEqual(sliver, [99, 1, 0])
    XCTAssertEqual(sliver.reduce(0, +), 100)

    // Rounding never moves a segment by more than a point.
    let values: [Double] = [3, 3, 3]
    let thirds = PixelMath.segments(values, total: 100)
    XCTAssertEqual(thirds.reduce(0, +), 100)
    XCTAssertTrue(thirds.allSatisfy { abs(Double($0) - 100.0 / 3) < 1 })
  }

  func testSegmentsHandleNothingToShow() {
    XCTAssertEqual(PixelMath.segments([0, 0, 0], total: 120), [0, 0, 0])
    XCTAssertEqual(PixelMath.segments([.nan, -5, .infinity], total: 120), [0, 0, 0])
    XCTAssertEqual(PixelMath.segments([1, 2], total: 0), [0, 0])
  }

  func testBarLengthIsProportionalAndNeverHidesAPositiveValue() {
    XCTAssertEqual(PixelMath.barLength(0, peak: 100, length: 34), 0, "a real zero draws no bar")
    XCTAssertEqual(PixelMath.barLength(1, peak: 1_000_000, length: 34), 1, "any output shows")
    XCTAssertEqual(PixelMath.barLength(50, peak: 100, length: 34), 17)
    XCTAssertEqual(PixelMath.barLength(100, peak: 100, length: 34), 34)
    XCTAssertEqual(PixelMath.barLength(150, peak: 100, length: 34), 34, "clamped to the chart")
    // Order is preserved: a larger value is never drawn shorter.
    let heights = [10.0, 11, 30, 31, 99, 100].map { PixelMath.barLength($0, peak: 100, length: 34) }
    XCTAssertEqual(heights, heights.sorted())
  }

  // MARK: - Shapes

  func testPixelRectCutsCornersInWholeSteps() {
    let rect = CGRect(x: 0, y: 0, width: 40, height: 20)
    let path = PixelRect(step: 2, steps: 1).path(in: rect)
    XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: 0.5)), "the corner cell is cut")
    XCTAssertTrue(path.contains(CGPoint(x: 2.5, y: 0.5)), "the edge starts one step in")
    XCTAssertTrue(path.contains(CGPoint(x: 0.5, y: 2.5)))
    XCTAssertTrue(path.contains(CGPoint(x: 20, y: 10)))

    let round = PixelRect(step: 2, steps: 2).path(in: rect)
    XCTAssertFalse(round.contains(CGPoint(x: 2.5, y: 0.5)), "two steps cut deeper")
    XCTAssertFalse(round.contains(CGPoint(x: 0.5, y: 2.5)))
    XCTAssertTrue(round.contains(CGPoint(x: 2.5, y: 2.5)), "the inner stair is kept")
    XCTAssertEqual(round.boundingRect, rect)
  }

  func testPixelBorderIsARingOfConstantThickness() {
    let rect = CGRect(x: 0, y: 0, width: 40, height: 20)
    let ring = PixelBorder(width: 2, steps: 1).path(in: rect)
    let inside = { (point: CGPoint) in ring.contains(point, eoFill: true) }
    XCTAssertTrue(inside(CGPoint(x: 20, y: 1)), "top edge")
    XCTAssertTrue(inside(CGPoint(x: 1, y: 10)), "left edge")
    XCTAssertTrue(inside(CGPoint(x: 39, y: 10)), "right edge")
    XCTAssertFalse(inside(CGPoint(x: 20, y: 10)), "the interior is not border")
    XCTAssertFalse(inside(CGPoint(x: 1, y: 1)), "the cut corner is not border")

    // Two steps: the inner outline keeps one, so the stair is border too and the
    // ring is as thick across the corner as along the edges.
    let rounder = PixelBorder(width: 2, steps: 2).path(in: rect)
    XCTAssertTrue(rounder.contains(CGPoint(x: 3, y: 3), eoFill: true))
    XCTAssertFalse(rounder.contains(CGPoint(x: 5, y: 5), eoFill: true))
    XCTAssertFalse(rounder.contains(CGPoint(x: 1, y: 3), eoFill: true))
  }

  func testDitherIsACheckerboard() {
    let path = DitherPattern(cell: 1).path(in: CGRect(x: 0, y: 0, width: 4, height: 2))
    XCTAssertTrue(path.contains(CGPoint(x: 0.5, y: 0.5)))
    XCTAssertFalse(path.contains(CGPoint(x: 1.5, y: 0.5)))
    XCTAssertFalse(path.contains(CGPoint(x: 0.5, y: 1.5)))
    XCTAssertTrue(path.contains(CGPoint(x: 1.5, y: 1.5)))
  }

  // MARK: - Art

  func testIconsSitOnTheTwelvePointGrid() {
    for icon in PixelIcon.allCases {
      XCTAssertEqual(icon.glyph.width, 12, "\(icon) width")
      XCTAssertEqual(icon.glyph.height, 12, "\(icon) height")
      XCTAssertFalse(icon.glyph.runs.isEmpty, "\(icon) is blank")
    }
  }

  func testGlyphRowsAreRectangularAndRunsRebuildThem() {
    let rows = ["#..##", ".#.#.", "....."]
    let glyph = PixelGlyph(rows)
    XCTAssertEqual(glyph.width, 5)
    XCTAssertEqual(glyph.height, 3)
    var rebuilt = Array(repeating: Array(repeating: Character("."), count: 5), count: 3)
    for (ink, runs) in glyph.runs {
      for run in runs { for x in run.x..<(run.x + run.length) { rebuilt[run.y][x] = ink } }
    }
    XCTAssertEqual(rebuilt.map { String($0) }, rows)

    XCTAssertFalse(PixelGlyph(["##", "#"]).isRectangular)
    let art = PixelIcon.allCases.map(\.glyph) + [
      PixelArt.claudeMark, PixelArt.codexMark, PixelArt.appMark, PixelArt.menuBarMark,
      PixelArt.terminal, PixelArt.lamp, PixelArt.screenPrompt, PixelArt.screenCursor,
      PixelArt.screenAlert,
    ] + PixelArt.screenBlocks
    for glyph in art {
      XCTAssertTrue(glyph.isRectangular, "a row of \(glyph.width)-wide art is a different length")
    }
    XCTAssertEqual(PixelArt.claudeMark.width, 14)
    XCTAssertEqual(PixelArt.codexMark.height, 14)
  }

  /// The screen contents are drawn into the terminal's 16 × 8 screen and nowhere else.
  func testTerminalScreenArtFitsTheScreen() {
    let screens = [PixelArt.screenPrompt, PixelArt.screenCursor, PixelArt.screenAlert] + PixelArt.screenBlocks
    for screen in screens {
      XCTAssertEqual(screen.width, 16)
      XCTAssertEqual(screen.height, 8)
    }
    let origin = PixelArt.screenOrigin
    let screenRuns = PixelArt.terminal.runs["n"] ?? []
    XCTAssertTrue(screenRuns.allSatisfy { $0.x == origin.x && $0.length == 16 })
    XCTAssertEqual(Set(screenRuns.map(\.y)), Set(origin.y..<(origin.y + 8)))
  }

  func testMenuBarImageIsAFixedSizeTemplate() {
    let image = MenuBarImage.template
    XCTAssertTrue(image.isTemplate)
    XCTAssertEqual(image.size, NSSize(width: 15, height: 16))
  }

  /// An icon with any transparent cell is shrunk onto a grey plate by macOS 26+.
  func testAppIconIsFullBleedAndOpaque() throws {
    for size in [16, 32] {
      let canvas = AppIconArt.canvas(size: size)
      XCTAssertEqual(canvas.size, size)
      XCTAssertTrue(canvas.cells.allSatisfy { $0 != nil }, "\(size)-cell icon has a transparent cell")
    }
    let rep = try XCTUnwrap(AppIconArt.bitmap(AppIconArt.canvas(size: 32), pixelsPerCell: 4))
    XCTAssertEqual(rep.pixelsWide, 128)
    // Nearest-neighbour: both sides of a cell boundary keep their own colours.
    let canvas = AppIconArt.canvas(size: 32)
    for (x, y) in [(5, 18), (13, 12), (21, 6), (7, 8)] {
      let expected = try XCTUnwrap(canvas[x, y])
      let color = try XCTUnwrap(rep.colorAt(x: x * 4 + 3, y: y * 4 + 3))
      XCTAssertEqual(Int((color.redComponent * 255).rounded()), Int((expected >> 16) & 0xFF))
      XCTAssertEqual(color.alphaComponent, 1)
    }
  }

  // MARK: - Font and copy

  func testPixelFontIsBundledAndRegisters() {
    XCTAssertTrue(PixelFont.isAvailable, "the pixel font must load from the resource bundle")
    XCTAssertNotNil(NSFont(name: PixelFont.postScriptName, size: PixelFont.designSize))
    XCTAssertNotNil(AppResources.url("ArkPixel-OFL", "txt"), "the licence ships with the font")
  }

  /// Every character of every label is drawn by the pixel font itself, so no label
  /// falls back to another face mid-word. Sentences (anything with a 。) are running
  /// text in the system font and are exempt; see `L10n`.
  func testInterfaceLabelsAreCoveredByThePixelFont() throws {
    let font = try XCTUnwrap(PixelFont.characterSet)
    let numbers = [0, 7, 999, 1_260, 99_995, 127_000, 3_700_000, 99_995_000, 2_500_000_000]
      .map { Format.token(Int64($0)) }
    let dates = [Format.time(Date(), withDate: true), Format.day(Date()), Format.monthDay(Date())]
      + (0..<7).map { Format.weekday(Date().addingTimeInterval(Double($0) * 86_400)) }
    var missing: [String: Set<Character>] = [:]
    let labels = try interfaceLiterals().filter { !$0.contains("。") }
    XCTAssertGreaterThan(labels.count, 80)
    for text in labels + numbers + dates + [Format.percent(0.86)] {
      for character in text where !character.isWhitespace {
        let scalars = character.unicodeScalars
        if !scalars.allSatisfy(font.contains) { missing[text, default: []].insert(character) }
      }
    }
    XCTAssertTrue(missing.isEmpty, "characters the pixel font cannot draw: \(missing)")
  }

  /// Ordinary words are Chinese. Latin text is limited to names, identifiers and
  /// units the user reads elsewhere verbatim; anything else is untranslated copy.
  func testInterfaceCopyHasNoUntranslatedWords() throws {
    let allowed: Set<String> = [
      // Products and companies
      "AI", "Toolbox", "Codex", "Claude", "Code", "OpenAI", "Anthropic", "ChatGPT", "Console", "Mac",
      // Keyboard shortcuts
      "R", "Q",
      // Protocols, formats and units
      "API", "HTTP", "http", "https", "TLS", "JSON", "UTF", "TOML", "ms", "token", "ID", "Bearer",
      // Files, paths, keys and fields the user types or finds on disk
      "auth", "json", "config", "toml", "settings", "codex", "claude", "env", "Library", "Application",
      "Support", "providers", "model", "providers", "catalog", "wire", "api", "responses", "v",
      "ANTHROPIC", "KEY", "AUTH", "TOKEN", "x", "key", "Authorization", "openai", "ollama", "lmstudio",
      // Placeholder examples
      "sk", "company", "gateway",
    ]
    var stray: [String: Set<String>] = [:]
    for text in try interfaceLiterals() {
      let words = text.split { !$0.isASCII || !($0.isLetter) }.map(String.init)
      for word in words where !allowed.contains(word) {
        stray[text, default: []].insert(word)
      }
    }
    XCTAssertTrue(stray.isEmpty, "untranslated words in the interface copy: \(stray)")
  }

  /// The string literals in `L10n.swift`, with interpolations removed.
  private func interfaceLiterals() throws -> [String] {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Sources/AIToolbox/L10n.swift")
    let source = try String(contentsOf: file, encoding: .utf8)
    let code = source.split(separator: "\n").filter {
      !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }.joined(separator: "\n")
    let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
    let interpolation = try NSRegularExpression(pattern: #"\\\([^)]*\)"#)
    let range = NSRange(code.startIndex..., in: code)
    let literals: [String] = literal.matches(in: code, range: range).compactMap { match in
      guard let body = Range(match.range(at: 1), in: code) else { return nil }
      let text = String(code[body])
      let stripped = interpolation.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
      return stripped.replacingOccurrences(of: #"\""#, with: "\"")
    }
    // The formatting locale is an identifier, not copy.
    let copy = literals.filter { $0 != "zh_Hans_CN" }
    XCTAssertGreaterThan(copy.count, 150, "the scan must actually find the copy")
    return copy
  }

  // MARK: - Contrast

  func testTextInksMeetTheContrastMinimums() throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
      let surface = try resolved(Ink.surface, appearance)
      let canvas = try resolved(Ink.canvas, appearance)
      let sunken = try resolved(Ink.sunken, appearance)
      for (ink, name) in [(Ink.text, "text"), (Ink.textMuted, "textMuted"), (Ink.accent, "accent"),
                          (Ink.danger, "danger"), (Ink.warning, "warning")] {
        let color = try resolved(ink, appearance)
        for (background, label) in [(surface, "surface"), (canvas, "canvas"), (sunken, "sunken")] {
          XCTAssertGreaterThanOrEqual(
            contrast(color, background), 4.5,
            "\(name) on \(label) in \(appearance.rawValue)")
        }
      }
      let chrome = try resolved(Ink.chrome, appearance)
      for ink in [Ink.chromeText, Ink.chromeMuted] {
        XCTAssertGreaterThanOrEqual(contrast(try resolved(ink, appearance), chrome), 4.5)
      }
      XCTAssertGreaterThanOrEqual(
        contrast(try resolved(Ink.chromeTabText, appearance), try resolved(Ink.chromeTab, appearance)), 4.5)
      XCTAssertGreaterThanOrEqual(
        contrast(try resolved(Ink.onAccent, appearance), try resolved(Ink.accent, appearance)), 4.5)
      // Chart fills and control edges: the 3:1 non-text minimum.
      for ink in [Ink.accentFill, Ink.cacheRead, Ink.cacheWrite, Ink.uncached, Ink.control] {
        XCTAssertGreaterThanOrEqual(contrast(try resolved(ink, appearance), surface), 3)
      }
    }
  }

  private func resolved(_ color: Color, _ appearance: NSAppearance.Name) throws -> NSColor {
    let look = try XCTUnwrap(NSAppearance(named: appearance))
    var result: NSColor?
    look.performAsCurrentDrawingAppearance {
      result = NSColor(color).usingColorSpace(.sRGB)
    }
    return try XCTUnwrap(result)
  }

  private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
    func luminance(_ c: NSColor) -> Double {
      func channel(_ v: CGFloat) -> Double {
        let v = Double(v)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
        + 0.0722 * channel(c.blueComponent)
    }
    let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
    return (high + 0.05) / (low + 0.05)
  }
}
