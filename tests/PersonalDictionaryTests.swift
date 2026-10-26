import Foundation
import Yams

@main
struct PersonalDictionaryTests {
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-personal-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var checks = 0
    func expect(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
      guard try value() else { throw SettingsError.invalid("FAIL: \(name)") }
      checks += 1
    }
    func rejects(_ operation: () throws -> Void, _ name: String) throws {
      do { try operation() } catch { checks += 1; return }
      throw SettingsError.invalid("FAIL: accepted invalid content: \(name)")
    }
    let original = try PersonalWord(text: "  绿洲  ", pinyin: "  LÜ  ZHOU  ", weight: 2000).normalized()
    try expect(original.text == "绿洲" && original.pinyin == "lv zhou", "normalization preserves Unicode and canonicalizes pinyin")
    try expect(PersonalWord.normalizePinyin("nu:'er") == "nv er", "u-colon and apostrophe normalize")
    for word in [PersonalWord(text: "", pinyin: "ci"), .init(text: "词\n条", pinyin: "ci"), .init(text: "#注释", pinyin: "ci"),
                 .init(text: "词", pinyin: "ci2"), .init(text: "词", pinyin: "ci", weight: -1), .init(text: "词", pinyin: "ci", weight: 1_000_000_001)] {
      try rejects({ _ = try word.normalized() }, "word validation")
    }
    let second = PersonalWord(text: "重行", pinyin: "chong xing")
    var words = try QingTypePersonalDictionary.upsert(original, in: [])
    words = try QingTypePersonalDictionary.upsert(second, in: words)
    var edited = original
    edited.weight = 7000
    words = try QingTypePersonalDictionary.upsert(edited, in: words)
    try expect(words.count == 2 && words[0].id == original.id && words[0].weight == 7000, "editing retains stable identity")
    try rejects({ _ = try QingTypePersonalDictionary.upsert(.init(text: "绿洲", pinyin: "lv zhou"), in: words) }, "normalized duplicate")
    let polyphone = try QingTypePersonalDictionary.upsert(.init(text: "重行", pinyin: "zhong hang"), in: words)
    try expect(polyphone.count == 3, "same text with distinct pinyin remains valid")

    let csv = "\u{feff}拼音,词语,词频\r\nlv zhou,绿洲,3000\r\nqing yan,清言,5000\r\nwrong1,错误,12\r\nqing yan,清言,9000\r\n\r\n# comment\r\n"
    let preview = try QingTypePersonalDictionary.preview(text: csv, format: .csv)
    try expect(preview.rows.count == 4 && preview.ignoredLines == 2 && preview.rows[2].line == 4 && preview.rows[2].error != nil,
               "BOM, reordered header, CRLF and invalid line numbers are preserved")
    let keep = QingTypePersonalDictionary.merge(preview, into: [original], policy: .keepExisting)
    try expect(keep.count(.added) == 1 && keep.count(.skipped) == 2 && keep.count(.failed) == 1 && keep.words[0].weight == 2000,
               "keep-existing policy handles file and stored duplicates without hiding failures")
    let replace = QingTypePersonalDictionary.merge(preview, into: [original], policy: .replaceExisting)
    try expect(replace.words[0].id == original.id && replace.words[0].weight == 3000 && replace.words[1].weight == 9000,
               "replace policy is deterministic and preserves existing IDs")
    let higher = QingTypePersonalDictionary.merge(preview, into: [edited], policy: .higherWeight)
    try expect(higher.words[0].weight == 7000 && higher.words[1].weight == 9000, "higher-weight policy retains the maximum")
    let quoted = try QingTypePersonalDictionary.preview(text: "text,pinyin,weight\n\"词,条\"\"\",ci tiao,12\n\"跨\n行\",kua hang,20\n\"未闭合,wei bi he,4", format: .csv)
    try expect(quoted.rows[0].word?.text == "词,条\"" && quoted.rows[1].error != nil && quoted.rows[2].line == 5 && quoted.rows[2].error != nil,
               "quoted delimiters and escaped quotes parse; multiline/control and unterminated fields report their starting lines")
    try rejects({ _ = try QingTypePersonalDictionary.preview(text: "text,pinyin,other\n词,ci,1", format: .csv) }, "unknown header")
    for format in PersonalDictionaryFormat.allCases {
      let exported = try QingTypePersonalDictionary.export(replace.words, format: format)
      let roundTrip = try QingTypePersonalDictionary.preview(text: String(decoding: exported, as: UTF8.self), format: format)
      try expect(roundTrip.rows.allSatisfy { $0.error == nil } && Set(roundTrip.rows.compactMap(\.word).map(\.key)) == Set(replace.words.map(\.key)),
                 "\(format.rawValue) exports round-trip without entry loss")
    }
    let tsv = root.appendingPathComponent("词库.tsv")
    try "词语\t拼音\t词频\r\n清言\tqing yan\t42\r\n".data(using: .utf16)!.write(to: tsv)
    try expect(try QingTypePersonalDictionary.preview(url: tsv).rows.first?.word?.weight == 42, "UTF-16 BOM imports from disk")
    try Data([0xff, 0x00, 0xfe]).write(to: root.appendingPathComponent("bad.csv"))
    try rejects({ _ = try QingTypePersonalDictionary.preview(url: root.appendingPathComponent("bad.csv")) }, "invalid encoding")
    let report = String(decoding: QingTypePersonalDictionary.inspectionReport(keep), as: UTF8.self)
    try expect(report.contains("失败") && report.contains("拼音应为"), "inspection export includes every failed row and reason")

