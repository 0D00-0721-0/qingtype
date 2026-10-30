import Foundation
import CryptoKit
import Yams

struct QingTypeLearningSnapshot: Codable {
  var name: String
  var data: Data
  var sha256: String
  init(name: String, data: Data) {
    self.name = name; self.data = data
    sha256 = Self.digest(data)
  }
  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  func validate() throws {
    guard QingTypeLearning.validName(name), data.count <= 64 * 1024 * 1024,
          sha256 == Self.digest(data), let text = String(data: data, encoding: .utf8),
          !text.contains("\0"), !text.contains("\r") else {
      throw SettingsError.invalid("学习备份的名称、编码或校验值不正确。")
    }
    var metadata: [String: String] = [:]
    for line in text.split(separator: "\n") {
      if line.hasPrefix("#@") {
        let parts = line.dropFirst(2).split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 2, metadata[String(parts[0])] == nil else { throw SettingsError.invalid("学习备份的元数据不完整或重复。") }
        metadata[String(parts[0])] = String(parts[1])
      } else if !line.hasPrefix("#") {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[2].range(of: "^c=-?[0-9]+ d=[0-9.eE+\\-]+ t=[0-9]+$", options: .regularExpression) != nil else {
          throw SettingsError.invalid("学习备份包含无效记录，未修改现有数据。")
        }
        let values = parts[2].split(separator: " ")
        guard values.count == 3, Int32(values[0].dropFirst(2)) != nil,
              let weight = Double(values[1].dropFirst(2)), weight.isFinite,
              UInt64(values[2].dropFirst(2)) != nil else { throw SettingsError.invalid("学习备份包含超出范围的词频数值。") }
      }
    }
    guard metadata["/db_name"] == name, metadata["/db_type"] == "userdb" else {
      throw SettingsError.invalid("学习备份的数据库身份不匹配。")
    }
    if let tick = metadata["/tick"], UInt64(tick) == nil { throw SettingsError.invalid("学习备份的计数器无效。") }
  }
}

struct QingTypeLearningBackup: Codable {
  var format = "org.qingtype.learning"
  var version = 1
  var createdAt = Date()
  var rimeVersion: String
  var snapshots: [QingTypeLearningSnapshot]
  func validate() throws {
    guard format == "org.qingtype.learning", version == 1, snapshots.count <= 128,
          Set(snapshots.map { $0.name.lowercased() }).count == snapshots.count,
          snapshots.reduce(0, { $0 + $1.data.count }) <= 64 * 1024 * 1024 else {
      throw SettingsError.invalid("不支持的学习备份，或备份超过容量限制。")
    }
    try snapshots.forEach { try $0.validate() }
  }
  static func load(_ url: URL) throws -> Self {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    guard size <= 90 * 1024 * 1024 else { throw SettingsError.invalid("学习备份文件过大。") }
    let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    try result.validate()
    return result
  }
  func write(to url: URL) throws {
    try validate()
    guard url.pathExtension == "qinglearning" else { throw SettingsError.invalid("学习备份须使用 .qinglearning 扩展名。") }
    if FileManager.default.fileExists(atPath: url.path) { try QingTypeLearning.checkTree(url) }
    try JSONEncoder().encode(self).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

struct QingTypeLearningResult: Codable {
  var message: String
  var databaseCount: Int
  var backupPath: String?
}

struct QingTypeLearningRecoveryError: LocalizedError {
  var directory: URL
  var reason: String
  var errorDescription: String? { "学习数据恢复未完成，输入服务将保持停止。恢复目录：\(directory.path)。\(reason)" }
}

enum QingTypeLearning {
  static func validName(_ name: String) -> Bool {
    name.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil
  }

  // Reject symlinks and special files before cloning, moving or removing any
  // tree. Root paths are supplied by QingType, never by an archive entry.
  static func checkTree(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
    guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
      throw SettingsError.invalid("学习数据包含符号链接或特殊文件，操作已停止：\(url.lastPathComponent)")
    }
    if values.isDirectory == true {
      for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try checkTree(child) }
    }
  }

