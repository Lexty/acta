import Foundation

/// How many segments each track has closed so far — the number `session.json` reports while the
/// recording is still running.
///
/// Pure and unit-tested (`SegmentProgressTests`) because the runtime side is two audio queues
/// racing to bump a counter: the arithmetic ("what number should the manifest show now, and did it
/// change?") is settled here, and `AudioRecorder` only serialises the calls.
///
/// The counter is **diagnostic only**. Recovery reads the file system, never this number: it lags
/// by design (a segment is counted after it closes) and a crash freezes it wherever it was — in the
/// live run the manifest said `0` with 12 segments on disk. Trusting it would have thrown away the
/// whole meeting.
public struct SegmentProgress: Equatable, Sendable {
    /// The two tracks written in parallel; each closes its own segments.
    public enum Track: Sendable {
        case system
        case mic
    }

    public private(set) var system = 0
    public private(set) var mic = 0

    public init(system: Int = 0, mic: Int = 0) {
        self.system = system
        self.mic = mic
    }

    /// The number to publish: the tracks close their segments independently and may differ by one
    /// mid-rotation, so the greater is the honest count of what a reader would find on disk.
    public var segmentCount: Int { max(system, mic) }

    /// Count one closed segment. Returns `true` when `segmentCount` changed — the caller writes
    /// `session.json` only then, so a rotation of the trailing track costs no disk write.
    @discardableResult
    public mutating func recordFinalizedSegment(track: Track) -> Bool {
        let before = segmentCount
        switch track {
        case .system: system += 1
        case .mic: mic += 1
        }
        return segmentCount != before
    }
}
