import Foundation
import Yams

@main
struct ContentTests {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-content-tests-\(UUID())")
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("user")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var checks = 0
    func expect(_ condition: Bool, _ message: String) throws {
      guard condition else { throw SettingsError.invalid("FAIL: \(message)") }
      checks += 1
    }
    func rejects(_ action: () throws -> Void) throws {
      do { try action() } catch { checks += 1; return }
      throw SettingsError.invalid("Expected invalid content to be rejected")
    }
    let leaf = "---\nname: term\nversion: '1'\n...\n自定义词库\tzi ding yi ci ku\t1000\n"
    try leaf.write(to: source.appendingPathComponent("nested/term.dict.yaml"), atomically: true, encoding: .utf8)
    let aggregate = "---\nname: package\nversion: '1'\nimport_tables:\n  - nested/term\n...\n"
    let input = source.appendingPathComponent("package.dict.yaml")
    try aggregate.write(to: input, atomically: true, encoding: .utf8)
    let imported = try QingTypeContent.importDictionary(from: input, into: destination)
    try expect(imported.tables.count == 2 && imported.wordCount == 1, "recursive dependency package is flattened")
    try expect(imported.tables.allSatisfy { FileManager.default.fileExists(atPath: destination.appendingPathComponent($0 + ".dict.yaml").path) },
               "all imported files are owned copies")
    var settings = QingTypeSettings()
    settings.dictionaries = [imported]
    try settings.save(to: destination)
    let generated = try settings.generatedFiles()
    let parsed = try Yams.load(yaml: String(decoding: generated["qingtype_main.dict.yaml"]!, as: UTF8.self)) as! [String: Any]
    try expect((parsed["import_tables"] as! [String]).count == 3, "all dictionary tables are included alongside the base")
    settings.dictionaries[0].enabled = false
    let disabled = try settings.generatedFiles()
    let without = try Yams.load(yaml: String(decoding: disabled["qingtype_main.dict.yaml"]!, as: UTF8.self)) as! [String: Any]
    try expect((without["import_tables"] as! [String]) == ["luna_pinyin"], "disabling a dictionary removes its tables")
    try expect(try String(contentsOf: input, encoding: .utf8) == aggregate, "source dictionary stays intact")

    try "---\nname: cycle\nimport_tables: [cycle]\n...\n".write(to: source.appendingPathComponent("cycle.dict.yaml"), atomically: true, encoding: .utf8)
    try rejects { _ = try QingTypeContent.importDictionary(from: source.appendingPathComponent("cycle.dict.yaml"), into: destination) }
    try "---\nname: escape\nimport_tables: [../outside]\n...\n".write(to: source.appendingPathComponent("escape.dict.yaml"), atomically: true, encoding: .utf8)
    try rejects { _ = try QingTypeContent.importDictionary(from: source.appendingPathComponent("escape.dict.yaml"), into: destination) }
    try "---\nname: missing\nimport_tables: [not_here]\n...\n".write(to: source.appendingPathComponent("missing.dict.yaml"), atomically: true, encoding: .utf8)
    try rejects { _ = try QingTypeContent.importDictionary(from: source.appendingPathComponent("missing.dict.yaml"), into: destination) }
    let fakeModel = source.appendingPathComponent("broken.gram")
    var fake = Data("Rime::Grammar/1.0".utf8)
    fake.append(Data(repeating: 0, count: 2048))
    try fake.write(to: fakeModel)
    try rejects { _ = try QingTypeContent.importGrammar(from: fakeModel, into: destination) }

    // Migration from the previous settings format preserves user's choices.
    let previous = Data("{\"schema\":\"luna_pinyin_simp\",\"fontSize\":21,\"layout\":\"stacked\"}".utf8)
    let migrated = try JSONDecoder().decode(QingTypeSettings.self, from: previous)
    try expect(migrated.fontSize == 21 && migrated.layout == "stacked" && migrated.useSystemCandidates,
               "old preferences survive while system candidates become the default")
    let report = QingTypeDeploymentReport(success: true, settingsHash: "test", schema: "test", dictionaryCount: 1,
                                           modelLanguage: "test-model", message: "", logDirectory: "")
    let load = "use grammar: test-model\ngram_db.cc:14] loading gram db: /tmp/test-model.gram\n"
    try expect(!report.modelWasLoaded(in: load + "prism.cc:121] found double array image of size 1792."),
               "a loaded spelling index cannot be mistaken for a loaded model")
    try expect(report.modelWasLoaded(in: load + "gram_db.cc:44] found double array image of size 100."),
               "plugin stderr can provide positive model-load evidence")
    try expect(!report.modelWasLoaded(in: load + "gram_db.cc:44] found double array image of size 100.\nfailed to load grammar database: test-model"),
               "a model-load error prevents a success status")
    print("PASS: \(checks) content and migration checks")
  }
}
