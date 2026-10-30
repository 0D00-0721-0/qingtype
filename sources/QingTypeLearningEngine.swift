import Foundation
import Yams

// Only opens cloned, closed databases in a private temporary workspace. No sync
// operation is used: backup must never merge a user's external sync directory.
enum QingTypeLearningEngine {
  static func withWorkspace<T>(api: RimeApi_stdbool, at directory: URL,
                               body: (RimeLeversApi, URL) throws -> T) throws -> T {
    var api = api
    // Deployer state survives API reinitialization. Always pin this workspace's
    // sync directory instead of inheriting a previous workspace/external path.
    let existing = try? Yams.load(yaml: String(contentsOf: directory.appendingPathComponent("installation.yaml"), encoding: .utf8)) as? [String: Any]
    let installation: [String: String] = ["installation_id": existing?["installation_id"] as? String ?? "qingtype-offline-learning",
                                        "sync_dir": directory.appendingPathComponent("sync").path]
    try Yams.dump(object: installation).write(to: directory.appendingPathComponent("installation.yaml"), atomically: true, encoding: .utf8)
    var traits = RimeTraits.rimeStructInit()
    traits.setCString(Bundle.main.sharedSupportPath!, to: \.shared_data_dir)
    traits.setCString(directory.path, to: \.user_data_dir)
    traits.setCString(directory.path, to: \.log_dir)
    traits.setCString("rime.qingtype.learning", to: \.app_name)
    api.setup(&traits)
    api.deployer_initialize(nil)
    defer { api.finalize() }
    guard api.run_task("installation_update"), let lever = qingtype_levers_api(&api) else {
      throw SettingsError.invalid("无法初始化 Rime 学习数据管理器。")
    }
    var path = [CChar](repeating: 0, count: 8192)
    api.get_user_data_sync_dir(&path, path.count)
    let sync = URL(fileURLWithPath: String(cString: path))
    guard sync.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(directory.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
      throw SettingsError.invalid("备份工作目录越界，操作已停止。")
    }
    return try body(lever.pointee, sync)
  }

  static func snapshots(api: RimeApi_stdbool, directory: URL, names: [String]) throws -> [QingTypeLearningSnapshot] {
    try withWorkspace(api: api, at: directory) { lever, sync in
      try names.map { name in
        guard lever.backup_user_dict(name) != 0 else { throw SettingsError.invalid("无法读取学习数据库：\(name)，原数据未修改。") }
        let file = sync.appendingPathComponent(name + ".userdb.txt")
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1024 * 1024 else {
          throw SettingsError.invalid("学习数据库超过备份容量限制，原数据未修改。")
        }
        let data = try Data(contentsOf: file)
        return QingTypeLearningSnapshot(name: name, data: data)
      }
    }
  }

  static func restore(api: RimeApi_stdbool, directory: URL, snapshots: [QingTypeLearningSnapshot]) throws {
    try withWorkspace(api: api, at: directory) { lever, _ in
      for snapshot in snapshots {
        let file = directory.appendingPathComponent(snapshot.name + ".userdb.txt")
        try snapshot.data.write(to: file, options: .atomic)
        guard lever.restore_user_dict(file.path) != 0 else { throw SettingsError.invalid("Rime 无法恢复备份中的 \(snapshot.name)。原数据未修改。") }
      }
    }
    // Reopen and export every restored database, rather than trusting existence.
    _ = try self.snapshots(api: api, directory: directory, names: snapshots.map(\.name))
  }
}
