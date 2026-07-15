import Testing
import ActaKit

// Чистая логика имён/выбора сегментов. База и для записи (SegmentWriter), и для восстановления
// (RecoveryManager, Task 3) — поэтому покрыта отдельно от файловой системы.

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
func segmentIndexRejectsForeignNames() {
    #expect(SegmentLayout.segmentIndex(fromFileName: ".DS_Store") == nil)
    #expect(SegmentLayout.segmentIndex(fromFileName: "0000.caf") == nil)
    #expect(SegmentLayout.segmentIndex(fromFileName: "12.wav") == nil)     // не 4 цифры
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
