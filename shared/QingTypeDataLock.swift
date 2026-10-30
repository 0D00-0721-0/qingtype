import Foundation
import Darwin

// Shared by the running input service; exclusive for offline learning/deployment
// workers. An OS-triggered service relaunch cannot race database replacement.
final class QingTypeDataLock {
  private let descriptor: Int32
  init(directory: URL, exclusive: Bool) throws {
    guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
      throw SettingsError.invalid("清言数据目录包含符号链接，操作已停止。")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(".qingtype-data.lock").path
    descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw SettingsError.invalid("无法锁定清言数据目录。") }
    guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
      close(descriptor)
      throw SettingsError.invalid("清言正在输入或管理数据，请结束当前输入或等待操作完成后重试。")
    }
    do {
      if let pending = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .first(where: { $0.lastPathComponent.hasPrefix(".learning-recovery-") }) {
        throw SettingsError.invalid("学习数据有未完成的恢复，请先处理恢复目录：\(pending.path)。输入服务保持停止。")
      }
    } catch { flock(descriptor, LOCK_UN); close(descriptor); throw error }
  }
  deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
