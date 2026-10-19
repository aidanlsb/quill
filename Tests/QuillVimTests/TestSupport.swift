import XCTest
@testable import QuillVim

let cursorMark: Character = "█"

/// The cursor is a UTF-16 offset, like the engine's, so `"😀█a"` puts it at 2.
func splitMarked(_ s: String) -> (text: String, cursor: Int) {
    if let idx = s.firstIndex(of: cursorMark) {
        let cursor = s[..<idx].utf16.count
        var text = s
        text.remove(at: idx)
        return (text, cursor)
    }
    return (s, 0)
}

func marked(_ text: String, cursor: Int) -> String {
    if text.isEmpty { return String(cursorMark) }
    let c = min(max(0, cursor), text.utf16.count)
    let i = String.Index(utf16Offset: c, in: text)
    var out = text
    out.insert(cursorMark, at: i)
    return out
}

func vim(_ initial: String, keys: String, layout: (any ScreenLayout)? = nil) -> Engine {
    let parsed = splitMarked(initial)
    let engine = Engine(text: parsed.text, cursor: parsed.cursor, layout: layout)
    engine.type(keys)
    return engine
}

func XCTAssertVim(
    _ initial: String,
    keys: String,
    _ expected: String,
    mode: Mode? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let engine = vim(initial, keys: keys)
    let parsed = splitMarked(expected)
    XCTAssertEqual(
        engine.text,
        parsed.text,
        "text mismatch after \(keys.debugDescription)\n got: \(marked(engine.text, cursor: engine.cursor).debugDescription)\nwant: \(expected.debugDescription)",
        file: file,
        line: line
    )
    if expected.contains(cursorMark) {
        XCTAssertEqual(
            engine.cursor,
            parsed.cursor,
            "cursor mismatch after \(keys.debugDescription)\n got: \(marked(engine.text, cursor: engine.cursor))\nwant: \(expected)",
            file: file,
            line: line
        )
    }
    if let mode {
        XCTAssertEqual(engine.mode, mode, "mode mismatch after \(keys.debugDescription)", file: file, line: line)
    }
}

/// SplitMix64: deterministic, so a failing fuzz case reproduces from its seed.
struct Rng: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
