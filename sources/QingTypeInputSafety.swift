import AppKit

enum QingTypeInputSafety {
  struct Ranges {
    let selection: NSRange
    let caret: Int
  }

  static func utf8Index(in text: String, offset: Int) -> String.Index? {
    guard offset >= 0, offset <= text.utf8.count else { return nil }
    let index = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
    return String.Index(index, within: text)
  }

  static func ranges(in text: String, start: Int, end: Int, caret: Int) -> Ranges? {
    guard start <= end,
          let startIndex = utf8Index(in: text, offset: start),
          let endIndex = utf8Index(in: text, offset: end),
          let caretIndex = utf8Index(in: text, offset: caret) else { return nil }
    let startUTF16 = startIndex.utf16Offset(in: text)
    let endUTF16 = endIndex.utf16Offset(in: text)
    return Ranges(selection: NSRange(location: startUTF16, length: endUTF16 - startUTF16),
                  caret: caretIndex.utf16Offset(in: text))
  }

  static func markedRanges(in text: String, selection: NSRange, caret: Int) -> (NSRange, NSRange)? {
    let length = text.utf16.count
    guard selection.location != NSNotFound, selection.location >= 0, selection.location <= length,
          selection.length >= 0, selection.length <= length - selection.location,
          caret >= 0, caret <= length else { return nil }
    return (NSRange(location: 0, length: selection.location),
            NSRange(location: selection.location, length: length - selection.location))
  }

  static func markAttributes(_ value: Any?) -> [NSAttributedString.Key: Any] {
    value as? [NSAttributedString.Key: Any] ?? [:]
  }
}
