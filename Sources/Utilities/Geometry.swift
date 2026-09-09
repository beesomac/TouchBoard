import CoreGraphics
import Foundation

/// Shared field geometry in normalised (0...1) whole-area coordinates, used by both
/// the field rendering and the play model so positions and markings stay in sync.
/// The field length runs horizontally; width is vertical. Sub boxes sit just outside
/// each sideline, centred on halfway.
enum FieldLayout {
    static let field = CGRect(x: 0.035, y: 0.10, width: 0.93, height: 0.80)
    static let benchTop = CGRect(x: 0.30, y: 0.006, width: 0.40, height: 0.085)     // defence subs
    static let benchBottom = CGRect(x: 0.30, y: 0.909, width: 0.40, height: 0.085)  // attack subs

    // Field-of-play markings, as fractions along the length within `field`.
    static let tryLeft: CGFloat = 0.09
    static let tryRight: CGFloat = 0.91
    static let halfway: CGFloat = 0.5
    static var playLength: CGFloat { tryRight - tryLeft }   // represents 70 m

    /// Metres converted to a fraction of the field length.
    static func metresToFx(_ m: CGFloat) -> CGFloat { (m / 70) * playLength }

    /// Field coords (fx along length 0..1, fy across width 0..1) → normalised whole-area point.
    static func point(fx: CGFloat, fy: CGFloat) -> CGPoint {
        CGPoint(x: field.minX + fx * field.width, y: field.minY + fy * field.height)
    }
}

/// Polyline helpers used for anchoring passes onto run lines and for animating
/// players along their run paths. All points are in whatever coordinate space the
/// caller supplies (the app uses normalised 0...1 field coordinates).
enum Geo {

    static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Total arc length of a polyline.
    static func length(_ line: [CGPoint]) -> CGFloat {
        guard line.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<line.count { total += dist(line[i - 1], line[i]) }
        return total
    }

    /// Point at fraction `t` (0...1) along the polyline by arc length.
    static func pointAlong(_ line: [CGPoint], _ t: CGFloat) -> CGPoint {
        guard let first = line.first else { return .zero }
        guard line.count > 1 else { return first }
        let clamped = min(max(t, 0), 1)
        let target = length(line) * clamped
        if target <= 0 { return first }

        var travelled: CGFloat = 0
        for i in 1..<line.count {
            let seg = dist(line[i - 1], line[i])
            if travelled + seg >= target {
                let local = seg == 0 ? 0 : (target - travelled) / seg
                return lerp(line[i - 1], line[i], local)
            }
            travelled += seg
        }
        return line[line.count - 1]
    }

    /// Sub-polyline between two arc-length fractions, with interpolated endpoints.
    static func subPath(_ line: [CGPoint], from t0: CGFloat, to t1: CGFloat) -> [CGPoint] {
        guard line.count > 1 else { return [] }
        let a = max(0, min(t0, t1)), b = min(1, max(t0, t1))
        if b <= a { return [] }
        var pts: [CGPoint] = [pointAlong(line, a)]
        let total = length(line)
        var travelled: CGFloat = 0
        for i in 1..<line.count {
            travelled += dist(line[i - 1], line[i])
            let frac = total <= 0 ? 0 : travelled / total
            if frac > a && frac < b { pts.append(line[i]) }
        }
        pts.append(pointAlong(line, b))
        return pts
    }

    /// Nearest point on the polyline to `p`, with its arc-length fraction and distance.
    static func nearestOnPolyline(_ p: CGPoint, _ line: [CGPoint])
        -> (point: CGPoint, t: CGFloat, dist: CGFloat) {
        guard let first = line.first else { return (p, 0, .greatestFiniteMagnitude) }
        guard line.count > 1 else { return (first, 0, dist(p, first)) }

        let total = length(line)
        var best = (point: first, t: CGFloat(0), dist: dist(p, first))
        var travelled: CGFloat = 0

        for i in 1..<line.count {
            let a = line[i - 1], b = line[i]
            let seg = dist(a, b)
            let proj = projectOntoSegment(p, a, b)
            let d = dist(p, proj.point)
            if d < best.dist {
                let arc = travelled + seg * proj.local
                best = (proj.point, total == 0 ? 0 : arc / total, d)
            }
            travelled += seg
        }
        return best
    }

    /// Projects `p` onto segment a→b, returning the closest point and its local 0...1 param.
    private static func projectOntoSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint)
        -> (point: CGPoint, local: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq == 0 { return (a, 0) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq
        t = min(max(t, 0), 1)
        return (CGPoint(x: a.x + dx * t, y: a.y + dy * t), t)
    }
}
