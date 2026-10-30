import Foundation

@main
struct WanxiangUpdateTests {
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("qingtype-model-update-test-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    var checks = 0
    func expect(_ condition: Bool, _ name: String) throws {
      guard condition else { throw SettingsError.invalid("FAIL: \(name)") }; checks += 1
    }
    func rejects(_ body: () throws -> Void) throws {
      do { try body() } catch { checks += 1; return }
      throw SettingsError.invalid("Invalid model update was accepted")
    }
    let payload = Data(repeating: 0x61, count: 2048)
    let source = root.appendingPathComponent("fixture.gram")
    try payload.write(to: source)
    let hash = try QingTypeContent.digest(of: source)
    let model = GrammarAsset(id: hash, name: "local-name", language: "qingtype_model_" + hash,
                             byteCount: Int64(payload.count), sha256: hash, variant: "hans")
    let file = root.appendingPathComponent(model.language + ".gram")
    try payload.write(to: file)
    func asset(schema: String = "luna_pinyin_simp", hash: String = hash) -> QingTypeRelease.Asset {
      let name = QingTypeWanxiang.filename(schema: schema)
      return .init(name: name, browser_download_url: URL(string: "https://github.com/\(QingTypeWanxiang.repository)/releases/download/LTS/\(name)")!,
                   size: Int64(payload.count), digest: "sha256:" + hash)
    }
    let official = QingTypeRelease(tag_name: "LTS", assets: [asset()])
    func inspect(_ release: QingTypeRelease = official, models: [GrammarAsset] = [model], schema: String = "luna_pinyin_simp", directory: URL = root) throws -> QingTypeWanxiang.Update {
      try QingTypeWanxiang.inspect(release: release, schema: schema, models: models, directory: directory)
    }
    let names = try fm.contentsOfDirectory(atPath: root.path)
    let current = try inspect()
    try expect(current.installed?.id == model.id, "matching official checksum reuses an installed model, including a locally imported alias")
    try expect(current.asset.digest == official.assets[0].digest && current.release == "LTS", "download plan retains the exact inspected asset and release")
    try expect(try fm.contentsOfDirectory(atPath: root.path) == names && Data(contentsOf: file) == payload, "current-model inspection creates no download, copied file or configuration")

    var settings = QingTypeSettings(); settings.models = [model]; settings.activeModelID = nil
    let before = settings
    try expect(try inspect(models: settings.models).installed != nil && settings == before && settings.activeModelID == nil,
               "already-installed latest model does not enable a disabled model or change preferences")
    let fresh = try inspect(models: [])
    try expect(fresh.installed == nil, "first installation proceeds to download")
    let newHash = String(repeating: "b", count: 64)
    let update = try inspect(.init(tag_name: "LTS", assets: [asset(hash: newHash)]))
    try expect(update.installed == nil && update.asset.digest == "sha256:" + newHash, "a changed official hash downloads the new asset and retains the old local file")
    try expect(try Data(contentsOf: file) == payload, "checking a new upstream model leaves the existing model untouched")
    try fm.removeItem(at: file)
    try expect(try inspect().installed == nil, "missing local model is downloaded even if old metadata remains")
    try payload.write(to: file)

    var damaged = payload; damaged[0] = 0x62
    try damaged.write(to: file)
    try expect(try inspect().installed == nil, "corrupt local model schedules a verified download instead of being called current")
    try expect(try Data(contentsOf: file) == damaged, "inspection leaves corrupt local file unchanged until verified replacement")
    try payload.write(to: file)
    var noDigest = official; noDigest.assets[0].digest = nil
    try rejects { _ = try inspect(noDigest) }
    var foreign = official; foreign.assets[0].browser_download_url = URL(string: "https://example.com/model.gram")!
    try rejects { _ = try inspect(foreign) }
    var tooLarge = official; tooLarge.assets[0].size = QingTypeWanxiang.downloadLimit + 1
    try rejects { _ = try inspect(tooLarge) }
    try rejects { _ = try inspect(.init(tag_name: "nightly", assets: official.assets)) }
    try rejects { _ = try inspect(.init(tag_name: "LTS", assets: [])) }
    try rejects { _ = try inspect(schema: "luna_pinyin") }
    let both = QingTypeRelease(tag_name: "LTS", assets: [asset(schema: "luna_pinyin", hash: newHash), asset()])
    try expect(try inspect(both, schema: "rime_ice").installed != nil, "simplified and Ice schemes compare the simplified model")
    try expect(try inspect(both, schema: "luna_pinyin").asset.name == "wanxiang-lts-zh-hant.gram", "traditional schema checks the traditional model only")
    let alias = root.appendingPathComponent("linked-profile")
    try fm.createSymbolicLink(at: alias, withDestinationURL: root)
    try rejects { _ = try inspect(directory: alias) }
    try fm.removeItem(at: file)
    try fm.createSymbolicLink(at: file, withDestinationURL: source)
    try rejects { _ = try inspect() }
    print("PASS: \(checks) Wanxiang checksum, no-download, first-install, integrity and variant update checks")
  }
}
