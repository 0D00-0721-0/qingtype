import Foundation
import Yams

enum QingTypeMaintenance {
  static func deploy(api: RimeApi_stdbool, directory: URL = QingTypePaths.userDirectory) throws -> QingTypeDeploymentReport {
    let settings = try QingTypeSettings.load(from: directory)
    try settings.validate()
    let logs = directory.appendingPathComponent("deployment-logs/\(UUID())")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    var traits = RimeTraits.rimeStructInit()
    traits.setCString(Bundle.main.sharedSupportPath!, to: \.shared_data_dir)
    traits.setCString(directory.path, to: \.user_data_dir)
    traits.setCString(logs.path, to: \.log_dir)
    traits.setCString("rime.qingtype.deploy", to: \.app_name)
    api.setup(&traits)
    api.initialize(nil)
    defer { api.finalize() }
    if api.start_maintenance(true) { api.join_maintenance_thread() }
    // A stale compiled table can still answer nihao after a failed rebuild.
    // Require the explicit schema/dictionary compiler result as well.
    let schemaFile = URL(fileURLWithPath: Bundle.main.sharedSupportPath!).appendingPathComponent(settings.schema + ".schema.yaml")
    let schemaReady = api.deploy_schema(schemaFile.path)
    let configReady = api.deploy_config_file("squirrel.yaml", "config_version")
    let session = api.create_session()
    defer { _ = api.destroy_session(session) }
    let selected = session != 0 && api.select_schema(session, settings.schema)
    let sample = settings.schema == "qingtype_double_pinyin" ? "nihc" : "nihao"
    for key in sample.utf8 { _ = api.process_key(session, Int32(key), 0) }
    var context = RimeContext_stdbool.rimeStructInit()
    let gotContext = api.get_context(session, &context)
    let hasCandidates = gotContext && context.menu.num_candidates > 0
    if gotContext { _ = api.free_context(&context) }
    // Exercise sentence composition in addition to exact word lookup.
    if settings.activeModel != nil {
      _ = api.process_key(session, Int32(XK_Escape), 0)
      let sentence = settings.schema == "qingtype_double_pinyin"
        ? "wojbtmzdxtxijisrjiwhlo" : "wojintianzaixuexijisuanjiwangluo"
      for key in sentence.utf8 { _ = api.process_key(session, Int32(key), 0) }
      var sentenceContext = RimeContext_stdbool.rimeStructInit()
      if api.get_context(session, &sentenceContext) { _ = api.free_context(&sentenceContext) }
    }
    let compiled = directory.appendingPathComponent("build/\(settings.schema).schema.yaml")
    let header = try Yams.load(yaml: String(contentsOf: compiled, encoding: .utf8)) as? [String: Any]
    let translator = header?["translator"] as? [String: Any]
    let prism = translator?["prism"] as? String ?? ""
    let dictionary = translator?["dictionary"] as? String ?? ""
    let binaryReady = FileManager.default.fileExists(atPath: directory.appendingPathComponent("build/\(prism).prism.bin").path) &&
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("build/qingtype_main.table.bin").path)
    let success = schemaReady && configReady && selected && hasCandidates && binaryReady && dictionary == "qingtype_main"
    return QingTypeDeploymentReport(success: success,
      settingsHash: try QingTypeContent.digest(of: directory.appendingPathComponent("settings.json")),
      schema: settings.schema, dictionaryCount: settings.dictionaries.filter(\.enabled).count,
      modelLanguage: settings.activeModel?.language,
      message: success ? "词库已编译，输入方案检查通过。" : "部署检查未通过，请查看部署日志。",
      logDirectory: logs.path)
  }
}
