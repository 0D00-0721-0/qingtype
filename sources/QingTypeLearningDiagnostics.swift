import Foundation
import Yams

enum QingTypeLearningDiagnostics {
  static let input = "qingyanxuexiceshi"
  static let learned = "清言学习乙词"
  static let base = "清言学习甲词"

  static func initialize(api: RimeApi_stdbool, directory: URL) {
    var traits = RimeTraits.rimeStructInit()
    traits.setCString(Bundle.main.sharedSupportPath!, to: \.shared_data_dir)
    traits.setCString(directory.path, to: \.user_data_dir)
    traits.setCString(directory.path, to: \.log_dir)
    traits.setCString("rime.qingtype.learning-test", to: \.app_name)
    api.setup(&traits); api.initialize(nil)
  }

  static func probe(api: RimeApi_stdbool, directory: URL, schema: String) -> Bool {
    guard directory.lastPathComponent.hasPrefix("qingtype-learning-engine-"),
          directory.resolvingSymlinksInPath().deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else { return false }
    initialize(api: api, directory: directory)
    defer { api.finalize() }
    let session = api.create_session()
    defer { _ = api.destroy_session(session) }
    guard session != 0, api.select_schema(session, schema) else { return false }
    for key in input.utf8 { _ = api.process_key(session, Int32(key), 0) }
    return QingTypeCandidateSource.read(api: api, session: session, startingAt: 0, limit: 128).first?.text == learned
  }

