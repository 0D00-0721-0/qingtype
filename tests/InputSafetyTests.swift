import AppKit

@main
struct InputSafetyTests {
  static func main() {
    var checks = 0
    func expect(_ condition: Bool, _ name: String) {
      guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
      checks += 1
    }
    let input = "你a😀"
    let valid = QingTypeInputSafety.ranges(in: input, start: 3, end: 4, caret: 8)
    expect(valid?.selection == NSRange(location: 1, length: 1) && valid?.caret == 4,
           "valid UTF-8 positions map to UTF-16 for the text client")
    expect(QingTypeInputSafety.ranges(in: input, start: -1, end: 3, caret: 0) == nil,
           "negative offsets are rejected")
    expect(QingTypeInputSafety.ranges(in: input, start: 1, end: 3, caret: 0) == nil,
           "offset inside a UTF-8 character is rejected")
    expect(QingTypeInputSafety.ranges(in: input, start: 4, end: 3, caret: 0) == nil,
           "inverted selection is rejected")
    expect(QingTypeInputSafety.ranges(in: input, start: 0, end: 3, caret: 99) == nil,
           "out-of-bounds caret is rejected")
    expect(QingTypeInputSafety.markedRanges(in: input, selection: NSRange(location: 1, length: 1), caret: 4) != nil,
           "valid marked-text range is accepted")
    expect(QingTypeInputSafety.markedRanges(in: input, selection: NSRange(location: NSNotFound, length: 0), caret: 0) == nil,
           "unknown selection cannot be applied to attributed text")
    expect(QingTypeInputSafety.markedRanges(in: input, selection: NSRange(location: 1, length: Int.max), caret: 0) == nil,
           "overflowing selection cannot be applied")
    expect(QingTypeInputSafety.markedRanges(in: input, selection: NSRange(location: 0, length: 0), caret: 5) == nil,
           "out-of-bounds marked-text caret is rejected")
    expect(QingTypeInputSafety.markAttributes(nil).isEmpty && QingTypeInputSafety.markAttributes("unexpected").isEmpty,
           "missing or malformed framework attributes fall back to plain text")
    let attributes: [NSAttributedString.Key: Any] = [.underlineStyle: 1]
    expect(QingTypeInputSafety.markAttributes(attributes)[.underlineStyle] as? Int == 1,
           "valid framework attributes are preserved")
    expect(QingTypeInputSafety.utf8Index(in: "你好", offset: 3) != nil &&
           QingTypeInputSafety.utf8Index(in: "你好", offset: 2) == nil &&
           QingTypeInputSafety.utf8Index(in: "你好", offset: 100) == nil,
           "preview offsets are checked against their own string")
    print("PASS: \(checks) external input and framework boundary checks")
  }
}
