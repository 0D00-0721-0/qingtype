import Foundation
import Yams

enum QingTypePersonalDictionaryDiagnostics {
  static func run(api: RimeApi_stdbool) -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-personal-engine-\(UUID())")
    var initialized = false
    var session: RimeSessionId = 0
    func stop() {
      if session != 0 { _ = api.destroy_session(session); session = 0 }
      if initialized { api.finalize(); initialized = false }
    }
    defer { stop(); try? FileManager.default.removeItem(at: directory) }
    do {
      var checks = 0
      func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw SettingsError.invalid("FAIL: \(name)") }
        checks += 1
        print("PASS: \(name)")
      }
      var settings = QingTypeSettings()
      settings.personalWords = [.init(text: "星河清言样词", pinyin: "xing he qing yan yang ci", weight: 50000)]
      func saveFixture() throws {
        try settings.save(to: directory)
        // Fixed-source CRUD is tested independently of learning: otherwise a
        // deliberately learned candidate may remain after its fixed row is deleted.
        let path = directory.appendingPathComponent(settings.schema + ".custom.yaml")
        var yaml = try Yams.load(yaml: String(contentsOf: path, encoding: .utf8)) as! [String: Any]
        var patch = yaml["patch"] as! [String: Any]
        patch["translator/enable_user_dict"] = false
        yaml["patch"] = patch
        try (QingTypeSettings.managedHeader + Yams.dump(object: yaml)).write(to: path, atomically: true, encoding: .utf8)
      }
      func deployAndStart() throws {
        stop()
        let report = try QingTypeMaintenance.deploy(api: api, directory: directory)
        try expect(report.success, "explicit schema/dictionary deployment succeeds")
        api.initialize(nil)
        initialized = true
        session = api.create_session()
        try expect(session != 0 && api.select_schema(session, settings.schema), "start the selected schema after deployment")
      }
      func candidates(_ input: String) -> [QingTypeCandidate] {
        _ = api.process_key(session, Int32(XK_Escape), 0)
        for key in input.utf8 { _ = api.process_key(session, Int32(key), 0) }
        return QingTypeCandidateSource.read(api: api, session: session, startingAt: 0, limit: 128)
      }
      try saveFixture()
      try deployAndStart()
      let added = candidates("xingheqingyanyangci")
      try expect(added.contains { $0.text == "星河清言样词" }, "new managed personal word reaches the real full-pinyin engine")
      let chosen = added.first { $0.text == "星河清言样词" }!
      try expect(api.select_candidate(session, chosen.index), "the personal candidate can be selected")
      var commit = RimeCommit.rimeStructInit()
      let gotCommit = api.get_commit(session, &commit)
      let text = commit.text.map { String(cString: $0) }
      if gotCommit { _ = api.free_commit(&commit) }
      try expect(gotCommit && text == "星河清言样词", "selected personal candidate commits exact Unicode text")
      stop()
      let identity = settings.personalWords[0].id
      settings.personalWords[0] = .init(id: identity, text: "银河清言新词", pinyin: "yin he qing yan xin ci", weight: 90000)
      settings.personalWords.append(.init(text: "银河清言次词", pinyin: "yin he qing yan xin ci", weight: 1))
      try saveFixture()
      try deployAndStart()
      try expect(!candidates("xingheqingyanyangci").contains { $0.text == "星河清言样词" }, "editing removes the previous fixed word and spelling")
      let edited = candidates("yinheqingyanxinci").map(\.text)
      try expect(edited.contains("银河清言新词") && edited.contains("银河清言次词") && edited.firstIndex(of: "银河清言新词")! < edited.firstIndex(of: "银河清言次词")!,
                 "edited spelling works and fixed-table weights affect ordering")
      stop()
      let exported = try QingTypePersonalDictionary.export(settings.personalWords, format: .csv)
      let preview = try QingTypePersonalDictionary.preview(text: String(decoding: exported, as: UTF8.self), format: .csv)
      settings.personalWords = QingTypePersonalDictionary.merge(preview, into: [], policy: .keepExisting).words
      settings.schema = "qingtype_double_pinyin"
      try saveFixture()
      try deployAndStart()
      try expect(candidates("ybheqkyjxbci").contains { $0.text == "银河清言新词" }, "CSV round-trip personal words also work in Xiaohe double pinyin")
      stop()
      api.initialize(nil); initialized = true; session = api.create_session()
      _ = api.select_schema(session, settings.schema)
      try expect(candidates("ybheqkyjxbci").contains { $0.text == "银河清言新词" }, "fixed personal entries remain available after engine restart")
      stop()
      settings.personalWords = []
      try saveFixture()
      try deployAndStart()
      try expect(!candidates("ybheqkyjxbci").contains { $0.text == "银河清言新词" }, "deleting all personal rows removes them from the fixed source after redeploy")
      stop()
      let goodFiles = try settings.generatedFiles()
      try (QingTypeSettings.managedHeader + "---\nname: qingtype_main\nversion: 'broken'\nimport_tables: [qingtype_missing_fixture]\n...\n")
        .write(to: directory.appendingPathComponent("qingtype_main.dict.yaml"), atomically: true, encoding: .utf8)
      let failure = try QingTypeMaintenance.deploy(api: api, directory: directory)
      try expect(!failure.success, "a failed dictionary compile cannot be hidden by an old usable binary table")
      for (name, data) in goodFiles { try data.write(to: directory.appendingPathComponent(name), options: .atomic) }
      try saveFixture()
      try deployAndStart()
      try expect(!candidates("nihc").isEmpty, "restoring prior configuration can rebuild a usable engine")
      print("PASS: \(checks) personal dictionary engine integration checks; isolated data; learning behavior is a separate phase")
      return true
    } catch {
      fputs("\(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }
}
