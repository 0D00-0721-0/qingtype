import Foundation

struct PersonalWord: Codable, Equatable, Identifiable {
  var id: UUID = UUID()
  var text: String
  var pinyin: String
  var weight: Int = 1000

  static func normalizePinyin(_ value: String) -> String {
    value.lowercased().replacingOccurrences(of: "u:", with: "v").replacingOccurrences(of: "ü", with: "v")
      .replacingOccurrences(of: "'", with: " ").replacingOccurrences(of: "’", with: " ")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
  var key: String { text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines) + "\0" + Self.normalizePinyin(pinyin) }

  func normalized() throws -> Self {
    var value = self
    value.text = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    value.pinyin = Self.normalizePinyin(pinyin)
    guard !value.text.isEmpty, value.text.count <= 128, !value.text.hasPrefix("#"),
          !value.text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
      throw SettingsError.invalid("词语不能为空、超过 128 字、以 # 开头或包含控制字符。")
    }
    guard value.pinyin.count <= 256,
          value.pinyin.range(of: "^[a-z]+(?: [a-z]+)*$", options: .regularExpression) != nil else {
      throw SettingsError.invalid("拼音应为无声调字母，音节用空格分隔；ü 可写成 v。")
    }
    guard (0...1_000_000_000).contains(weight) else {
      throw SettingsError.invalid("词频应为 0 到 1000000000 之间的整数。")
    }
    return value
  }
}

enum PersonalDictionaryFormat: String, CaseIterable, Identifiable {
  case csv, tsv, txt
  var id: String { rawValue }
  var delimiter: Character { self == .csv ? "," : "\t" }
  var title: String { self == .txt ? "TXT（制表符分隔）" : rawValue.uppercased() }
}

enum PersonalImportPolicy: String, CaseIterable, Identifiable {
  case keepExisting, replaceExisting, higherWeight
  var id: String { rawValue }
  var title: String {
    switch self {
    case .keepExisting: return "保留原记录"
    case .replaceExisting: return "使用导入记录"
    case .higherWeight: return "保留较高词频"
    }
  }
}

struct PersonalImportRow: Identifiable {
  let id = UUID()
  var line: Int
  var word: PersonalWord?
  var error: String?
}
struct PersonalImportPreview: Identifiable {
  let id = UUID()
  var name: String
  var rows: [PersonalImportRow]
  var ignoredLines: Int
}
struct PersonalImportDecision: Identifiable {
  enum Action: String { case added = "新增", updated = "更新", skipped = "跳过", failed = "失败" }
  var id: UUID
  var line: Int
  var word: PersonalWord?
  var action: Action
  var reason: String
}
struct PersonalImportResult {
  var words: [PersonalWord]
  var decisions: [PersonalImportDecision]
  func count(_ action: PersonalImportDecision.Action) -> Int { decisions.filter { $0.action == action }.count }
  var changedCount: Int { count(.added) + count(.updated) }
  var summary: String { "新增 \(count(.added)) · 更新 \(count(.updated)) · 跳过 \(count(.skipped)) · 失败 \(count(.failed))" }
}

enum QingTypePersonalDictionary {
  static let tableName = "qingtype_personal"
  static let maxImportBytes = 10 * 1024 * 1024
  static let maxEntries = 100_000

  static func validate(_ words: [PersonalWord]) throws {
    guard words.count <= maxEntries else { throw SettingsError.invalid("个人词库最多支持 100000 条。") }
    var keys = Set<String>(), ids = Set<UUID>()
    for word in words {
      let normalized = try word.normalized()
      guard keys.insert(normalized.key).inserted, ids.insert(word.id).inserted else {
        throw SettingsError.invalid("个人词条“\(word.text)”与已有记录重复（词语和拼音均相同）。")
      }
    }
  }

  static func upsert(_ word: PersonalWord, in words: [PersonalWord]) throws -> [PersonalWord] {
    let value = try word.normalized()
    guard !words.contains(where: { $0.id != value.id && $0.key == value.key }) else {
      throw SettingsError.invalid("已有相同词语和拼音的记录，请直接编辑那条记录。")
    }
    var result = words
    if let index = result.firstIndex(where: { $0.id == value.id }) { result[index] = value }
    else { result.append(value) }
    try validate(result)
    return result
  }

