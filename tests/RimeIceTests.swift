import Foundation
import Yams

@main
struct RimeIceTests {
  static func main() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("qingtype-ice-tests-\(UUID())")
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    var checks = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
      guard try condition() else { throw SettingsError.invalid("FAIL: \(name)") }
      checks += 1
    }
    func rejects(_ operation: () throws -> Void, _ name: String) throws {
      do { try operation() } catch { checks += 1; return }
      throw SettingsError.invalid("FAIL: accepted \(name)")
    }
    let source = root.appendingPathComponent("source")
    let user = root.appendingPathComponent("user")
    func write(_ name: String, _ value: String) throws {
      let url = source.appendingPathComponent(name)
      try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try value.write(to: url, atomically: true, encoding: .utf8)
    }
    let ice = "schema:\n  schema_id: rime_ice\n  version: 'fixture'\n  dependencies: [melt_eng, radical_pinyin]\nengine:\n  translators: [lua_translator@*date_translator]\nkey_binder:\n  import_preset: default\npunctuator:\n  __include: default:/punctuator\n"
    try write("rime_ice.schema.yaml", ice)
    for id in ["melt_eng", "radical_pinyin"] { try write(id + ".schema.yaml", "schema:\n  schema_id: \(id)\n") }
    try write("rime_ice.dict.yaml", "---\nname: rime_ice\nversion: '1'\nimport_tables: [cn_dicts/base]\n...\n")
    try write("cn_dicts/base.dict.yaml", "---\nname: base\nversion: '1'\nimport_tables: [cn_dicts/extra]\n...\n你好\tni hao\t100\n")
    try write("cn_dicts/extra.dict.yaml", "---\nname: extra\nversion: '1'\n...\n星河\txing he\t1\n")
    try write("melt_eng.dict.yaml", "---\nname: melt_eng\nimport_tables: [en_dicts/en]\n...\n")
    try write("en_dicts/en.dict.yaml", "---\nname: en\n...\nhello\thello\t1\n")
    try write("radical_pinyin.dict.yaml", "---\nname: radical_pinyin\n...\n你\tren er\t1\n")
    try write("lua/date_translator.lua", "return function() end")
    try write("lua/lunar.db", "static calendar fixture")
    try write("opencc/emoji.json", "{}")
    try write("default.yaml", "config_version: '1'\nkey_binder:\n  bindings: []\n")
    try write("LICENSE", "GPL-3.0 fixture")
    try write("squirrel.yaml", "never copy this")
    try write("custom_phrase.txt", "never copy this")
    try write("rime_ice.userdb/CURRENT", "private upstream learning")
    var settings = QingTypeSettings()
    try settings.save(to: user)
    let before = try settings.generatedFiles()
    let learning = user.appendingPathComponent("rime_ice.userdb/CURRENT")
    try manager.createDirectory(at: learning.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("private-user-learning".utf8).write(to: learning)
    let installation = try QingTypeRimeIce.installPackage(from: source, into: user)
    let asset = installation.asset
    try expect(asset.tables == ["rime_ice", "cn_dicts/base", "cn_dicts/extra"], "recursive table imports are flattened")
    try expect(try before.allSatisfy { try Data(contentsOf: user.appendingPathComponent($0.key)) == $0.value }, "installation leaves existing generated settings and phrases intact")
    try expect(try String(contentsOf: learning, encoding: .utf8) == "private-user-learning", "learning is never copied from source or reset")
    try expect(!manager.fileExists(atPath: user.appendingPathComponent("squirrel.yaml").path) && manager.fileExists(atPath: user.appendingPathComponent("qingtype_ice_defaults.yaml").path), "client configuration is excluded and defaults are isolated")
    let schema = try String(contentsOf: user.appendingPathComponent("rime_ice.schema.yaml"), encoding: .utf8)
    try expect(schema.contains("qingtype_ice_defaults:/punctuator") && schema.contains("import_preset: qingtype_ice_defaults"), "default references are namespaced")
    try expect(try asset.files.allSatisfy { try QingTypeContent.digest(of: user.appendingPathComponent($0.path)) == $0.sha256 }, "manifest hashes match installed bytes")
    try expect(QingTypeRimeIce.installed(in: user) == asset, "manifest round-trip")

    // A repeat install must not rewrite unchanged bytes or leave staging dirs.
    let stableFile = user.appendingPathComponent("cn_dicts/base.dict.yaml")
    let sentinel = Date(timeIntervalSince1970: 1_000_000)
    try manager.setAttributes([.modificationDate: sentinel], ofItemAtPath: stableFile.path)
    _ = try QingTypeRimeIce.installPackage(from: source, into: user)
    var afterStat = stat()
    _ = stat(stableFile.path, &afterStat)
    try expect(afterStat.st_mtimespec.tv_sec == Int(sentinel.timeIntervalSince1970),
               "repeat install skips unchanged files")
    try expect(try manager.contentsOfDirectory(atPath: user.path).filter { $0.hasPrefix(".ice-stage-") }.isEmpty,
               "repeat install leaves no staging directory")

    // The update check compares the official archive checksum before downloading.
    let digestA = String(repeating: "a", count: 64)
    let digestB = String(repeating: "b", count: 64)
    func release(_ name: String, _ digest: String?) -> QingTypeRelease {
      .init(tag_name: "nightly", assets: [.init(name: name,
        browser_download_url: URL(string: "https://github.com/iDvel/rime-ice/releases/download/nightly/full.zip")!,
        size: 1024, digest: digest.map { "sha256:" + $0 })])
    }
    var official = asset
    official.archiveSHA256 = digestA
    try expect(try QingTypeRimeIceUpdates.inspect(release: release("full.zip", digestA), installed: official).upToDate,
               "matching archive checksum means up to date")
    try expect(try !QingTypeRimeIceUpdates.inspect(release: release("full.zip", digestB), installed: official).upToDate,
               "a different archive checksum means an update")
    try expect(try !QingTypeRimeIceUpdates.inspect(release: release("full.zip", digestA), installed: nil).upToDate,
               "no installed package always needs an install")
    try rejects({ _ = try QingTypeRimeIceUpdates.inspect(release: release("other.zip", digestA), installed: official) },
                "missing official package asset")
    try expect(try String(contentsOf: user.appendingPathComponent("lua/lunar.db"), encoding: .utf8) == "static calendar fixture", "static lunar database is included without copying user-learning databases")
    settings.rimeIce = asset
    settings.schema = "rime_ice"
    settings.personalWords = [.init(text: "样词", pinyin: "yang ci", weight: 999)]
    let generated = try settings.generatedFiles()
    let main = String(decoding: generated[QingTypeRimeIce.dictionaryName + ".dict.yaml"]!, as: UTF8.self)
    try expect(main.contains("qingtype_personal") && main.contains("cn_dicts/extra"), "personal and official tables are combined")
    let patch = String(decoding: generated["rime_ice.custom.yaml"]!, as: UTF8.self)
    try expect(patch.contains("translator/user_dict: rime_ice") && patch.contains("radical_reverse_lookup/dictionary: qingtype_ice_main"), "stable learning name and reverse lookup use the correct dictionaries")
    try settings.save(to: user)
    try expect(try QingTypeSettings.load(from: user) == settings, "scheme metadata and personal words survive reload")
    try manager.removeItem(at: user.appendingPathComponent("lua/date_translator.lua"))
    try rejects({ try settings.save(to: user) }, "missing installed dependency")
    try Data("return function() end".utf8).write(to: user.appendingPathComponent("lua/date_translator.lua"))
    let manifestBeforeAgain = QingTypeRimeIce.installed(in: user)
    let again = try QingTypeRimeIce.installPackage(from: source, into: user)
    try QingTypeRimeIce.rollback(again, in: user)
    try expect(QingTypeRimeIce.installed(in: user) == manifestBeforeAgain, "package rollback restores previous manifest")
    try write("lua/date_translator.lua", "return function() return 'new' end")
    let changed = try QingTypeRimeIce.installPackage(from: source, into: user)
    try expect(try String(contentsOf: user.appendingPathComponent("lua/date_translator.lua"), encoding: .utf8).contains("new"), "owned package files can update")
    try QingTypeRimeIce.rollback(changed, in: user)
    try expect(try String(contentsOf: user.appendingPathComponent("lua/date_translator.lua"), encoding: .utf8) == "return function() end", "failed activation restores previous resources")
    try "manual edit".write(to: user.appendingPathComponent("lua/date_translator.lua"), atomically: true, encoding: .utf8)
    try rejects({ _ = try QingTypeRimeIce.install(from: source, into: user) }, "manually modified resource")
    try expect(try String(contentsOf: user.appendingPathComponent("lua/date_translator.lua"), encoding: .utf8) == "manual edit", "resource conflicts preserve manual edits")
    let other = root.appendingPathComponent("other")
    try manager.removeItem(at: source.appendingPathComponent("melt_eng.schema.yaml"))
    try rejects({ _ = try QingTypeRimeIce.install(from: source, into: other) }, "missing schema dependency")
    try write("melt_eng.schema.yaml", "schema:\n  schema_id: melt_eng\n")
    try manager.removeItem(at: source.appendingPathComponent("lua/date_translator.lua"))
    try rejects({ _ = try QingTypeRimeIce.install(from: source, into: other) }, "missing autoload Lua module")
    try write("lua/date_translator.lua", "return function() end")
    try write("cn_dicts/extra.dict.yaml", "---\nname: extra\nimport_tables: [cn_dicts/base]\n...\n")
    try rejects({ _ = try QingTypeRimeIce.install(from: source, into: other) }, "dictionary cycle")
    try write("cn_dicts/extra.dict.yaml", "---\nname: extra\nimport_tables: [../escape]\n...\n")
    try rejects({ _ = try QingTypeRimeIce.install(from: source, into: other) }, "traversing dictionary reference")
    try write("cn_dicts/extra.dict.yaml", "---\nname: extra\n...\n")
    try manager.createDirectory(at: other, withIntermediateDirectories: true)
    try manager.createSymbolicLink(at: other.appendingPathComponent("lua"), withDestinationURL: root)
    try rejects({ _ = try QingTypeRimeIce.install(from: source, into: other) }, "destination parent symlink escaping data directory")
    try manager.removeItem(at: source.appendingPathComponent("lua/date_translator.lua"))
    try manager.createSymbolicLink(at: source.appendingPathComponent("lua/date_translator.lua"), withDestinationURL: learning)
    try rejects({ _ = try QingTypeRimeIce.install(from: source, into: other) }, "source symlink")
    try rejects({ try QingTypeRimeIceDownload.validateZIP(Data("not a zip".utf8)) }, "malformed zip")
    let archive = root.appendingPathComponent("fixture.zip")
    let zip = Process(); zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.arguments = ["-q", archive.path, "LICENSE"]; zip.currentDirectoryURL = source
    try zip.run(); zip.waitUntilExit()
    var zipData = try Data(contentsOf: archive)
    try QingTypeRimeIceDownload.validateZIP(zipData); checks += 1
    // Mutate a valid local/central name into a traversal with the same byte count.
    let originalName = Data("LICENSE".utf8), unsafe = Data("../evil".utf8)
    while let range = zipData.range(of: originalName) { zipData.replaceSubrange(range, with: unsafe) }
    try rejects({ try QingTypeRimeIceDownload.validateZIP(zipData) }, "zip traversal")
    try expect(try String(contentsOf: learning, encoding: .utf8) == "private-user-learning", "all failure paths preserve learning data")
    print("PASS: \(checks) Rime Ice package, isolation, rollback and archive checks")
  }
}
