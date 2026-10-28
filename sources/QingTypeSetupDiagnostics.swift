import Foundation

enum QingTypeSetupDiagnostics {
  static func run(api: RimeApi_stdbool) -> Bool {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-factory-\(UUID())")
    var initialized = false
    var session: RimeSessionId = 0
    func stop() {
      if session != 0 { _ = api.destroy_session(session); session = 0 }
      if initialized { api.finalize(); initialized = false }
    }
    defer { stop(); try? FileManager.default.removeItem(at: root) }
    do {
      var checks = 0
      func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw SettingsError.invalid("FAIL: \(name)") }; checks += 1; print("PASS: \(name)")
      }
      let settings = QingTypeSettings()
      try settings.save(to: root)
      let report = try QingTypeMaintenance.deploy(api: api, directory: root)
      try expect(report.success && report.modelLanguage == nil, "factory profile deploys from bundled resources without optional downloads")
      api.initialize(nil); initialized = true
      session = api.create_session()
      try expect(session != 0 && api.select_schema(session, settings.schema), "factory simplified pinyin starts")
      for key in "nihao".utf8 { _ = api.process_key(session, Int32(key), 0) }
      let candidates = QingTypeCandidateSource.read(api: api, session: session, startingAt: 0, limit: 64)
      try expect(candidates.contains { $0.text == "你好" }, "factory nihao produces 你好 without Rime Ice or Wanxiang")
      try expect(api.select_candidate(session, candidates.first { $0.text == "你好" }!.index), "factory candidate can be selected")
      var commit = RimeCommit.rimeStructInit()
      let got = api.get_commit(session, &commit)
      let text = commit.text.map { String(cString: $0) }
      if got { _ = api.free_commit(&commit) }
      try expect(got && text == "你好", "factory selection commits exact Chinese text")
      let saved = try QingTypeSettings.load(from: root)
      try expect(saved.rimeIce == nil && saved.models.isEmpty && saved.dictionaries.isEmpty && saved.useSystemCandidates,
                 "first use leaves optional components absent and native candidates enabled")
      stop()
      // Exercise the actual deployment entry point with a synthetic model in the isolated profile.
      let fixture = root.appendingPathComponent("fixture.gram")
      var fixtureBytes = Data(repeating: 0x61, count: 2048)
      fixtureBytes.replaceSubrange(0..<17, with: Data("Rime::Grammar/1.0".utf8))
      fixtureBytes.replaceSubrange(36..<44, with: [1, 0, 0, 0, 4, 0, 0, 0])
      try fixtureBytes.write(to: fixture)
      let fixtureModel = try QingTypeContent.importGrammar(from: fixture, into: root)
      var withModel = settings
      withModel.models = [fixtureModel]; withModel.activeModelID = fixtureModel.id
      try withModel.save(to: root)
      let config = root.appendingPathComponent("settings.json")
      let compiledSchema = root.appendingPathComponent("build/\(settings.schema).schema.yaml")
      let savedConfig = try Data(contentsOf: config)
      let compiledBefore = try Data(contentsOf: compiledSchema)
      try Data("corrupted model".utf8).write(to: root.appendingPathComponent(fixtureModel.language + ".gram"))
      var modelRejected = false
      do { _ = try QingTypeMaintenance.deploy(api: api, directory: root) }
      catch { modelRejected = error.localizedDescription.contains("模型校验失败") }
      try expect(modelRejected, "deployment rejects a model corrupted after configuration was saved")
      let configAfter = try Data(contentsOf: config)
      let compiledAfter = try Data(contentsOf: compiledSchema)
      try expect(configAfter == savedConfig && compiledAfter == compiledBefore,
                 "model verification fails before altering settings or compiled schema")
      try settings.save(to: root)
      if let path = ProcessInfo.processInfo.environment["QINGTYPE_FACTORY_TEST_MODEL"] {
        var enhanced = settings
        let model = try QingTypeContent.importGrammar(from: URL(fileURLWithPath: path), into: root)
        enhanced.models = [model]; enhanced.activeModelID = model.id
        try enhanced.save(to: root)
        let enhancedReport = try QingTypeMaintenance.deploy(api: api, directory: root)
        try expect(enhancedReport.success && enhancedReport.modelLanguage == model.language, "Wanxiang can deploy independently of Rime Ice")
        api.initialize(nil); initialized = true; session = api.create_session(); _ = api.select_schema(session, enhanced.schema)
        for key in "nihao".utf8 { _ = api.process_key(session, Int32(key), 0) }
        try expect(QingTypeCandidateSource.read(api: api, session: session, startingAt: 0, limit: 64).contains { $0.text == "你好" }, "basic pinyin with only the optional model produces Chinese candidates")
      }
      print("PASS: \(checks) offline factory engine checks")
      return true
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
  }
}
