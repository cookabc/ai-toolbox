import SwiftUI

/// A rectangle whose corners are cut in square steps — the pixel-art rounded corner.
///
/// `steps` stairs of `step` points each are removed from every corner. One step is
/// the classic notched box; two read as a slightly rounder panel. All vertices are
/// whole points, so edges stay on device pixels at any scale.
struct PixelRect: InsettableShape {
    var step: CGFloat = Pixel.border
    var steps: Int = 1
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }
        let n = max(0, min(steps, Int(min(r.width, r.height) / (2 * step))))
        guard n > 0 else { return Path(r) }
        let s = step
        let cut = CGFloat(n) * s
        var p = Path()
        p.move(to: CGPoint(x: r.minX + cut, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - cut, y: r.minY))
        for i in 0..<n {  // top-right: down, then right
            p.addLine(to: CGPoint(x: r.maxX - CGFloat(n - i) * s, y: r.minY + CGFloat(i + 1) * s))
            p.addLine(to: CGPoint(x: r.maxX - CGFloat(n - i - 1) * s, y: r.minY + CGFloat(i + 1) * s))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - cut))
        for i in 0..<n {  // bottom-right: left, then down
            p.addLine(to: CGPoint(x: r.maxX - CGFloat(i + 1) * s, y: r.maxY - CGFloat(n - i) * s))
            p.addLine(to: CGPoint(x: r.maxX - CGFloat(i + 1) * s, y: r.maxY - CGFloat(n - i - 1) * s))
        }
        p.addLine(to: CGPoint(x: r.minX + cut, y: r.maxY))
        for i in 0..<n {  // bottom-left: up, then left
            p.addLine(to: CGPoint(x: r.minX + CGFloat(n - i) * s, y: r.maxY - CGFloat(i + 1) * s))
            p.addLine(to: CGPoint(x: r.minX + CGFloat(n - i - 1) * s, y: r.maxY - CGFloat(i + 1) * s))
        }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + cut))
        for i in 0..<n {  // top-left: right, then up
            p.addLine(to: CGPoint(x: r.minX + CGFloat(i + 1) * s, y: r.minY + CGFloat(n - i) * s))
            p.addLine(to: CGPoint(x: r.minX + CGFloat(i + 1) * s, y: r.minY + CGFloat(n - i - 1) * s))
        }
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> PixelRect {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// The outline of a `PixelRect`, as a filled ring: the stepped outer edge minus an
/// interior with one step fewer, so the border keeps its thickness around the
/// corner. Fill it with `FillStyle(eoFill: true)`.
///
/// Filled rather than stroked on purpose. A stroke is centred on the path, which
/// puts a 1-point line on half points, and stroked outlines pick up stray marks in
/// the off-screen renders the documentation is made from.
struct PixelBorder: Shape {
    var width: CGFloat = Pixel.border
    var steps: Int = 1

    func path(in rect: CGRect) -> Path {
        var path = PixelRect(step: width, steps: steps).path(in: rect)
        let inner = rect.insetBy(dx: width, dy: width)
        if inner.width > 0, inner.height > 0 {
            path.addPath(PixelRect(step: width, steps: max(0, steps - 1)).path(in: inner))
        }
        return path
    }
}

/// A checkerboard of `cell`-point squares: the pixel-art half-tone. It stands for
/// "part of" (reasoning inside output), "not yet" (an empty track) and "unavailable"
/// (a disabled surface) without introducing another colour.
struct DitherPattern: Shape {
    var cell: CGFloat = 1
    var phase = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let columns = Int((rect.width / cell).rounded(.down))
        let rows = Int((rect.height / cell).rounded(.down))
        guard columns > 0, rows > 0 else { return path }
        for row in 0..<rows {
            var column = (row + phase) % 2
            while column < columns {
                path.addRect(
                    CGRect(
                        x: rect.minX + CGFloat(column) * cell, y: rect.minY + CGFloat(row) * cell,
                        width: cell, height: cell))
                column += 2
            }
        }
        return path
    }
}

/// A dashed pixel outline: `dash`-point squares with `dash`-point gaps, laid from
/// each corner so the pattern is symmetric. Marks an affordance that adds
/// something rather than one that changes something.
struct PixelDashedBorder: Shape {
    var width: CGFloat = Pixel.border
    var dash: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let period = dash * 2
        func run(_ length: CGFloat, _ place: (CGFloat, CGFloat) -> CGRect) {
            var offset: CGFloat = width
            while offset + dash <= length - width {
                path.addRect(place(offset, dash))
                offset += period
            }
        }
        run(rect.width) { x, d in CGRect(x: rect.minX + x, y: rect.minY, width: d, height: width) }
        run(rect.width) { x, d in CGRect(x: rect.minX + x, y: rect.maxY - width, width: d, height: width) }
        run(rect.height) { y, d in CGRect(x: rect.minX, y: rect.minY + y, width: width, height: d) }
        run(rect.height) { y, d in CGRect(x: rect.maxX - width, y: rect.minY + y, width: width, height: d) }
        return path
    }
}

/// Integer geometry for charts drawn on the point grid.
///
/// A pixel chart can only draw whole points, but it must not distort what it
/// shows. These helpers keep the rounding honest: proportions are preserved to the
/// nearest point, segments add up to exactly the space they were given, and a
/// non-zero value never rounds away to nothing.
enum PixelMath {
    /// Splits `total` points among `values` in proportion to them, in whole points.
    ///
    /// Largest-remainder rounding, so the result sums to exactly `total` (when any
    /// value is positive) and no segment is off by more than one point. Each
    /// positive value gets at least `minimum` points, taken from the largest
    /// segments, so a sliver stays visible.
    static func segments(_ values: [Double], total: Int, minimum: Int = 1) -> [Int] {
        let clean = values.map { $0.isFinite ? max(0, $0) : 0 }
        let sum = clean.reduce(0, +)
        guard total > 0, sum > 0 else { return clean.map { _ in 0 } }
        let exact = clean.map { $0 / sum * Double(total) }
        var result = exact.map { Int($0.rounded(.down)) }
        var remaining = total - result.reduce(0, +)
        let order = exact.indices.sorted {
            (exact[$0] - Double(result[$0])) > (exact[$1] - Double(result[$1]))
        }
        for index in order where remaining > 0 && clean[index] > 0 {
            result[index] += 1
            remaining -= 1
        }
        let positive = clean.indices.filter { clean[$0] > 0 }
        if minimum > 0, positive.count * minimum <= total {
            for index in positive where result[index] < minimum {
                var needed = minimum - result[index]
                while needed > 0,
                    let donor = result.indices.filter({ result[$0] > minimum }).max(by: {
                        result[$0] < result[$1]
                    })
                {
                    result[donor] -= 1
                    result[index] += 1
                    needed -= 1
                }
            }
        }
        return result
    }

    /// A bar's length in whole points for `value` against `peak` over `length`
    /// points. Zero stays zero; any positive value is at least one point.
    static func barLength(_ value: Double, peak: Double, length: Int) -> Int {
        guard value > 0, peak > 0, length > 0 else { return 0 }
        let scaled = Int((min(value, peak) / peak * Double(length)).rounded())
        return min(length, max(1, scaled))
    }
}