  static func dictionaryData(_ words: [PersonalWord]) throws -> Data {
    try validate(words)
    let header = QingTypeSettings.managedHeader + "---\nname: \(tableName)\nversion: '1'\nsort: by_weight\nuse_preset_vocabulary: false\ncolumns: [text, code, weight]\n...\n"
    return Data((header + (try words.map { try $0.normalized() }).map { "\($0.text)\t\($0.pinyin)\t\($0.weight)\n" }.joined()).utf8)
  }

  static func preview(url: URL) throws -> PersonalImportPreview {
    guard let format = PersonalDictionaryFormat(rawValue: url.pathExtension.lowercased()) else {
      throw SettingsError.invalid("请选择 CSV、TSV 或 TXT 个人词库文件。")
    }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= maxImportBytes else { throw SettingsError.invalid("导入文件不能超过 10 MB。") }
    let data = try Data(contentsOf: url)
    guard data.count <= maxImportBytes else { throw SettingsError.invalid("导入文件不能超过 10 MB。") }
    let text: String?
    if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { text = String(data: data, encoding: .utf16) }
    else { text = String(data: data, encoding: .utf8) }
    guard let text else { throw SettingsError.invalid("请使用 UTF-8，或带 BOM 的 UTF-16 编码保存词库。") }
    return try preview(text: text, format: format, name: url.lastPathComponent)
  }

