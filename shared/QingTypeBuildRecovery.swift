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
  static func moveDerivedArtifacts(in buildDirectory: URL, to backup: URL) throws -> Int {
    let manager = FileManager.default
    guard (try? buildDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw SettingsError.invalid("编译目录包含符号链接，已停止重建。")
    }
    guard let entries = try? manager.contentsOfDirectory(
      at: buildDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
      return 0
    }
    let derived: Set<String> = ["bin", "yaml"]
    var moved = 0
    for url in entries where derived.contains(url.pathExtension.lowercased()) {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
      try manager.createDirectory(at: backup, withIntermediateDirectories: true)
      try manager.moveItem(at: url, to: backup.appendingPathComponent(url.lastPathComponent))
      moved += 1
    }
    return moved
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
