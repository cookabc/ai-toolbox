import AppKit
import SwiftUI

/// A bitmap on a square grid, one character per cell. `.` is empty; any other
/// character is an ink that a palette maps to a colour, so one glyph can carry
/// several colours (a brand mark, an illustration) or one (an icon, drawn in the
/// foreground style).
///
/// The rows are the source of truth: what you see in the literal is what is drawn.
struct PixelGlyph: Sendable {
    struct Run: Sendable, Equatable {
        let x: Int
        let y: Int
        let length: Int
    }

    let width: Int
    let height: Int
    /// Horizontal runs per ink, so drawing is one rectangle per run, not per cell.
    let runs: [Character: [Run]]
    /// Whether every row has the same length. A short row is a typo in the art.
    let isRectangular: Bool

    init(_ rows: [String]) {
        height = rows.count
        width = rows.map(\.count).max() ?? 0
        isRectangular = Set(rows.map(\.count)).count <= 1
        var runs: [Character: [Run]] = [:]
        for (y, row) in rows.enumerated() {
            let cells = Array(row)
            var x = 0
            while x < cells.count {
                let ink = cells[x]
                guard ink != "." else {
                    x += 1
                    continue
                }
                var end = x + 1
                while end < cells.count, cells[end] == ink { end += 1 }
                runs[ink, default: []].append(Run(x: x, y: y, length: end - x))
                x = end
            }
        }
        self.runs = runs
    }

    var inks: [Character] { runs.keys.sorted() }

    /// The cells of one ink, as a path in a `width × height` box scaled into `rect`.
    func path(ink: Character, in rect: CGRect) -> Path {
        var path = Path()
        let cellWidth = rect.width / CGFloat(width)
        let cellHeight = rect.height / CGFloat(height)
        for run in runs[ink] ?? [] {
            path.addRect(
                CGRect(
                    x: rect.minX + CGFloat(run.x) * cellWidth,
                    y: rect.minY + CGFloat(run.y) * cellHeight,
                    width: CGFloat(run.length) * cellWidth,
                    height: cellHeight))
        }
        return path
    }
}

/// One ink of a glyph as a shape, so it takes `.foregroundStyle` like text does.
struct PixelGlyphShape: Shape {
    let glyph: PixelGlyph
    var ink: Character = "#"

    func path(in rect: CGRect) -> Path { glyph.path(ink: ink, in: rect) }
}

/// The interface's icon set, drawn on a 12 × 12 grid with one-point cells.
enum PixelIcon: CaseIterable, Sendable {
    case refresh, folder, power, usage, config, plus, pencil, trash, bolt, eye, eyeOff
    case check, cross, warning, info, clock, chip, calendar, download, save, swap, wand
    case chevronRight, chevronDown, hourglass

    var glyph: PixelGlyph {
        switch self {
        case .refresh: PixelArt.refresh
        case .folder: PixelArt.folder
        case .power: PixelArt.power
        case .usage: PixelArt.usage
        case .config: PixelArt.config
        case .plus: PixelArt.plus
        case .pencil: PixelArt.pencil
        case .trash: PixelArt.trash
        case .bolt: PixelArt.bolt
        case .eye: PixelArt.eye
        case .eyeOff: PixelArt.eyeOff
        case .check: PixelArt.check
        case .cross: PixelArt.cross
        case .warning: PixelArt.warning
        case .info: PixelArt.info
        case .clock: PixelArt.clock
        case .chip: PixelArt.chip
        case .calendar: PixelArt.calendar
        case .download: PixelArt.download
        case .save: PixelArt.save
        case .swap: PixelArt.swap
        case .wand: PixelArt.wand
        case .chevronRight: PixelArt.chevronRight
        case .chevronDown: PixelArt.chevronDown
        case .hourglass: PixelArt.hourglass
        }
    }
}

/// An icon in the current foreground style. Decorative by default: the control it
/// sits in carries the label.
struct PixelIconView: View {
    let icon: PixelIcon
    var scale: CGFloat = 1

