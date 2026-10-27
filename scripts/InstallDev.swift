import Foundation

@main
struct InstallDev {
  static func main() async {
    do {
      let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/QingType.app")
      let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/QingType.app")
      let backup = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/install-backups/\(UUID())")
      _ = try QingTypeAppInstallation.version(at: source)
      try QingTypeInstallCommands.verifySignature(source)
      let lock = try QingTypeInstallLock(destination: destination)
      defer { withExtendedLifetime(lock) {} }
      let before = try await QingTypeInstallationSession.state(app: source)
      let session = QingTypeInstallationSession(before: before, cacheRoot: try QingTypeInstallCommands.cacheRoot(), cacheBackup: backup.appendingPathComponent("input-source-cache"))
      _ = try await QingTypeInstallCommands.run(["--quit"], app: source)
      try await QingTypeAppInstallation.install(source: source, destination: destination, backups: backup, lock: lock,
        validate: QingTypeInstallCommands.verifySignature,
        rollback: { existed in try await session.restore(app: existed ? destination : source, existed: existed) }) {
          try await session.activate(app: destination)
        }
      print("已安装清言。请在系统输入菜单中选择清言；备份：\(backup.path)")
    } catch {
      fputs("安装失败：\(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }
}
