import Foundation

@main
struct UninstallDev {
  static func main() async {
    do {
      let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let control = root.appendingPathComponent("build/QingType.app")
      let destination = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/QingType.app")
      let fm = FileManager.default
      guard fm.fileExists(atPath: destination.path) else { print("没有已安装的清言输入法。用户数据保留。") ; return }
      _ = try QingTypeAppInstallation.version(at: control)
      _ = try QingTypeAppInstallation.version(at: destination)
      try QingTypeInstallCommands.verifySignature(control)
      try await QingTypeUninstallTransaction.checkControl(control)
      let lock = try QingTypeInstallLock(destination: destination)
      defer { withExtendedLifetime(lock) {} }
      let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
      try fm.createDirectory(at: trash, withIntermediateDirectories: true)
      let staging = destination.deletingLastPathComponent().appendingPathComponent(".qingtype-uninstall-\(UUID())")
      let removed = trash.appendingPathComponent("清言卸载备份-\(UUID())")
      try await QingTypeUninstallTransaction.run(prepare: {
        let previous = try await QingTypeInstallationSession.state(app: control)
        _ = try await QingTypeInstallCommands.run(["--prepare-uninstall"], app: control)
        return previous
      }, verify: {
        _ = try await QingTypeInstallCommands.run(["--verify-uninstall"], app: control)
      }, stop: {
        _ = try await QingTypeInstallCommands.run(["--quit"], app: control)
      }, remove: {
        _ = try QingTypeProgramMaintenance.stageUninstall(items: [.init(url: destination, kind: .inputService)],
          allowed: [destination], userData: QingTypePaths.userDirectory, staging: staging)
        do { try fm.moveItem(at: staging, to: removed) }
        catch {
          let reason = error.localizedDescription
          do { try QingTypeProgramMaintenance.undoStagedUninstall(staging, allowed: [destination]) }
          catch { throw SettingsError.invalid("程序恢复未完成，请保留 \(staging.path)：\(reason)；\(error.localizedDescription)") }
          throw SettingsError.invalid("无法移到废纸篓，程序已恢复：\(reason)")
        }
      }, restore: { previous in
        let backup = root.appendingPathComponent("build/uninstall-no-cache-\(UUID())")
        let session = QingTypeInstallationSession(before: previous, cacheRoot: try QingTypeInstallCommands.cacheRoot(), cacheBackup: backup)
        try await session.restore(app: destination, existed: true)
      })
      print("已将输入法程序移到废纸篓：\(removed.path)。用户数据保留在 ~/Library/QingType。")
    } catch {
      fputs("卸载失败：\(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }
}
