import AppKit
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
      let lock = try QingTypeInstallLock(destination: destination)
      defer { withExtendedLifetime(lock) {} }
      let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
      try fm.createDirectory(at: trash, withIntermediateDirectories: true)
      let staging = destination.deletingLastPathComponent().appendingPathComponent(".qingtype-uninstall-\(UUID())")
      let removed = trash.appendingPathComponent("清言卸载备份-\(UUID())")
      _ = try await QingTypeGuidedUninstall.run(read: {
        try await QingTypeUninstallPreflight.read(app: control)
      }, stop: {
        _ = try await QingTypeInstallCommands.run(["--quit"], app: control)
      }, requireStopped: {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: QingTypeAppInstallation.bundleID)
          .allSatisfy({ $0.processIdentifier == getpid() || $0.isTerminated }) else {
          throw SettingsError.invalid("输入服务重新启动或尚未退出，程序保留。")
        }
      }, acquireDataLock: {
        try QingTypeDataLock(directory: QingTypePaths.userDirectory, exclusive: true)
      }, remove: {
        try await QingTypeGuidedUninstall.removePrograms(items: [.init(url: destination, kind: .inputService)],
          allowed: [destination], userData: QingTypePaths.userDirectory, staging: staging, recycle: { folder in
            try fm.moveItem(at: folder, to: removed)
            return .init(location: removed)
          })
      })
      print("已将输入法程序移到废纸篓：\(removed.path)。用户数据保留在 ~/Library/QingType。")
    } catch {
      fputs("卸载失败：\(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }
}
