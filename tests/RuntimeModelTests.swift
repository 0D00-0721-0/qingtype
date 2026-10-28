import Foundation
import Yams

@main
struct RuntimeModelTests {
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("qingtype-runtime-test-\(UUID())")
    try fm.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    var checks = 0
    func expect(_ condition: Bool, _ name: String) throws {
      guard condition else { throw SettingsError.invalid("FAIL: \(name)") }; checks += 1
    }
    let source = root.appendingPathComponent("source.gram")
    var bytes = Data(repeating: 0x61, count: 2048)
    bytes.replaceSubrange(0..<17, with: Data("Rime::Grammar/1.0".utf8))
    bytes.replaceSubrange(36..<44, with: [1, 0, 0, 0, 4, 0, 0, 0])
    try bytes.write(to: source)
    let asset = try QingTypeContent.importGrammar(from: source, into: root)
    var settings = QingTypeSettings(); settings.models = [asset]; settings.activeModelID = asset.id
    try settings.save(to: root)
    let schema = root.appendingPathComponent("build/luna_pinyin_simp.schema.yaml")
    let schemaText = "schema:\n  schema_id: luna_pinyin_simp\ngrammar:\n  language: \(asset.language)\n  collocation_prism: qingtype_luna_pinyin_simp.prism\n"
    try schemaText.write(to: schema, atomically: true, encoding: .utf8)
    let model = root.appendingPathComponent(asset.language + ".gram")
    let savedSettings = try Data(contentsOf: root.appendingPathComponent("settings.json"))
    let privateData = root.appendingPathComponent("learning-sentinel.userdb")
    try Data("learning fixture".utf8).write(to: privateData)
    let normal = try QingTypeRuntimeModel.prepare(in: root)
    try expect(normal.stagingDirectory == nil, "valid model uses normal staging")
    try Data("damaged".utf8).write(to: model)
    let fallback = try QingTypeRuntimeModel.prepare(in: root)
    guard let stage = fallback.stagingDirectory else { throw SettingsError.invalid("corrupt model must use fallback") }
    defer { try? fm.removeItem(at: stage.deletingLastPathComponent()) }
    let parsed = try Yams.load(yaml: String(contentsOf: stage.appendingPathComponent(schema.lastPathComponent), encoding: .utf8)) as? [String: Any]
    let grammar = parsed?["grammar"] as? [String: Any]
    try expect((grammar?["language"] as? String ?? "").isEmpty, "fallback compiled schema disables language model")
    try expect(try Data(contentsOf: schema) == Data(schemaText.utf8), "fallback leaves original compiled schema intact")
    try expect(try Data(contentsOf: root.appendingPathComponent("settings.json")) == savedSettings, "fallback leaves settings intact")
    try expect(try Data(contentsOf: model) == Data("damaged".utf8), "fallback preserves damaged model for recovery")
    try expect(try Data(contentsOf: privateData) == Data("learning fixture".utf8), "fallback preserves unrelated learning data")
    try QingTypeRuntimeModel.recordStatus(fallback.warning, in: root)
    try expect(QingTypeRuntimeModel.readStatus(in: root)?.message == fallback.warning, "model warning is visible to settings")
    try fm.removeItem(at: model)
    let missing = try QingTypeRuntimeModel.prepare(in: root)
    try expect(missing.stagingDirectory != nil, "missing model also falls back")
    if let stage = missing.stagingDirectory { try fm.removeItem(at: stage.deletingLastPathComponent()) }
    try fm.removeItem(at: schema)
    var noSchemaRejected = false
    do { _ = try QingTypeRuntimeModel.prepare(in: root) } catch { noSchemaRejected = true }
    try expect(noSchemaRejected, "fallback refuses to start without the selected compiled schema")
    try schemaText.write(to: schema, atomically: true, encoding: .utf8)
    try bytes.write(to: model)
    let repaired = try QingTypeRuntimeModel.prepare(in: root)
    try expect(repaired.stagingDirectory == nil, "repaired model returns to normal startup")
    try QingTypeRuntimeModel.recordStatus(repaired.warning, in: root)
    try expect(QingTypeRuntimeModel.readStatus(in: root)?.message == nil, "successful startup clears the previous warning")
    let externalSchema = root.appendingPathComponent("external.schema.yaml")
    try "schema:\n  schema_id: external\ngrammar:\n  language: unverified\n".write(to: externalSchema, atomically: true, encoding: .utf8)
    let changedSource = try QingTypeRuntimeModel.prepare(in: root)
    try expect(changedSource.stagingDirectory != nil, "unverified model in source schema cannot be compiled during normal startup")
    if let stage = changedSource.stagingDirectory { try fm.removeItem(at: stage.deletingLastPathComponent()) }
    try fm.removeItem(at: externalSchema)
    let custom = root.appendingPathComponent("external.custom.yaml")
    try "patch:\n  grammar/language: unverified\n".write(to: custom, atomically: true, encoding: .utf8)
    let changedPatch = try QingTypeRuntimeModel.prepare(in: root)
    try expect(changedPatch.stagingDirectory != nil, "unverified model in a custom patch cannot be compiled during normal startup")
    if let stage = changedPatch.stagingDirectory { try fm.removeItem(at: stage.deletingLastPathComponent()) }
    try fm.removeItem(at: custom)
    settings.activeModelID = nil
    try settings.save(to: root)
    let stale = try QingTypeRuntimeModel.prepare(in: root)
    try expect(stale.stagingDirectory != nil, "stale compiled model cannot run when disabled in settings")
    if let stage = stale.stagingDirectory { try fm.removeItem(at: stage.deletingLastPathComponent()) }
    try fm.removeItem(at: schema)
    try fm.createSymbolicLink(at: schema, withDestinationURL: source)
    var rejected = false
    do { _ = try QingTypeRuntimeModel.prepare(in: root) } catch { rejected = true }
    try expect(rejected, "linked compiled schema is not followed or overwritten")
    print("PASS: \(checks) startup model verification and fallback checks")
  }
}
