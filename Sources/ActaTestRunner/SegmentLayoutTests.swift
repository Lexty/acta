import Testing
import ActaKit

// Pure logic for segment naming/selection. It underpins both recording (SegmentWriter) and
// recovery (RecoveryManager, Task 3) - hence it is covered separately from the file system.

@Test
func segmentFileNameIsZeroPaddedFourDigits() {
    #expect(SegmentLayout.segmentFileName(index: 0) == "0000.wav")
    #expect(SegmentLayout.segmentFileName(index: 42) == "0042.wav")
    #expect(SegmentLayout.segmentFileName(index: 1234) == "1234.wav")
}

@Test
func segmentIndexParsesValidNames() {
    #expect(SegmentLayout.segmentIndex(fromFileName: "0000.wav") == 0)
    #expect(SegmentLayout.segmentIndex(fromFileName: "0042.wav") == 42)
}

@Test
func segmentNameAndIndexRoundTripPastFourDigits() {
    // An index >= 10000 (a long recording / short segments) does not fit into 4 digits. The name
    // and the parser must stay reversible, otherwise such segments would silently drop out of
    // assembly/recovery.
    for index in [0, 42, 9999, 10000, 123_456] {
        let name = SegmentLayout.segmentFileName(index: index)
        #expect(SegmentLayout.segmentIndex(fromFileName: name) == index)
    }
    #expect(SegmentLayout.segmentIndex(fromFileName: "10000.wav") == 10000)
}

@Test
func segmentIndexRejectsForeignNames() {
    #expect(SegmentLayout.segmentIndex(fromFileName: ".DS_Store") == nil)
    #expect(SegmentLayout.segmentIndex(fromFileName: "0000.caf") == nil)
    #expect(SegmentLayout.segmentIndex(fromFileName: "12.wav") == nil)     // not 4 digits
    #expect(SegmentLayout.segmentIndex(fromFileName: "combined.wav") == nil)
    #expect(SegmentLayout.segmentIndex(fromFileName: "00a0.wav") == nil)
}

@Test
func orderedSegmentsSortsAndFiltersJunk() {
    let names = ["0002.wav", ".DS_Store", "0000.wav", "combined.wav", "0001.wav"]
    let ordered = SegmentLayout.orderedSegments(fromFileNames: names)
    #expect(ordered.map(\.index) == [0, 1, 2])
    #expect(ordered.map(\.fileName) == ["0000.wav", "0001.wav", "0002.wav"])
}
