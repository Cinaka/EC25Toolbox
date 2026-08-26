import Foundation

/// One interface counter reading from the system.
struct TrafficSample: Equatable, Sendable {
    var date: Date
    var bytesIn: UInt64
    var bytesOut: UInt64
}

/// Derived per-interval rates feeding the chart.
struct TrafficRatePoint: Equatable, Sendable, Identifiable {
    var date: Date
    var bytesInPerSecond: Double
    var bytesOutPerSecond: Double

    var id: Date { date }
}

/// Totals for the current sampling session.
struct TrafficSessionStats: Equatable, Sendable {
    var startedAt: Date
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var peakBytesInPerSecond: Double = 0
    var peakBytesOutPerSecond: Double = 0

    var hasTraffic: Bool { bytesIn > 0 || bytesOut > 0 }
}

/// Published traffic state rendered by the Network tab.
struct TrafficStatus: Equatable, Sendable {
    var points: [TrafficRatePoint] = []
    var session: TrafficSessionStats?

    /// Point history kept for the chart; two seconds per sample ≈ 12 minutes.
    static let maxPoints = 360

    mutating func append(_ point: TrafficRatePoint) {
        points.append(point)
        if points.count > Self.maxPoints {
            points.removeFirst(points.count - Self.maxPoints)
        }
    }
}

/// Persisted summary of one finished sampling session.
struct TrafficSessionRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var bytesIn: UInt64
    var bytesOut: UInt64
    var peakBytesInPerSecond: Double
    var peakBytesOutPerSecond: Double
}

/// One sampler step: the chart point plus the updated session totals.
struct TrafficStep: Equatable, Sendable {
    var point: TrafficRatePoint
    var session: TrafficSessionStats
}

/// Pure rate math. Interface counters are cumulative and can reset (service
/// toggle, re-enumeration), so negative deltas are treated as zero instead of
/// corrupting the chart or the session totals.
enum TrafficMath {
    static func step(
        session: TrafficSessionStats?,
        previous: TrafficSample,
        current: TrafficSample
    ) -> TrafficStep? {
        let elapsed = current.date.timeIntervalSince(previous.date)
        guard elapsed > 0 else { return nil }
        let inDelta = current.bytesIn > previous.bytesIn
            ? current.bytesIn - previous.bytesIn
            : 0
        let outDelta = current.bytesOut > previous.bytesOut
            ? current.bytesOut - previous.bytesOut
            : 0
        let point = TrafficRatePoint(
            date: current.date,
            bytesInPerSecond: Double(inDelta) / elapsed,
            bytesOutPerSecond: Double(outDelta) / elapsed
        )
        var next = session ?? TrafficSessionStats(startedAt: previous.date)
        next.bytesIn &+= inDelta
        next.bytesOut &+= outDelta
        next.peakBytesInPerSecond = max(next.peakBytesInPerSecond, point.bytesInPerSecond)
        next.peakBytesOutPerSecond = max(next.peakBytesOutPerSecond, point.bytesOutPerSecond)
        return TrafficStep(point: point, session: next)
    }
}
