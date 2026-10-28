import AppKit

enum InstallationService {
  static let installedURL = QingTypePaths.userDirectory.deletingLastPathComponent().appendingPathComponent("Input Methods/QingType.app")
  static var payload: URL? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let url = resources.appendingPathComponent("InputMethod/QingType.app")
    return (try? QingTypeAppInstallation.version(at: url)) == nil ? nil : url
  }
  static var installedVersion: String? { try? QingTypeAppInstallation.version(at: installedURL) }

  static func command(_ arguments: [String], app: URL = installedURL) async throws -> Data {
    try await QingTypeInstallCommands.run(arguments, app: app)
  }
  static func state() async throws -> QingTypeInputSourceState { try JSONDecoder().decode(QingTypeInputSourceState.self, from: await command(["--status"])) }

  @MainActor
  static func install() async throws -> QingTypeDeploymentReport {
    let source = payload
    guard source != nil || installedVersion != nil else { throw SettingsError.invalid("没有找到输入法程序，请从完整的清言应用重新安装。") }
    if let source { try QingTypeInstallCommands.verifySignature(source) }
    let lock = try QingTypeInstallLock(destination: installedURL)
    defer { withExtendedLifetime(lock) {} }
    let before = try await QingTypeInstallationSession.state(app: source ?? installedURL)
    let cacheRoot = try QingTypeInstallCommands.cacheRoot()
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: QingTypeAppInstallation.bundleID)
    for app in running { app.terminate() }
    for _ in 0..<40 {
      if running.allSatisfy(\.isTerminated) { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard running.allSatisfy(\.isTerminated) else { throw SettingsError.invalid("输入法尚未退出，请完成当前输入后重试。") }
    let others = ["org.qingtype.settings", "org.qingtype.app"].flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }.filter { $0.processIdentifier != getpid() }
    for app in others { app.terminate() }
    var report: QingTypeDeploymentReport?
    let backup = QingTypePaths.userDirectory.appendingPathComponent("backups/install-\(UUID())")
    let session = QingTypeInstallationSession(before: before, cacheRoot: cacheRoot, cacheBackup: backup.appendingPathComponent("input-source-cache"))
    func activate() async throws {
      try session.backUpCache()
      // Deploy before enabling the input source. Enabling lets macOS start the
      // input service immediately, and a service compiling the same build
      // directory at the same time can truncate the compiled dictionary.
      try await DeploymentService.stopInputMethod()
      let settings = try QingTypeSettings.load()
      report = try await QingTypeConfigurationApply.apply(settings, to: QingTypePaths.userDirectory) {
        // Deployment can be retried after a rollback; make sure a service that
        // macOS restarted in between cannot hold the shared data lock.
        try await DeploymentService.stopInputMethod()
        return try await DeploymentService.runWorker(appURL: installedURL)
      }
      try await session.enableInputSource(app: installedURL)
      // The transaction has committed; start from the installed path so the user
      // keeps a working input method without a stale staging executable.
      DeploymentService.startInputMethod(at: installedURL)
    }
    if let source {
      try await QingTypeAppInstallation.install(source: source, destination: installedURL, backups: backup, lock: lock,
        validate: QingTypeInstallCommands.verifySignature,
        rollback: { existed in
          // Never swap the program back underneath a live service: that process
          // would keep running from a staging directory the transaction deletes.
          _ = try? await DeploymentService.stopInputMethod()
          try await session.restore(app: existed ? installedURL : source, existed: existed)
        }, activate: activate)
    } else {
      do { try await activate() }
      catch {
        let original = error.localizedDescription
        _ = try? await DeploymentService.stopInputMethod()
        do { try await session.restore(app: installedURL, existed: true) }
        catch { throw SettingsError.invalid("安装失败，输入源或缓存恢复未确认。备份：\(backup.path)。\(original)；\(error.localizedDescription)") }
        throw SettingsError.invalid("安装失败，输入源状态已恢复。\(original)")
      }
    }
    guard let report else { throw SettingsError.invalid("输入法尚未完成初始化。") }
    return report
  }
}
