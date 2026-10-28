import Foundation

/// Compiling can be interrupted by an earlier crash or a concurrent writer,
/// leaving a truncated table or prism behind. Rime then refuses every later
/// deployment. These artifacts are derived data: move them aside, rebuild once,
/// and put the old files back if the rebuild still fails.
enum QingTypeBuildRecovery {
  static func isCompileFailure(_ error: Error) -> Bool {
    let text = error.localizedDescription
    return text.contains("failed to compile")
      || text.contains("Error translating syllable_id")
      || text.contains("building prism")
  }

  /// Moves derived `.bin`/`.yaml` files from the build directory into a backup.
  /// Returns how many files were moved; symlinks and subdirectories are ignored.
  @discardableResult
  static func moveDerivedArtifacts(in buildDirectory: URL, to backup: URL,
                                   move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> Int {
    let manager = FileManager.default
    guard (try? buildDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw SettingsError.invalid("编译目录包含符号链接，已停止重建。")
    }
    guard let entries = try? manager.contentsOfDirectory(
      at: buildDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
      return 0
    }
    let derived: Set<String> = ["bin", "yaml"]
    var moved: [URL] = []
    do {
      for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where derived.contains(url.pathExtension.lowercased()) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
        try manager.createDirectory(at: backup, withIntermediateDirectories: true)
        try move(url, backup.appendingPathComponent(url.lastPathComponent))
        moved.append(url)
      }
    } catch {
      let reason = error.localizedDescription
      var failures: [String] = []
      for original in moved.reversed() {
        do {
          guard !manager.fileExists(atPath: original.path) else { throw SettingsError.invalid("目标文件已重新出现。") }
          try move(backup.appendingPathComponent(original.lastPathComponent), original)
        } catch { failures.append("\(original.lastPathComponent)：\(error.localizedDescription)") }
      }
      if !failures.isEmpty {
        throw SettingsError.invalid("编译文件恢复未完成，原文件保留在 \(backup.path)。\(reason)；\(failures.joined(separator: "；"))")
      }
      throw SettingsError.invalid("编译文件搬移失败，已恢复原文件。\(reason)")
    }
    return moved.count
  }

  static func restore(from backup: URL, to buildDirectory: URL) throws {
    let manager = FileManager.default
    guard let entries = try? manager.contentsOfDirectory(
      at: backup, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
    try manager.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
    for url in entries {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
      let target = buildDirectory.appendingPathComponent(url.lastPathComponent)
      if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
      try manager.moveItem(at: url, to: target)
    }
    try? manager.removeItem(at: backup)
  }

  static func discard(_ backup: URL) {
    try? FileManager.default.removeItem(at: backup)
  }
}