    init(_ icon: PixelIcon, scale: CGFloat = 1) {
        self.icon = icon
        self.scale = scale
    }

    var body: some View {
        let glyph = icon.glyph
        PixelGlyphShape(glyph: glyph)
            .fill(.foreground)
            .frame(width: CGFloat(glyph.width) * scale, height: CGFloat(glyph.height) * scale)
            .accessibilityHidden(true)
    }
}

/// A several-colour glyph. Inks without a colour are left empty.
struct PixelArtView: View {
    let glyph: PixelGlyph
    let palette: [Character: Color]
    var scale: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            for ink in glyph.inks {
                guard let color = palette[ink] else { continue }
                context.fill(glyph.path(ink: ink, in: rect), with: .color(color))
            }
        }
        .frame(width: CGFloat(glyph.width) * scale, height: CGFloat(glyph.height) * scale)
        .accessibilityHidden(true)
    }
}

/// The tools' marks, redrawn on the pixel grid from their official artwork so the
/// tabs keep the recognisable silhouettes without dropping out of the style.
struct ToolBrandMark: View {
    let app: LiveConfigApp

    var body: some View {
        switch app {
        case .claude:
            PixelArtView(glyph: PixelArt.claudeMark, palette: ["o": Ink.claude])
        case .codex:
            PixelGlyphShape(glyph: PixelArt.codexMark)
                .fill(.foreground)
                .frame(width: CGFloat(PixelArt.codexMark.width), height: CGFloat(PixelArt.codexMark.height))
                .accessibilityHidden(true)
        }
    }
}

/// The app's own mark — the icon's three rising bars — for the header.
struct AppMark: View {
    var scale: CGFloat = 2

    var body: some View {
        PixelArtView(
            glyph: PixelArt.appMark,
            palette: ["c": Ink.brandCyan, "b": Ink.brandBlue, "v": Ink.brandViolet],
            scale: scale)
    }
}

enum PixelArt {
    static let refresh = PixelGlyph([
        "......#.....",
        "......##....",
        "....#####...",
        "..##..##....",
        "..#...#.....",
        ".#..........",
        ".#..........",
        ".#........#.",
        ".#........#.",
        "..#......#..",
        "..##....##..",
        "....####....",
    ])

    static let folder = PixelGlyph([
        "............",
        "............",
        ".####.......",
        ".#..#######.",
        ".#........#.",
        ".##########.",
        ".#........#.",
        ".#........#.",
        ".#........#.",
        ".##########.",
        "............",
        "............",
    ])

    static let power = PixelGlyph([
        "............",
        ".....##.....",
        "..#..##..#..",
        ".#...##...#.",
        ".#...##...#.",
        ".#...##...#.",
        ".#........#.",
        ".#........#.",
        "..#......#..",
        "..##....##..",
        "....####....",
        "............",
    ])

    static let usage = PixelGlyph([
        "............",
        "........##..",
        "........##..",
        "........##..",
        ".....##.##..",
        ".....##.##..",
        ".....##.##..",
        "..##.##.##..",
        "..##.##.##..",
        "..##.##.##..",
        ".##########.",
        "............",
    ])

    static let config = PixelGlyph([
        "............",
        "...##.......",
        ".##########.",
        "...##.......",
        "............",
        ".......##...",
        ".##########.",
        ".......##...",
        "............",
        ".....##.....",
        ".##########.",
        ".....##.....",
    ])

    static let plus = PixelGlyph([
        "............",
        "............",
        ".....##.....",
        ".....##.....",
        ".....##.....",
        "..########..",
        "..########..",
        ".....##.....",
        ".....##.....",
        ".....##.....",
        "............",
        "............",
    ])

    static let pencil = PixelGlyph([
        "............",
        ".........##.",
        "........#.##",
        ".......###..",
        "......###...",
        ".....###....",
        "....###.....",
        "...###......",
        "..###.......",
        "..##........",
        ".#..........",
        "............",
    ])