  static func databases(in directory: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard values.isSymbolicLink != true, values.isDirectory == true else { throw SettingsError.invalid("学习数据目录不可用。") }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasSuffix(".userdb") }
      .map {
        let name = String($0.lastPathComponent.dropLast(7))
        guard validName(name) else { throw SettingsError.invalid("不支持的学习数据库名称。") }
        try checkTree($0)
        guard try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw SettingsError.invalid("不支持的学习数据库格式。") }
        return name
      }.sorted()
  }

  static func workspace() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-learning-work-\(UUID())")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return path
  }

  static func clone(_ names: [String], from directory: URL, to workspace: URL) throws {
    let installation = directory.appendingPathComponent("installation.yaml")
    if FileManager.default.fileExists(atPath: installation.path),
       let object = try Yams.load(yaml: String(contentsOf: installation, encoding: .utf8)) as? [String: Any],
       let id = object["installation_id"] as? String {
      try Yams.dump(object: ["installation_id": id, "sync_dir": workspace.appendingPathComponent("sync").path])
        .write(to: workspace.appendingPathComponent("installation.yaml"), atomically: true, encoding: .utf8)
    }
    for name in names {
      guard validName(name) else { throw SettingsError.invalid("不支持的学习数据库名称。") }
      let source = directory.appendingPathComponent(name + ".userdb")
      try checkTree(source)
      try FileManager.default.copyItem(at: source, to: workspace.appendingPathComponent(name + ".userdb"))
    }
  }

  static func localBackups(in directory: URL) -> URL { directory.appendingPathComponent("learning-backups") }

  static func makeBackupURL(in directory: URL) throws -> URL {
    let folder = localBackups(in: directory)
    if FileManager.default.fileExists(atPath: folder.path) { try checkTree(folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(UUID()).qinglearning")
  }

  // Rime's local sync snapshots can reintroduce cleared records later. Operate
  // only inside QingType; external sync locations require user-side management.
  static func resetTargets(in directory: URL, includeBackups: Bool) throws -> [URL] {
    var targets = try databases(in: directory).map { directory.appendingPathComponent($0 + ".userdb") }
    let installation = directory.appendingPathComponent("installation.yaml")
    if FileManager.default.fileExists(atPath: installation.path),
       let config = try Yams.load(yaml: String(contentsOf: installation, encoding: .utf8)) as? [String: Any],
       let path = config["sync_dir"] as? String, !path.isEmpty {
      let sync = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
      guard sync.resolvingSymlinksInPath().standardizedFileURL.path == directory.appendingPathComponent("sync").resolvingSymlinksInPath().standardizedFileURL.path else {
        throw SettingsError.invalid("检测到自定义同步目录。请先将同步目录恢复为清言目录内的 sync，再清除学习记录；不会修改外部同步文件。")
      }
    }
    targets.append(contentsOf: try localSnapshots(in: directory))
    let backups = localBackups(in: directory)
    if includeBackups, FileManager.default.fileExists(atPath: backups.path) { try checkTree(backups); targets.append(backups) }
    return targets
  }

  static func localSnapshots(in directory: URL) throws -> [URL] {
    var targets: [URL] = []
    let sync = directory.appendingPathComponent("sync")
    if FileManager.default.fileExists(atPath: sync.path) {
      try checkTree(sync)
      func collect(_ folder: URL) throws {
        for child in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
          if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try collect(child) }
          else if child.lastPathComponent.hasSuffix(".userdb.txt") { targets.append(child) }
        }
      }
      try collect(sync)
    }
    for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      where child.lastPathComponent.hasSuffix(".userdb.txt") { try checkTree(child); targets.append(child) }
    return targets
  }

  // Move originals aside, install already-validated replacements, and restore
  // originals on any error. Configuration, personal tables and models are never
  // transaction targets. The optional hook exercises partial-failure recovery.
  static func replace(in directory: URL, targets: [URL], replacements: [String: URL] = [:],
                      afterMove: () throws -> Void = {}) throws {
    let fm = FileManager.default
    let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    for target in targets {
      try checkTree(target)
      guard target.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw SettingsError.invalid("学习数据操作越界。") }
      let relative = String(target.resolvingSymlinksInPath().path.dropFirst(root.count))
      guard (relative.hasPrefix("sync/") && relative.hasSuffix(".userdb.txt")) ||
            (!relative.contains("/") && (relative.hasSuffix(".userdb") || relative.hasSuffix(".userdb.txt") || relative == "learning-backups")) else {
        throw SettingsError.invalid("学习数据操作不允许修改配置或其他文件。")
      }
    }
    for (name, path) in replacements {
      guard validName(name), path.lastPathComponent == name + ".userdb" else { throw SettingsError.invalid("学习恢复目标无效。") }
      try checkTree(path)
      let dest = directory.appendingPathComponent(name + ".userdb")
      guard !fm.fileExists(atPath: dest.path) || targets.contains(where: { $0.resolvingSymlinksInPath().path == dest.resolvingSymlinksInPath().path }) else { throw SettingsError.invalid("恢复目标出现了新的学习数据，请重试。") }
    }
    let recovery = directory.appendingPathComponent(".learning-recovery-\(UUID())")
    try fm.createDirectory(at: recovery, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var moved: [(URL, URL)] = []
    var installed: [URL] = []
    do {
      try JSONEncoder().encode(targets.enumerated().map { ["saved": String($0.offset), "original": String($0.element.resolvingSymlinksInPath().path.dropFirst(root.count))] })
        .write(to: recovery.appendingPathComponent("recovery.json"), options: .atomic)
      for (index, target) in targets.enumerated() {
        let saved = recovery.appendingPathComponent(String(index))
        try fm.moveItem(at: target, to: saved); moved.append((target, saved))
        try afterMove()
      }
      for (name, source) in replacements.sorted(by: { $0.key < $1.key }) {
        let dest = directory.appendingPathComponent(name + ".userdb")
        try fm.moveItem(at: source, to: dest); installed.append(dest)
      }
    } catch {
      do {
        for dest in installed { try fm.removeItem(at: dest) }
        for (original, saved) in moved.reversed() { try fm.moveItem(at: saved, to: original) }
        try fm.removeItem(at: recovery)
      } catch { throw QingTypeLearningRecoveryError(directory: recovery, reason: error.localizedDescription) }
      throw SettingsError.invalid("学习数据操作失败，已恢复原有数据。")
    }
    // A failed cleanup must be visible: the recovery directory contains private
    // records. Leave it for explicit handling instead of claiming privacy clear.
    do { try fm.removeItem(at: recovery) }
    catch { throw QingTypeLearningRecoveryError(directory: recovery, reason: "操作已应用，但旧学习数据的清理失败。") }
  }
}