  static func preview(text: String, format: PersonalDictionaryFormat, name: String = "导入文件") throws -> PersonalImportPreview {
    guard text.utf8.count <= maxImportBytes else { throw SettingsError.invalid("导入文件不能超过 10 MB。") }
    let records = try parse(text: text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text, delimiter: format.delimiter)
    var rows: [PersonalImportRow] = [], ignored = 0
    var columns = ["text", "pinyin", "weight"]
    var examinedHeader = false
    let aliases = ["word": "text", "text": "text", "词语": "text", "词条": "text", "pinyin": "pinyin", "code": "pinyin", "拼音": "pinyin", "编码": "pinyin", "weight": "weight", "frequency": "weight", "词频": "weight"]
    for record in records {
      if record.error == nil && (record.fields.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } || record.fields.first?.trimmingCharacters(in: .whitespaces).hasPrefix("#") == true) {
        ignored += 1
        continue
      }
      if !examinedHeader {
        examinedHeader = true
        let mapped = record.fields.map { aliases[$0.trimmingCharacters(in: .whitespaces).lowercased()] ?? "" }
        if mapped.contains("text") && mapped.contains("pinyin") {
          guard record.error == nil, !mapped.contains(""), Set(mapped).count == mapped.count else {
            throw SettingsError.invalid("表头仅支持词语、拼音、词频三种列，不能重复。")
          }
          columns = mapped
          continue
        }
      }
      do {
        if let error = record.error { throw SettingsError.invalid(error) }
        guard record.fields.count >= 2, record.fields.count <= columns.count,
              let textIndex = columns.firstIndex(of: "text"), textIndex < record.fields.count,
              let pinyinIndex = columns.firstIndex(of: "pinyin"), pinyinIndex < record.fields.count else {
          throw SettingsError.invalid("需要词语、拼音两列和可选的词频列；TSV/TXT 请用制表符分列。")
        }
        let weightText = columns.firstIndex(of: "weight").flatMap { $0 < record.fields.count ? record.fields[$0] : nil }?.trimmingCharacters(in: .whitespaces) ?? ""
        guard weightText.isEmpty || Int(weightText) != nil else { throw SettingsError.invalid("词频不是整数。") }
        let word = try PersonalWord(text: record.fields[textIndex], pinyin: record.fields[pinyinIndex], weight: Int(weightText) ?? 1000).normalized()
        rows.append(PersonalImportRow(line: record.line, word: word))
      } catch { rows.append(PersonalImportRow(line: record.line, error: error.localizedDescription)) }
    }
    return PersonalImportPreview(name: name, rows: rows, ignoredLines: ignored)
  }

  static func merge(_ preview: PersonalImportPreview, into existing: [PersonalWord], policy: PersonalImportPolicy) -> PersonalImportResult {
    var words = existing
    var indices: [String: Int] = [:]
    for (index, word) in words.enumerated() { indices[word.key] = index }
    var decisions: [PersonalImportDecision] = []
    for row in preview.rows {
      guard var value = row.word else {
        decisions.append(.init(id: row.id, line: row.line, action: .failed, reason: row.error ?? "无法读取词条。"))
        continue
      }
      if let index = indices[value.key] {
        let replace = policy == .replaceExisting || (policy == .higherWeight && value.weight > words[index].weight)
        if replace && value.weight != words[index].weight {
          value.id = words[index].id
          words[index] = value
          decisions.append(.init(id: row.id, line: row.line, word: value, action: .updated, reason: "更新相同词语和拼音的词频。"))
        } else {
          decisions.append(.init(id: row.id, line: row.line, word: value, action: .skipped, reason: "重复记录，按所选策略保留已有值。"))
        }
      } else if words.count >= maxEntries {
        decisions.append(.init(id: row.id, line: row.line, word: value, action: .failed, reason: "个人词库已达到 100000 条上限。"))
      } else {
        indices[value.key] = words.count
        words.append(value)
        decisions.append(.init(id: row.id, line: row.line, word: value, action: .added, reason: ""))
      }
    }
    return PersonalImportResult(words: words, decisions: decisions)
  }

  static func export(_ words: [PersonalWord], format: PersonalDictionaryFormat) throws -> Data {
    try validate(words)
    func quote(_ value: String) -> String {
      value.contains(format.delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r")
        ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }
    let values = try words.map { try $0.normalized() }.sorted { $0.key < $1.key }
    let rows = [["text", "pinyin", "weight"]] + values.map { [$0.text, $0.pinyin, String($0.weight)] }
    return Data((rows.map { $0.map(quote).joined(separator: String(format.delimiter)) }.joined(separator: "\r\n") + "\r\n").utf8)
  }

  static func inspectionReport(_ result: PersonalImportResult) -> Data {
    func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    let rows = [["line", "action", "text", "pinyin", "weight", "reason"]] + result.decisions.map {
      [String($0.line), $0.action.rawValue, $0.word?.text ?? "", $0.word?.pinyin ?? "", $0.word.map { String($0.weight) } ?? "", $0.reason]
    }
    return Data((rows.map { $0.map(quote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
  }

  private struct Record { var line: Int; var fields: [String]; var error: String? }
  private enum ParseState { case start, unquoted, quoted, closed }
  private static func parse(text: String, delimiter: Character) throws -> [Record] {
    var records: [Record] = [], fields: [String] = [], field = "", error: String?
    var state = ParseState.start, line = 1, startLine = 1
    var index = text.startIndex
    func finish() throws {
      fields.append(field)
      records.append(Record(line: startLine, fields: fields, error: error))
      guard records.count <= maxEntries else { throw SettingsError.invalid("导入文件最多支持 100000 条记录。") }
      fields = []; field = ""; error = nil; state = .start
    }
    while index < text.endIndex {
      let char = text[index]
      let next = text.index(after: index)
      if char == "\n" || char == "\r" || char == "\r\n" {
        if state == .quoted { field += "\n" }
        else { try finish() }
        line += 1
        if state != .quoted { startLine = line }
        if char == "\r", next < text.endIndex, text[next] == "\n" { index = text.index(after: next) }
        else { index = next }
        continue
      }
      if state == .quoted {
        if char == "\"" { state = .closed } else { field.append(char) }
      } else if state == .closed {
        if char == "\"" { field.append(char); state = .quoted }
        else if char == delimiter { fields.append(field); field = ""; state = .start }
        else if char != " " { error = "引号结束后只能接分隔符或换行。"; field.append(char) }
      } else if char == delimiter {
        fields.append(field); field = ""; state = .start
      } else if char == "\"", state == .start {
        state = .quoted
      } else {
        if char == "\"" { error = "字段中的引号需要用双引号转义。" }
        field.append(char); state = .unquoted
      }
      index = next
    }
    if state == .quoted { error = "引号未闭合。" }
    if !fields.isEmpty || !field.isEmpty || state != .start || error != nil { try finish() }
    return records
  }
}