    static let trash = PixelGlyph([
        "............",
        "....####....",
        ".##########.",
        "............",
        "..########..",
        "..#.#..#.#..",
        "..#.#..#.#..",
        "..#.#..#.#..",
        "..#.#..#.#..",
        "..#......#..",
        "..########..",
        "............",
    ])

    static let bolt = PixelGlyph([
        "............",
        ".......###..",
        "......###...",
        ".....###....",
        "....###.....",
        "...#######..",
        "......###...",
        ".....###....",
        "....###.....",
        "...##.......",
        "..#.........",
        "............",
    ])

    static let eye = PixelGlyph([
        "............",
        "............",
        "............",
        "....####....",
        "..##....##..",
        ".#...##...#.",
        ".#...##...#.",
        "..##....##..",
        "....####....",
        "............",
        "............",
        "............",
    ])

    static let eyeOff = PixelGlyph([
        "............",
        ".#..........",
        "..#.........",
        "...#####....",
        "..###...##..",
        ".#...##...#.",
        ".#...##...#.",
        "..##...###..",
        "....#####...",
        ".........#..",
        "..........#.",
        "............",
    ])

    static let check = PixelGlyph([
        "............",
        "............",
        ".........##.",
        "........##..",
        ".......##...",
        ".##...##....",
        "..##.##.....",
        "...###......",
        "....#.......",
        "............",
        "............",
        "............",
    ])

    static let cross = PixelGlyph([
        "............",
        "............",
        "..##....##..",
        "..###..###..",
        "...######...",
        "....####....",
        "....####....",
        "...######...",
        "..###..###..",
        "..##....##..",
        "............",
        "............",
    ])

    static let warning = PixelGlyph([
        ".....##.....",
        ".....##.....",
        "....#..#....",
        "....#..#....",
        "...#.##.#...",
        "...#.##.#...",
        "..#..##..#..",
        "..#..##..#..",
        ".#........#.",
        ".#...##...#.",
        "############",
        "............",
    ])

    static let info = PixelGlyph([
        "............",
        "..########..",
        ".#........#.",
        ".#...##...#.",
        ".#........#.",
        ".#..###...#.",
        ".#...##...#.",
        ".#...##...#.",
        ".#..####..#.",
        ".#........#.",
        "..########..",
        "............",
    ])

    static let clock = PixelGlyph([
        "............",
        "....####....",
        "..##....##..",
        "..#..#...#..",
        ".#...#....#.",
        ".#...#....#.",
        ".#...####.#.",
        ".#........#.",
        "..#......#..",
        "..##....##..",
        "....####....",
        "............",
    ])

    static let chip = PixelGlyph([
        "............",
        "....#..#....",
        "..########..",
        "..#......#..",
        ".##.####.##.",
        "..#.####.#..",
        "..#.####.#..",
        ".##.####.##.",
        "..#......#..",
        "..########..",
        "....#..#....",
        "............",
    ])

    static let calendar = PixelGlyph([
        "............",
        "...#....#...",
        ".##########.",
        ".##########.",
        ".#........#.",
        ".#.##..##.#.",
        ".#.##..##.#.",
        ".#........#.",
        ".#.##..##.#.",
        ".#.##..##.#.",
        ".##########.",
        "............",
    ])

    static let download = PixelGlyph([
        ".....##.....",
        ".....##.....",
        ".....##.....",
        ".....##.....",
        "...######...",
        "....####....",
        ".....##.....",
        ".#........#.",
        ".#........#.",
        ".#........#.",
        ".##########.",
        "............",
    ])

    static let save = PixelGlyph([
        "............",
        ".########...",
        ".#..####.#..",
        ".#..#.##..#.",
        ".#..####..#.",
        ".#........#.",
        ".#.######.#.",
        ".#.#....#.#.",
        ".#.#....#.#.",
        ".#.#....#.#.",
        ".##########.",
        "............",
    ])

