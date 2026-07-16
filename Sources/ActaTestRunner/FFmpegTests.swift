import Testing
import ActaKit

// Pure logic for building ffmpeg arguments (assembly) - an acceptance criterion of Task 2.

@Test
func concatArgsAreCopyMuxWithSafeZero() {
    let args = FFmpeg.concatArgs(listPath: "/tmp/list.txt", outputPath: "/tmp/system.wav")
    #expect(args == ["-y", "-xerror", "-f", "concat", "-safe", "0",
                     "-i", "/tmp/list.txt", "-c", "copy", "/tmp/system.wav"])
}

@Test
func concatListContentsQuotesEachSegmentPerLine() {
    let content = FFmpeg.concatListContents(segmentPaths: ["/rec/system/0000.wav", "/rec/system/0001.wav"])
    #expect(content == "file '/rec/system/0000.wav'\nfile '/rec/system/0001.wav'\n")
}

@Test
func concatListContentsEscapesSingleQuoteInPath() {
    let content = FFmpeg.concatListContents(segmentPaths: ["/rec/it's/0000.wav"])
    #expect(content == "file '/rec/it'\\''s/0000.wav'\n")
}

@Test
func concatListContentsEmptyForNoSegments() {
    #expect(FFmpeg.concatListContents(segmentPaths: []) == "")
}
