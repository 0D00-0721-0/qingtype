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
      if let path = ProcessInfo.processInfo.environment["QINGTYPE_FACTORY_TEST_MODEL"] {
        stop()
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