    static let swap = PixelGlyph([
        "............",
        ".......#....",
        ".......##...",
        ".#########..",
        ".......##...",
        ".......#....",
        "....#.......",
        "...##.......",
        "..#########.",
        "...##.......",
        "....#.......",
        "............",
    ])

    static let wand = PixelGlyph([
        "............",
        ".........#..",
        "....#...###.",
        ".........#..",
        ".......##...",
        "......##....",
        ".....##.....",
        "....##......",
        "...##.......",
        "..##.....#..",
        ".##.........",
        "............",
    ])

    static let chevronRight = PixelGlyph([
        "............",
        "............",
        "............",
        ".....#......",
        ".....##.....",
        ".....###....",
        ".....###....",
        ".....##.....",
        ".....#......",
        "............",
        "............",
        "............",
    ])

    static let chevronDown = PixelGlyph([
        "............",
        "............",
        "............",
        "............",
        "...######...",
        "....####....",
        ".....##.....",
        "............",
        "............",
        "............",
        "............",
        "............",
    ])

    static let hourglass = PixelGlyph([
        ".##########.",
        "..#......#..",
        "..#......#..",
        "...#....#...",
        "....#..#....",
        ".....##.....",
        ".....##.....",
        "....#..#....",
        "...#.##.#...",
        "..#.####.#..",
        "..########..",
        ".##########.",
    ])

    /// A 6 × 6 status lamp.
    static let lamp = PixelGlyph([
        ".####.",
        "######",
        "######",
        "######",
        "######",
        ".####.",
    ])

    /// Claude's spark: twelve uneven rays from a small core, in its own orange.
    static let claudeMark = PixelGlyph([
        "......o.......",
        "...o..o..o....",
        "....o.o..o....",
        ".o..ooo.o..o..",
        "..oo..oo..o...",
        "...o..oo.o....",
        "ooooooooo.....",
        ".....ooooooooo",
        "...o..oo.oo...",
        ".oo..o.oo.oo..",
        "....o..ooo....",
        "...o...o.o....",
        ".......o..o...",
        ".......o......",
    ])

    /// The OpenAI knot, rasterised from the official mark and made point-symmetric.
    static let codexMark = PixelGlyph([
        "....####......",
        "...##..#####..",
        "..##..##...##.",
        ".###.#......#.",
        "##.#.#..##..#.",
        "#..#.####..##.",
        "#..#.#..###.##",
        "##.###..#.#..#",
        ".##..####.#..#",
        ".#..##..#.#.##",
        ".#......#.###.",
        ".##...##..##..",
        "..#####..##...",
        "......####....",
    ])

    /// The header mark: the icon's bars in cyan, blue and violet.
    static let appMark = PixelGlyph([
        "............",
        "........vvv.",
        "........vvv.",
        "........vvv.",
        "....bbb.vvv.",
        "....bbb.vvv.",
        "....bbb.vvv.",
        "ccc.bbb.vvv.",
        "ccc.bbb.vvv.",
        "ccc.bbb.vvv.",
        "ccc.bbb.vvv.",
        "............",
    ])

    /// The menu-bar item: the same three bars, as a template.
    static let menuBarMark = PixelGlyph([
        "...............",
        "...............",
        "...........###.",
        "...........###.",
        "...........###.",
        ".......###.###.",
        ".......###.###.",
        ".......###.###.",
        "...###.###.###.",
        "...###.###.###.",
        "...###.###.###.",
        "...###.###.###.",
        "...###.###.###.",
        "...............",
        "...............",
        "...............",
    ])

