import Foundation
import Yams

@main
struct LearningTests {
  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("qingtype-learning-safety-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    var checks = 0
    func expect(_ result: Bool, _ message: String) throws {
      guard result else { throw SettingsError.invalid("FAIL: \(message)") }
      checks += 1
    }
    func rejects(_ operation: () throws -> Void) throws {
      do { try operation() } catch { checks += 1; return }
      throw SettingsError.invalid("Expected operation to be rejected")
    }
    let snapshot = QingTypeLearningSnapshot(name: "qingtype_main", data: Data("# Rime user dictionary\n#@/db_name\tqingtype_main\n#@/db_type\tuserdb\n#@/tick\t3\nqing yan \t清言\tc=3 d=3 t=3\n".utf8))
    let backup = QingTypeLearningBackup(rimeVersion: "test", snapshots: [snapshot])
    let file = root.appendingPathComponent("test.qinglearning")
    try backup.write(to: file)
    try expect(try QingTypeLearningBackup.load(file).snapshots[0].data == snapshot.data, "portable backup preserves full Rime snapshot bytes")
    try expect((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "learning backup is private to the current user")
    var corrupt = backup; corrupt.snapshots[0].data.append(0)
    try rejects { try corrupt.validate() }
    var traversal = backup; traversal.snapshots[0].name = "../Rime"
    try rejects { try traversal.validate() }
    var mismatch = backup
    mismatch.snapshots[0] = QingTypeLearningSnapshot(name: "other", data: snapshot.data)
    try rejects { try mismatch.validate() }
    var duplicate = backup; duplicate.snapshots.append(snapshot)
    try rejects { try duplicate.validate() }
    var caseAlias = backup
    caseAlias.snapshots.append(QingTypeLearningSnapshot(name: "QINGTYPE_MAIN", data: Data(String(decoding: snapshot.data, as: UTF8.self).replacingOccurrences(of: "qingtype_main", with: "QINGTYPE_MAIN").utf8)))
    try rejects { try caseAlias.validate() }
    var unknown = backup; unknown.version = 100
    try rejects { try unknown.validate() }
    let badRecord = QingTypeLearningSnapshot(name: "qingtype_main", data: Data("#@/db_name\tqingtype_main\n#@/db_type\tuserdb\nqing yan \t清言\tbroken\n".utf8))
    try rejects { try badRecord.validate() }
    let overflow = QingTypeLearningSnapshot(name: "qingtype_main", data: Data(String(decoding: snapshot.data, as: UTF8.self).replacingOccurrences(of: "d=3", with: "d=3e99999").utf8))
    try rejects { try overflow.validate() }
    try rejects { try backup.write(to: root.appendingPathComponent("settings.json")) }
    let destination = root.appendingPathComponent("outside.qinglearning")
    try fm.createSymbolicLink(at: destination, withDestinationURL: file)
    try rejects { try backup.write(to: destination) }

    var settings = QingTypeSettings()
    try expect(settings.learningEnabled, "learning is enabled for new profiles")
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
    json.removeValue(forKey: "learningEnabled")
    try expect(try JSONDecoder().decode(QingTypeSettings.self, from: JSONSerialization.data(withJSONObject: json)).learningEnabled,
               "legacy profiles keep learning enabled")
    settings.learningEnabled = false
    let generated = try settings.generatedFiles()
    for name in ["luna_pinyin", "luna_pinyin_simp", "qingtype_double_pinyin"] {
      let object = try Yams.load(yaml: String(decoding: generated[name + ".custom.yaml"]!, as: UTF8.self)) as! [String: Any]
      let patch = object["patch"] as! [String: Any]
      try expect(patch["translator/user_dict"] as? String == "qingtype_main" && patch["translator/enable_user_dict"] as? Bool == false,
                 "supported base schemas retain the stable database identity and learning switch")
    }
    let user = root.appendingPathComponent("user")
    try fm.createDirectory(at: user, withIntermediateDirectories: false)
    let db = user.appendingPathComponent("qingtype_main.userdb")
    try fm.createDirectory(at: db, withIntermediateDirectories: false)
    let sentinel = Data("private-learning-sentinel".utf8)
    try sentinel.write(to: db.appendingPathComponent("CURRENT"))
    let config = user.appendingPathComponent("settings.json")
    try Data("private-settings-sentinel".utf8).write(to: config)
    try rejects { try QingTypeLearning.replace(in: user, targets: [config]) }
    let localSnapshot = user.appendingPathComponent("sync/fixture/qingtype_main.userdb.txt")
    try fm.createDirectory(at: localSnapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
    try snapshot.data.write(to: localSnapshot)
    let targets = try QingTypeLearning.resetTargets(in: user, includeBackups: false)
    let paths = targets.map { $0.resolvingSymlinksInPath().path }
    try expect(paths.contains(db.resolvingSymlinksInPath().path) && paths.contains(localSnapshot.resolvingSymlinksInPath().path) && !paths.contains(config.resolvingSymlinksInPath().path), "reset includes local sync learning but excludes configuration")
    try rejects { try QingTypeLearning.replace(in: user, targets: targets, afterMove: { throw SettingsError.invalid("injected mid-operation failure") }) }
    try expect(try Data(contentsOf: db.appendingPathComponent("CURRENT")) == sentinel && Data(contentsOf: localSnapshot) == snapshot.data,
               "partial reset failure restores original databases and sync snapshots")
    try expect(!((try fm.contentsOfDirectory(at: user, includingPropertiesForKeys: nil)).contains { $0.lastPathComponent.hasPrefix(".learning-recovery-") }),
               "verified recovery removes its temporary private data")
    let ice = user.appendingPathComponent("rime_ice.userdb")
    let staged = root.appendingPathComponent("staged")
    let newMain = staged.appendingPathComponent("qingtype_main.userdb")
    let newIce = staged.appendingPathComponent("rime_ice.userdb")
    for folder in [ice, newMain, newIce] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    try sentinel.write(to: ice.appendingPathComponent("CURRENT"))
    try Data("replacement".utf8).write(to: newMain.appendingPathComponent("CURRENT"))
    var moves = 0
    try rejects {
      try QingTypeLearning.replace(in: user, targets: [db, ice], replacements: ["qingtype_main": newMain, "rime_ice": newIce]) {
        moves += 1
        if moves == 2 { try fm.removeItem(at: newIce) }
      }
    }
    try expect(try Data(contentsOf: db.appendingPathComponent("CURRENT")) == sentinel && Data(contentsOf: ice.appendingPathComponent("CURRENT")) == sentinel,
               "failure after one replacement restores both original learning databases")
    let link = user.appendingPathComponent("linked.userdb")
    try fm.createSymbolicLink(at: link, withDestinationURL: db)
    try rejects { _ = try QingTypeLearning.databases(in: user) }
    try fm.removeItem(at: link)
    try "sync_dir: /Library/Rime\n".write(to: user.appendingPathComponent("installation.yaml"), atomically: true, encoding: .utf8)
    try rejects { _ = try QingTypeLearning.resetTargets(in: user, includeBackups: true) }
    try fm.removeItem(at: user.appendingPathComponent("installation.yaml"))
    let localBackup = try QingTypeLearning.makeBackupURL(in: user)
    try backup.write(to: localBackup)
    let erase = try QingTypeLearning.resetTargets(in: user, includeBackups: true)
    try QingTypeLearning.replace(in: user, targets: erase)
    try expect(try QingTypeLearning.databases(in: user).isEmpty && !fm.fileExists(atPath: localSnapshot.path) && !fm.fileExists(atPath: localBackup.path),
               "privacy clear includes active records, sync snapshots and local learning backups")
    try expect(try Data(contentsOf: config) == Data("private-settings-sentinel".utf8), "privacy clear preserves unrelated private settings")
    let linkedRoot = root.appendingPathComponent("linked-user")
    try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: user)
    try rejects { _ = try QingTypeDataLock(directory: linkedRoot, exclusive: true) }
    var reader: QingTypeDataLock? = try QingTypeDataLock(directory: user, exclusive: false)
    try rejects { _ = try QingTypeDataLock(directory: user, exclusive: true) }
    reader = nil
    var writer: QingTypeDataLock? = try QingTypeDataLock(directory: user, exclusive: true)
    try rejects { _ = try QingTypeDataLock(directory: user, exclusive: false) }
    writer = nil
    let pending = user.appendingPathComponent(".learning-recovery-fixture")
    try fm.createDirectory(at: pending, withIntermediateDirectories: false)
    try rejects { _ = try QingTypeDataLock(directory: user, exclusive: false) }
    withExtendedLifetime((reader, writer)) {}
    print("PASS: \(checks) learning backup validation, privacy boundaries, transaction recovery and runtime-lock checks")
  }
}
