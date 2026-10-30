import AppKit

enum InstallationService {
  /// `.automatic` uses the detected status: an equal, healthy installation is
  /// only redeployed, never copied again. `.reinstall` is the explicit user
  /// choice and always runs the full transactional replace.
  enum Mode: Equatable {
    case automatic
    case reinstall
  }

  static let installedURL = QingTypePaths.userDirectory.deletingLastPathComponent().appendingPathComponent("Input Methods/QingType.app")
  static var payload: URL? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let url = resources.appendingPathComponent("InputMethod/QingType.app")
    return (try? QingTypeAppInstallation.version(at: url)) == nil ? nil : url
  }
  static var installedVersion: String? { try? QingTypeAppInstallation.version(at: installedURL) }

  static func status(verifyingSignature: Bool = false) -> QingTypeInstallationStatus {
    QingTypeInstallationCheck.inspect(destination: installedURL, payload: payload,
                                      signature: verifyingSignature ? QingTypeInstallationCheck.verifySignature : nil)
  }

  static func command(_ arguments: [String], app: URL = installedURL) async throws -> Data {
    try await QingTypeInstallCommands.run(arguments, app: app)
  }
  static func state() async throws -> QingTypeInputSourceState { try JSONDecoder().decode(QingTypeInputSourceState.self, from: await command(["--status"])) }
  static func inputAvailable() async throws -> Bool {
    try await QingTypeUninstallPreflight.read(app: payload ?? installedURL).inputAvailable
  }

  @MainActor
  static func install(mode: Mode = .automatic) async throws -> QingTypeDeploymentReport {
    let source = payload
    let status = QingTypeInstallationCheck.inspect(destination: installedURL, payload: source)
    if mode == .automatic {
      switch QingTypeInstallationCheck.action(for: status) {
      case .blockedNewer:
        throw SettingsError.invalid("已安装的输入法 \(status.installedVersion ?? "未知版本") 比此安装包 \(status.payloadVersion ?? "未知版本") 更新，未做任何更改。")
      case .deployOnly:
        return try await redeploy(status: status)
      case .reinstall:
        throw SettingsError.invalid("输入法与安装包版本相同但构建内容不同，请确认后选择重新安装。")
      case .install, .update, .repair:
        break
      }
    }
    guard source != nil || status.installedVersion != nil else {
      throw SettingsError.invalid("没有找到输入法程序，请从完整的清言应用重新安装。")
    }
    return try await transactionalInstall(source: source, status: status)
  }

  /// Equal version and healthy: recompile the configuration and make sure the
  /// input source is enabled, without copying, backing up or swapping bundles.
  @MainActor
  private static func redeploy(status: QingTypeInstallationStatus) async throws -> QingTypeDeploymentReport {
    guard FileManager.default.fileExists(atPath: installedURL.path) else {
      throw SettingsError.invalid("没有找到已安装的输入法，请点“安装并启用清言”。")
    }
    let lock = try QingTypeInstallLock(destination: installedURL)
    defer { withExtendedLifetime(lock) {} }
    let before = try await QingTypeInstallationSession.state(app: installedURL)
    let cacheRoot = try QingTypeInstallCommands.cacheRoot()
    let backup = QingTypePaths.userDirectory.appendingPathComponent("backups/install-\(UUID())")
    let session = QingTypeInstallationSession(before: before, cacheRoot: cacheRoot,
                                              cacheBackup: backup.appendingPathComponent("input-source-cache"))
    var report: QingTypeDeploymentReport?
    do {
      report = try await activateInstalled(session, expectedVersion: status.installedVersion)
    } catch {
      let original = error.localizedDescription
      _ = try? await DeploymentService.stopInputMethod()
      do { try await session.restore(app: installedURL, existed: true) }
      catch { throw SettingsError.invalid("部署失败，输入源或缓存恢复未确认。备份：\(backup.path)。\(original)；\(error.localizedDescription)") }
      throw SettingsError.invalid("部署失败，输入源与缓存已恢复。\(original)")
    }
    guard let report else { throw SettingsError.invalid("输入法尚未完成初始化。") }
    return report
  }

  @MainActor
  private static func transactionalInstall(source: URL?, status: QingTypeInstallationStatus) async throws -> QingTypeDeploymentReport {
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
    let session = QingTypeInstallationSession(before: before, cacheRoot: cacheRoot,
                                              cacheBackup: backup.appendingPathComponent("input-source-cache"))
    if let source {
      try await QingTypeAppInstallation.install(source: source, destination: installedURL, backups: backup, lock: lock,
        validate: QingTypeInstallCommands.verifySignature,
        rollback: { existed in
          // Never swap the program back underneath a live service: that process
          // would keep running from a staging directory the transaction deletes.
          _ = try? await DeploymentService.stopInputMethod()
          try await session.restore(app: existed ? installedURL : source, existed: existed)
        }, activate: {
          report = try await activateInstalled(session, expectedVersion: status.payloadVersion)
        })
    } else {
      do { report = try await activateInstalled(session, expectedVersion: status.installedVersion) }
      catch {
        let original = error.localizedDescription
        _ = try? await DeploymentService.stopInputMethod()
        do { try await session.restore(app: installedURL, existed: true) }
        catch { throw SettingsError.invalid("安装失败，输入源或缓存恢复未确认。备份：\(backup.path)。\(original)；\(error.localizedDescription)") }
        throw SettingsError.invalid("安装失败，输入源状态已恢复。\(original)")
      }
    }
    guard let report else { throw SettingsError.invalid("输入法尚未完成初始化。") }
    try? QingTypeBackupRetention.markOwned(backup)
    pruneBackups()
    return report
  }

  /// Deploy first, verify the installed bundle, then enable the input source.
  /// Enabling can make macOS start the service, so it must not happen while the
  /// deployment worker compiles the same build directory.
  @MainActor
  private static func activateInstalled(_ session: QingTypeInstallationSession,
                                        expectedVersion: String?) async throws -> QingTypeDeploymentReport {
    try session.backUpCache()
    try await DeploymentService.stopInputMethod()
    let settings = try QingTypeSettings.load()
    let report = try await QingTypeConfigurationApply.apply(settings, to: QingTypePaths.userDirectory) {
      // Deployment can be retried after a rollback; make sure a service that
      // macOS restarted in between cannot hold the shared data lock.
      try await DeploymentService.stopInputMethod()
      return try await DeploymentService.runWorker(appURL: installedURL)
    }
    try QingTypeInstallationCheck.verify(destination: installedURL, expectedVersion: expectedVersion,
                                         signature: QingTypeInstallationCheck.verifySignature)
    try await session.enableInputSource(app: installedURL)
    // The transaction has committed; start from the installed path so the user
    // keeps a working input method without a stale staging executable.
    DeploymentService.startInputMethod(at: installedURL)
    return report
  }

  /// Keeps only the newest transaction backups. They are QingType-owned copies
  /// that otherwise grow on every reinstall and every saved configuration.
  private static func pruneBackups() {
    let root = QingTypePaths.userDirectory.appendingPathComponent("backups")
    _ = try? QingTypeBackupRetention.prune(in: root, prefixes: ["install-", "apply-"], keeping: 3)
  }
}