    /// A small terminal: the companion of every empty, loading and error state.
    /// `d` outline, `h` casing, `n` screen. The screen is 16 × 8 cells starting at
    /// (4, 3); `TerminalScreen` draws its contents.
    static let terminal = PixelGlyph([
        "..dddddddddddddddddddd..",
        ".dhhhhhhhhhhhhhhhhhhhhd.",
        "dhhddddddddddddddddddhhd",
        "dhhdnnnnnnnnnnnnnnnndhhd",
        "dhhdnnnnnnnnnnnnnnnndhhd",
        "dhhdnnnnnnnnnnnnnnnndhhd",
        "dhhdnnnnnnnnnnnnnnnndhhd",
        "dhhdnnnnnnnnnnnnnnnndhhd",
        "dhhdnnnnnnnnnnnnnnnndhhd",
        "dhhdnnnnnnnnnnnnnnnndhhd",
        "dhhdnnnnnnnnnnnnnnnndhhd",
        "dhhddddddddddddddddddhhd",
        "dhhhhhhhhhhhhhhhhhhhhhhd",
        ".dhhhhhhhhhhhhhhhhhhhhd.",
        "..dddddddddddddddddddd..",
        ".........dhhhhd.........",
        ".......ddhhhhhhdd.......",
        "......dhhhhhhhhhhd......",
        "......dddddddddddd......",
    ])

    static let screenOrigin = (x: 4, y: 3)

    /// `>` prompt; the cursor is drawn separately so it can blink.
    static let screenPrompt = PixelGlyph([
        "................",
        "................",
        "..c.............",
        "...cc...........",
        ".....cc.........",
        "...cc...........",
        "..c.............",
        "................",
    ])

    static let screenCursor = PixelGlyph([
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        ".......cccc.....",
        "................",
    ])

    /// Three blocks; the loading state lights them in turn.
    static let screenBlocks = [
        PixelGlyph([
            "................", "................", "................", "...cc...........",
            "...cc...........", "................", "................", "................",
        ]),
        PixelGlyph([
            "................", "................", "................", ".......cc.......",
            ".......cc.......", "................", "................", "................",
        ]),
        PixelGlyph([
            "................", "................", "................", "...........cc...",
            "...........cc...", "................", "................", "................",
        ]),
    ]

    static let screenAlert = PixelGlyph([
        "................",
        ".......yy.......",
        ".......yy.......",
        ".......yy.......",
        ".......yy.......",
        "................",
        ".......yy.......",
        "................",
    ])
}

// MARK: - App icon

/// The app icon, drawn from the same pixel grid as everything else.
///
/// It is full-bleed on purpose: since macOS 26 the system masks an opaque square
/// icon to its standard shape, and shrinks anything with a transparent margin onto
/// a grey plate instead — which is what the previous, glassy icon got.
enum AppIconArt {
    struct IconCanvas {
        let size: Int
        var cells: [UInt32?]

        init(size: Int) {
            self.size = size
            cells = Array(repeating: nil, count: size * size)
        }

        subscript(x: Int, y: Int) -> UInt32? {
            get { cells[y * size + x] }
            set {
                guard x >= 0, y >= 0, x < size, y < size else { return }
                cells[y * size + x] = newValue
            }
        }

        mutating func fill(x: ClosedRange<Int>, y: ClosedRange<Int>, _ color: UInt32) {
            for row in y { for column in x { self[column, row] = color } }
        }
    }

    private struct Bar {
        let highlight: UInt32
        let main: UInt32
        let shade: UInt32
    }

    private static let cyan = Bar(highlight: 0xB4F6FD, main: 0x4FD6EA, shade: 0x2A9FC0)
    private static let blue = Bar(highlight: 0x9CC2FF, main: 0x4C8DF6, shade: 0x2E5FC9)
    private static let violet = Bar(highlight: 0xC8B5FF, main: 0x8B6CF7, shade: 0x6244CF)

    /// The icon at `size` cells: 32 for every size from 32 px up, 16 for the 16-px
    /// slot, where the bars are redrawn rather than scaled down.
    static func canvas(size: Int) -> IconCanvas {
        size >= 32 ? large() : small()
    }