    var settings = QingTypeSettings()
    settings.personalWords = replace.words
    let directory = root.appendingPathComponent("user")
    try settings.save(to: directory)
    try expect(try QingTypeSettings.load(from: directory).personalWords == settings.personalWords, "personal records survive persistence and reload")
    let files = try settings.generatedFiles()
    let header = try Yams.load(yaml: String(decoding: files["qingtype_main.dict.yaml"]!, as: UTF8.self)) as! [String: Any]
    try expect((header["import_tables"] as! [String]).contains("qingtype_personal") && String(decoding: files["qingtype_personal.dict.yaml"]!, as: UTF8.self).contains("清言\tqing yan\t9000"),
               "managed personal dictionary is integrated into the existing main table")
    let legacy = try JSONDecoder().decode(QingTypeSettings.self, from: Data("{\"fontSize\":21}".utf8))
    try expect(legacy.personalWords.isEmpty && legacy.fontSize == 21, "previous settings migrate without a personal-word field")
    var deleted = settings
    deleted.personalWords = []
    let removed = try deleted.generatedFiles()
    let removedHeader = try Yams.load(yaml: String(decoding: removed["qingtype_main.dict.yaml"]!, as: UTF8.self)) as! [String: Any]
    try expect(!(removedHeader["import_tables"] as! [String]).contains("qingtype_personal"), "deleting all personal entries removes the dictionary from active imports")

    let learning = directory.appendingPathComponent("qingtype_main.userdb/CURRENT")
    try FileManager.default.createDirectory(at: learning.deletingLastPathComponent(), withIntermediateDirectories: true)
    let sentinel = Data("private-learning-sentinel".utf8)
    try sentinel.write(to: learning)
    let before = try settings.generatedFiles()
    var draft = settings
    draft.personalWords.append(.init(text: "新词", pinyin: "xin ci", weight: 100))
    var deployCalls = 0
    func deployment(_ success: Bool) -> QingTypeDeploymentReport {
      .init(success: success, settingsHash: "test", schema: "luna_pinyin_simp", dictionaryCount: 0, message: success ? "ok" : "simulated compile failure", logDirectory: root.path)
    }
    do {
      _ = try await QingTypeConfigurationApply.apply(draft, to: directory) {
        deployCalls += 1
        return deployment(deployCalls > 1)
      }
      throw SettingsError.invalid("failed deploy was reported as successful")
    } catch let error as QingTypeApplyError {
      try expect(error.configurationRestored && error.recoveryVerified && deployCalls == 2, "failed deployment restores and verifies the previous configuration")
    }
    try expect(try before.allSatisfy { try Data(contentsOf: directory.appendingPathComponent($0.key)) == $0.value }, "rollback restores all generated files byte-for-byte")
    try expect(try Data(contentsOf: learning) == sentinel, "save and rollback never mutate learning data")
    _ = try await QingTypeConfigurationApply.apply(draft, to: directory) { deployment(true) }
    try expect(try QingTypeSettings.load(from: directory).personalWords == draft.personalWords, "successful transaction persists new records")

    do {
      _ = try await QingTypeConfigurationApply.apply(settings, to: directory) { deployment(false) }
      throw SettingsError.invalid("expected recovery failure")
    } catch let error as QingTypeApplyError {
      try expect(error.configurationRestored && !error.recoveryVerified, "failed recovery compilation is distinguished from verified rollback")
    }
    let manual = Data("patch:\n  menu/page_size: 8\n".utf8)
    do {
      _ = try await QingTypeConfigurationApply.apply(settings, to: directory) {
        try manual.write(to: directory.appendingPathComponent("default.custom.yaml"), options: .atomic)
        return deployment(false)
      }
      throw SettingsError.invalid("expected concurrent edit detection")
    } catch let error as QingTypeApplyError {
      try expect(!error.configurationRestored && !error.recoveryVerified, "concurrent external changes stop rollback rather than being overwritten")
    }
    try expect(try Data(contentsOf: directory.appendingPathComponent("default.custom.yaml")) == manual && Data(contentsOf: learning) == sentinel,
               "external manual configuration and learning data remain intact")
    var unexpectedDeployment = false
    do {
      _ = try await QingTypeConfigurationApply.apply(settings, to: directory) {
        unexpectedDeployment = true
        return deployment(true)
      }
      throw SettingsError.invalid("expected manual ownership rejection")
    } catch is SettingsError {
      try expect(!unexpectedDeployment && (try Data(contentsOf: directory.appendingPathComponent("default.custom.yaml"))) == manual,
                 "rejected writes leave configuration unchanged and never invoke deployment")
    }
    print("PASS: \(checks) personal dictionary, import/export and deployment-transaction checks")
  }
}
