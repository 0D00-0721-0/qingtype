import Foundation

/// Keeps a bounded number of transaction backups. Only QingType-owned backup
/// directories are considered; files, symlinks and unrelated directories are
/// never touched, so a user's own copy is always safe.
enum QingTypeBackupRetention {
  static func prune(in root: URL, prefixes: [String], keeping: Int) throws -> [URL] {
    guard keeping >= 1 else { throw SettingsError.invalid("备份保留数量必须至少为 1。") }
    let manager = FileManager.default
    guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw SettingsError.invalid("备份目录包含符号链接，已停止清理。")
    }
    guard let entries = try? manager.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]) else {
      return []
    }
    var candidates: [(URL, Date)] = []
    for url in entries {
      let name = url.lastPathComponent
      guard prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
      guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
      candidates.append((url, values?.contentModificationDate ?? .distantPast))
    }
    candidates.sort { $0.1 > $1.1 }
    var removed: [URL] = []
    for (url, _) in candidates.dropFirst(keeping) {
      do { try manager.removeItem(at: url); removed.append(url) }
      catch { continue }
    }
    return removed
  }
}
