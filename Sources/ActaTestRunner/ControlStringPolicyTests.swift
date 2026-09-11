import ActaKit
import Foundation
import Testing

// The pure wire-string validator (Plan 2, Task 2). Its threshold lives in `ActaKit` so a test asserts
// against the one constant rather than a hand-typed copy of the number.

@Test
func anEmptyStringIsAccepted() {
    // An empty title is legitimate — the UI falls back to the suggested one.
    #expect(ControlStringPolicy.validate("") == nil)
}

@Test
func aStringAtTheLimitIsAcceptedAndOneOverIsRejected() {
    let atLimit = String(repeating: "a", count: ControlStringPolicy.maxLength)
    #expect(ControlStringPolicy.validate(atLimit) == nil)

    let over = String(repeating: "a", count: ControlStringPolicy.maxLength + 1)
    #expect(ControlStringPolicy.validate(over) == .tooLong(max: ControlStringPolicy.maxLength))
}

@Test
func theLimitIsCountedInScalarsNotBytes() {
    // A multi-byte character counts as one scalar, so the same count of them is still accepted.
    let nonAscii = String(repeating: "é", count: ControlStringPolicy.maxLength)
    #expect(ControlStringPolicy.validate(nonAscii) == nil)
}

@Test(arguments: ["\u{0}", "\u{7}", "\n", "\r", "\t", "\u{7F}", "\u{85}", "\u{2028}", "\u{2029}"])
func aControlCharacterIsRejected(character: String) {
    #expect(ControlStringPolicy.validate("title\(character)here") == .controlCharacter)
}

@Test
func ordinaryTextIsAccepted() {
    #expect(ControlStringPolicy.validate("Weekly sync — Q3 planning café 🎧") == nil)
}