    private static func background(
        _ canvas: inout IconCanvas, bands: [(rows: ClosedRange<Int>, color: UInt32)]
    ) {
        for (index, band) in bands.enumerated() {
            canvas.fill(x: 0...(canvas.size - 1), y: band.rows, band.color)
            // Dither the seam into the next band: the pixel-art gradient.
            if index + 1 < bands.count {
                let seam = band.rows.upperBound
                for x in 0..<canvas.size where x % 2 == 0 { canvas[x, seam] = bands[index + 1].color }
                for x in 0..<canvas.size where x % 2 == 1 { canvas[x, seam + 1] = band.color }
            }
        }
    }

    private static func bar(
        _ canvas: inout IconCanvas, x: ClosedRange<Int>, top: Int, bottom: Int, _ bar: Bar
    ) {
        canvas.fill(x: x, y: top...bottom, bar.main)
        canvas.fill(x: x.lowerBound...x.lowerBound, y: top...bottom, bar.highlight)
        canvas.fill(x: x, y: top...top, bar.highlight)
        canvas.fill(x: x.upperBound...x.upperBound, y: (top + 1)...bottom, bar.shade)
    }

    private static func large() -> IconCanvas {
        var canvas = IconCanvas(size: 32)
        background(
            &canvas,
            bands: [(0...10, 0x28337F), (11...21, 0x1E2766), (22...31, 0x151B4C)])
        // Floor line with a shadow under it.
        canvas.fill(x: 3...28, y: 26...26, 0x4A5BC0)
        canvas.fill(x: 3...28, y: 27...27, 0x0E1338)
        bar(&canvas, x: 5...10, top: 18, bottom: 25, cyan)
        bar(&canvas, x: 13...18, top: 12, bottom: 25, blue)
        bar(&canvas, x: 21...26, top: 6, bottom: 25, violet)
        // The spark: what makes the bars an AI tool's bars.
        let spark: UInt32 = 0xB4F6FD
        for offset in [-2, -1, 1, 2] {
            canvas[7 + offset, 8] = spark
            canvas[7, 8 + offset] = spark
        }
        canvas[7, 8] = 0xFFFFFF
        canvas[12, 5] = 0x9CC2FF
        return canvas
    }

    private static func small() -> IconCanvas {
        var canvas = IconCanvas(size: 16)
        background(&canvas, bands: [(0...7, 0x25307A), (8...15, 0x161C4F)])
        canvas.fill(x: 2...13, y: 13...13, 0x4A5BC0)
        bar(&canvas, x: 3...5, top: 9, bottom: 12, cyan)
        bar(&canvas, x: 7...9, top: 6, bottom: 12, blue)
        bar(&canvas, x: 11...13, top: 3, bottom: 12, violet)
        canvas[3, 3] = 0xB4F6FD
        return canvas
    }

    /// A bitmap of `canvas` at `pixelsPerCell`, nearest-neighbour. The bytes are
    /// written directly so the colours are exactly the palette's.
    static func bitmap(_ canvas: IconCanvas, pixelsPerCell: Int) -> NSBitmapImageRep? {
        let side = canvas.size * pixelsPerCell
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: side * 4, bitsPerPixel: 32),
            let data = rep.bitmapData
        else { return nil }
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                guard let hex = canvas[x / pixelsPerCell, y / pixelsPerCell] else {
                    (0..<4).forEach { data[offset + $0] = 0 }
                    continue
                }
                data[offset] = UInt8((hex >> 16) & 0xFF)
                data[offset + 1] = UInt8((hex >> 8) & 0xFF)
                data[offset + 2] = UInt8(hex & 0xFF)
                data[offset + 3] = 0xFF
            }
        }
        return rep
    }
}

// MARK: - Menu-bar image

enum MenuBarImage {
    /// The bars as a template image. Drawn by a handler rather than from a bitmap,
    /// so each cell lands on device pixels at whatever scale the menu bar is on.
    @MainActor static let template: NSImage = {
        let glyph = PixelArt.menuBarMark
        let image = NSImage(
            size: NSSize(width: glyph.width, height: glyph.height), flipped: true
        ) { _ in
            NSColor.black.setFill()
            for run in glyph.runs["#"] ?? [] {
                NSRect(x: run.x, y: run.y, width: run.length, height: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