  static func run(api: RimeApi_stdbool, package: URL? = nil) -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-learning-engine-\(UUID())")
    var initialized = false
    var session: RimeSessionId = 0
    var checks = 0
    func stop() {
      if session != 0 { _ = api.destroy_session(session); session = 0 }
      if initialized { api.finalize(); initialized = false }
    }
    defer { stop(); try? FileManager.default.removeItem(at: directory) }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw SettingsError.invalid("FAIL: \(message)") }
        checks += 1; print("PASS: \(message)")
      }
      var settings = QingTypeSettings()
      settings.personalWords = [.init(text: base, pinyin: "qing yan xue xi ce shi", weight: 10000),
                                .init(text: learned, pinyin: "qing yan xue xi ce shi", weight: 1)]
      if let package { settings.rimeIce = try QingTypeRimeIce.install(from: package, into: directory, provenance: "isolated learning test") }
      if let path = ProcessInfo.processInfo.environment["QINGTYPE_LEARNING_TEST_MODEL"] {
        let model = try QingTypeContent.importGrammar(from: URL(fileURLWithPath: path), into: directory)
        settings.models = [model]; settings.activeModelID = model.id
      }
      func start() throws {
        initialize(api: api, directory: directory); initialized = true
        session = api.create_session()
        try expect(session != 0 && api.select_schema(session, settings.schema), "learning test starts the configured real schema")
      }
      func deploy() throws {
        stop(); try settings.save(to: directory)
        let report = try QingTypeMaintenance.deploy(api: api, directory: directory)
        try expect(report.success, "learning fixture deploys with production configuration generation")
        let compiled = try Yams.load(yaml: String(contentsOf: directory.appendingPathComponent("build/\(settings.schema).schema.yaml"), encoding: .utf8)) as? [String: Any]
        guard (compiled?["translator"] as? [String: Any])?["enable_user_dict"] as? Bool == settings.learningEnabled else {
          throw SettingsError.invalid("FAIL: compiled learning switch differs from saved settings after an immediate redeploy")
        }
        try start()
      }
      func candidates(_ text: String = input) -> [QingTypeCandidate] {
        _ = api.process_key(session, Int32(XK_Escape), 0)
        for key in text.utf8 { _ = api.process_key(session, Int32(key), 0) }
        return QingTypeCandidateSource.read(api: api, session: session, startingAt: 0, limit: 128)
      }
      func choose(_ text: String, code: String = input) throws {
        guard let item = candidates(code).first(where: { $0.text == text }), api.select_candidate(session, item.index) else {
          throw SettingsError.invalid("FAIL: learning fixture candidate selection")
        }
        var commit = RimeCommit.rimeStructInit()
        let got = api.get_commit(session, &commit)
        let value = commit.text.map { String(cString: $0) }
        if got { _ = api.free_commit(&commit) }
        guard got && value == text else { throw SettingsError.invalid("FAIL: selected candidate commits exact text") }
      }
      func train() throws {
        let before = candidates().map(\.text)
        try expect(before.contains(base) && before.contains(learned) && before.firstIndex(of: base)! < before.firstIndex(of: learned)!,
                   "untrained lower-weight candidate begins behind the baseline")
        for _ in 0..<12 { try choose(learned) }
        try expect(candidates().first?.text == learned, "repeated real selections promote the lower-weight candidate to first place")
      }
      try deploy(); try train(); stop()
      let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      child.arguments = ["--learning-restart-probe", directory.path, settings.schema]
      child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      try child.run(); child.waitUntilExit()
      try expect(child.terminationStatus == 0, "learned ranking persists in a completely new engine process")
      let current = try QingTypeLearningMaintenance.backup(api: api, directory: directory).snapshots.first!
      let historical = QingTypeLearningSnapshot(name: "qingtype_history_fixture", data: Data(String(decoding: current.data, as: UTF8.self)
        .replacingOccurrences(of: "#@/db_name\tqingtype_main", with: "#@/db_name\tqingtype_history_fixture").utf8))
      let historicalFile = directory.appendingPathComponent("sync/other-device/qingtype_history_fixture.userdb.txt")
      try FileManager.default.createDirectory(at: historicalFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try historical.data.write(to: historicalFile)
      let backup = try QingTypeLearningMaintenance.run(api: api, action: "backup", directory: directory)
      let backupFile = URL(fileURLWithPath: backup.backupPath!)
      let savedBackup = try QingTypeLearningBackup.load(backupFile)
      try expect(savedBackup.snapshots.contains { $0.name == "qingtype_main" }, "portable Rime snapshot preserves the existing shared database identity")
      try expect(savedBackup.snapshots.contains { String(decoding: $0.data, as: UTF8.self).contains(learned) },
                 "backup contains the actually learned fixture, not only an empty database")
      try expect(savedBackup.snapshots.contains { $0.name == "qingtype_history_fixture" } &&
                 !(try QingTypeLearning.databases(in: directory)).contains("qingtype_history_fixture"),
                 "backup preserves local-sync-only history without merging into active databases")
      try start()
      try expect(candidates().first?.text == learned, "read-only backup leaves real ranking unchanged")
      let imported = try QingTypePersonalDictionary.preview(text: "词语,拼音,词频\n清言学习导入样词,qing yan xue xi dao ru yang ci,50000\n", format: .csv)
      settings.personalWords = QingTypePersonalDictionary.merge(imported, into: settings.personalWords, policy: .keepExisting).words
      try deploy()
      try expect(candidates().first?.text == learned, "adding personal words and redeploying preserves learned ranking")
      settings.personalWords.removeLast()
      try deploy()
      try expect(candidates().first?.text == learned, "deleting personal words and redeploying preserves learned ranking")
      settings.schema = "qingtype_double_pinyin"; try deploy()
      try expect(candidates("qkyjxtxiceui").first?.text == learned, "switching to Xiaohe retains the shared learned candidate")
      settings.schema = "luna_pinyin_simp"; try deploy()
      try expect(candidates().first?.text == learned, "switching back retains learned ranking")
      stop()
      _ = try QingTypeLearningMaintenance.run(api: api, action: "reset", directory: directory)
      try expect(try QingTypeLearning.databases(in: directory).isEmpty, "reset removes active learning while keeping a recovery snapshot")
      try start()
      try expect(candidates().first?.text != learned, "reset actually removes the learned ranking advantage")
      stop()
      _ = try QingTypeLearningMaintenance.run(api: api, action: "restore", directory: directory, source: backupFile)
      try expect(try QingTypeLearning.databases(in: directory).contains("qingtype_history_fixture"), "reset and restore also recover history that existed only in a sync snapshot")
      try start()
      try expect(candidates().first?.text == learned, "restoring the portable snapshot restores actual candidate behavior")
      try choose("你好", code: "nihao")
      stop()
      _ = try QingTypeLearningMaintenance.run(api: api, action: "restore", directory: directory, source: backupFile)
      try start()
      try expect(candidates().first?.text == learned, "merging the same backup again retains learned ordering")
      stop()
      let merged = try QingTypeLearningMaintenance.backup(api: api, directory: directory)
      try expect(merged.snapshots.contains { String(decoding: $0.data, as: UTF8.self).contains("你好") }, "restore merges history without losing words learned after the backup")
      try start()
      settings.personalWords.removeAll { $0.text == learned }; try deploy()
      try expect(candidates().first?.text == learned, "deleting a learned word's fixed row preserves its learned copy")
      settings.personalWords.append(.init(text: learned, pinyin: "qing yan xue xi ce shi", weight: 1))
      stop()
      let beforeDisabled = try QingTypeLearningMaintenance.backup(api: api, directory: directory)
      settings.learningEnabled = false; try deploy()
      try expect(candidates().first?.text != learned, "disabling learning excludes learned ordering without deleting the database")
      for _ in 0..<3 { try choose(base) }
      stop()
      let afterDisabled = try QingTypeLearningMaintenance.backup(api: api, directory: directory)
      func records(_ backup: QingTypeLearningBackup) -> [String] {
        backup.snapshots.flatMap { String(decoding: $0.data, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init) }.sorted()
      }
      try expect(records(beforeDisabled) == records(afterDisabled), "disabled learning records no new selections or frequency changes")
      settings.learningEnabled = true; try deploy()
      try expect(candidates().first?.text == learned, "reenabling learning restores preserved history")
      if package != nil {
        settings.schema = "rime_ice"; try deploy(); try train(); stop()
        let iceChild = Process(); iceChild.executableURL = child.executableURL
        iceChild.arguments = ["--learning-restart-probe", directory.path, settings.schema]
        iceChild.standardOutput = FileHandle.nullDevice; iceChild.standardError = FileHandle.nullDevice
        try iceChild.run(); iceChild.waitUntilExit()
        try expect(iceChild.terminationStatus == 0, "Ice learned ranking persists in a completely new process")
        let iceBackup = try QingTypeLearningMaintenance.run(api: api, action: "backup", directory: directory)
        let names = try QingTypeLearningBackup.load(URL(fileURLWithPath: iceBackup.backupPath!)).snapshots.map(\.name)
        try expect(names.contains("qingtype_main") && names.contains("rime_ice"), "Ice and base learning remain separate in a complete backup")
        try start()
        try expect(candidates().first?.text == learned, "Ice learned ranking survives restart")
        try deploy()
        try expect(candidates().first?.text == learned, "Ice learned ranking survives schema redeployment")
        stop()
        _ = try QingTypeLearningMaintenance.run(api: api, action: "reset", directory: directory)
        try start()
        try expect(candidates().first?.text != learned, "Ice reset removes the actual learned ranking")
        stop()
        _ = try QingTypeLearningMaintenance.run(api: api, action: "restore", directory: directory, source: URL(fileURLWithPath: iceBackup.backupPath!))
        try start()
        try expect(candidates().first?.text == learned, "restoring a multi-schema backup restores Ice learning behavior")
        settings.schema = "luna_pinyin_simp"; try deploy()
        try expect(candidates().first?.text == learned, "multi-schema recovery also preserves the base learning history")
      }
      stop()
      let fixed = try Data(contentsOf: directory.appendingPathComponent("qingtype_personal.dict.yaml"))
      _ = try QingTypeLearningMaintenance.run(api: api, action: "erase", directory: directory)
      try expect(try QingTypeLearning.databases(in: directory).isEmpty && !FileManager.default.fileExists(atPath: QingTypeLearning.localBackups(in: directory).path),
                 "privacy clear removes active records and local learning backups")
      try expect(try Data(contentsOf: directory.appendingPathComponent("qingtype_personal.dict.yaml")) == fixed,
                 "learning privacy clear preserves the fixed personal dictionary")
      print("PASS: \(checks) learning behavior, persistence, portable backup and recovery checks; isolated data only")
      return true
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
  }
}
