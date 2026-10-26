import AppKit

enum DeploymentService {
  static func inputMethodURL() -> URL {
    let own = Bundle.main.bundleURL
    let nestedParent = own.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if nestedParent.pathExtension == "app" { return nestedParent }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/QingType.app")
  }

  @MainActor
  static func installRimeIce(from source: URL, saved: QingTypeSettings, provenance: String, sha256: String?, activate: Bool = false) async throws -> (QingTypeSettings, QingTypeDeploymentReport) {
    let directory = QingTypePaths.userDirectory
    guard try QingTypeSettings.load() == saved else { throw SettingsError.invalid("设置文件已被其他程序修改，请重开设置后再安装。") }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "org.qingtype.inputmethod.QingType")
    for app in running { app.terminate() }
    for _ in 0..<40 {
      if running.allSatisfy(\.isTerminated) { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard running.allSatisfy(\.isTerminated) else { throw SettingsError.invalid("输入法尚未退出，请结束当前输入后重新安装方案。") }
    var restart = true
    defer {
      if restart && !running.isEmpty {
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        NSWorkspace.shared.openApplication(at: inputMethodURL(), configuration: config, completionHandler: nil)
      }
    }
    let installation: RimeIceInstallation
    do {
      installation = try await Task.detached {
        try QingTypeRimeIce.installPackage(from: source, into: directory, provenance: provenance, archiveSHA256: sha256)
      }.value
    } catch {
      if error is RimeIceRecoveryError { restart = false }
      throw error
    }
    var updated = saved
    updated.rimeIce = installation.asset
    if activate { updated.schema = "rime_ice" }
    do {
      let report = try await QingTypeConfigurationApply.apply(updated, to: directory) {
        try await runWorker(appURL: inputMethodURL())
      }
      return (updated, report)
    } catch {
      let reason = error.localizedDescription
      restart = false
      do {
        try QingTypeRimeIce.rollback(installation, in: directory)
        // A concurrent settings edit must never be silently reverted here.
        guard try QingTypeSettings.load() == saved else { throw SettingsError.invalid("设置文件未恢复到安装前状态。") }
        let recovery = try await runWorker(appURL: inputMethodURL())
        guard recovery.success else { throw SettingsError.invalid(recovery.message) }
        restart = true
      } catch {
        throw SettingsError.invalid("雾凇安装失败，恢复尚未通过，输入服务保持停止。备份：\(installation.backup.path)。\(reason)；\(error.localizedDescription)")
      }
      throw SettingsError.invalid("雾凇安装失败，已恢复上一版方案与配置。\(reason)")
    }
  }

  @MainActor
  static func apply(_ settings: QingTypeSettings) async throws -> QingTypeDeploymentReport {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "org.qingtype.inputmethod.QingType")
    for app in running { app.terminate() }
    for _ in 0..<40 {
      if running.allSatisfy(\.isTerminated) { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard running.allSatisfy(\.isTerminated) else {
      throw SettingsError.invalid("输入法尚未退出，请结束当前输入后重新应用。")
    }
    let appURL = inputMethodURL()
    var shouldRestart = true
    defer {
      if shouldRestart && !running.isEmpty {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
      }
    }
    do {
      return try await QingTypeConfigurationApply.apply(settings, to: QingTypePaths.userDirectory) {
        try await runWorker(appURL: appURL)
      }
    } catch {
      if let failure = error as? QingTypeApplyError { shouldRestart = failure.recoveryVerified }
      throw error
    }
  }

  static func runWorker(appURL: URL) async throws -> QingTypeDeploymentReport {
    let result = try await Task.detached {
      let task = Process()
      task.executableURL = appURL.appendingPathComponent("Contents/MacOS/QingType")
      task.arguments = ["--deploy-user-data"]
      let output = Pipe()
      task.standardOutput = output
      let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-deploy-\(UUID()).log")
      FileManager.default.createFile(atPath: errorURL.path, contents: nil)
      let errors = try FileHandle(forWritingTo: errorURL)
      defer { try? errors.close(); try? FileManager.default.removeItem(at: errorURL) }
      task.standardError = errors
      try task.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      task.waitUntilExit()
      try errors.synchronize()
      let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
      guard task.terminationStatus == 0 else {
        throw SettingsError.invalid("部署失败：\(detail.suffix(1200))")
      }
      return (try JSONDecoder().decode(QingTypeDeploymentReport.self, from: data), detail)
    }.value
    var report = result.0
    try result.1.write(to: URL(fileURLWithPath: report.logDirectory).appendingPathComponent("plugin-output.log"), atomically: true, encoding: .utf8)
    if report.modelLanguage != nil {
      let files = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: report.logDirectory), includingPropertiesForKeys: nil)) ?? []
      let logs = files.filter { $0.lastPathComponent.contains(".log.INFO.") }.compactMap {
        try? String(contentsOf: $0, encoding: .utf8)
      }.joined(separator: "\n") + "\n" + result.1
      report.modelVerified = report.modelWasLoaded(in: logs)
      if !report.modelVerified {
        report.success = false
        report.message = "词库已编译，但尚未确认模型加载成功，请查看部署日志。"
      } else { report.message = "词库已编译，语言模型已由引擎加载。" }
    }
    let data = try JSONEncoder().encode(report)
    try data.write(to: QingTypePaths.userDirectory.appendingPathComponent("deployment.json"), options: .atomic)
    return report
  }
}
