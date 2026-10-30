import AppKit

enum ProgramMaintenanceService {
  static var applications: [URL] {
    [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/清言.app"), URL(fileURLWithPath: "/Applications/清言.app")]
  }
  static var directory: URL { QingTypeMaintenancePreferences.directory }
  static var receiptURL: URL { directory.appendingPathComponent("pending-update.json") }

  static func verifySignature(_ app: URL) throws {
    _ = try QingTypeProgramMaintenance.version(at: app, kind: .application)
    let nested = app.appendingPathComponent("Contents/Resources/InputMethod/QingType.app")
    guard nested.resolvingSymlinksInPath().path.hasPrefix(app.resolvingSymlinksInPath().path + "/") else { throw SettingsError.invalid("输入服务路径越界。") }
    guard try QingTypeProgramMaintenance.version(at: nested, kind: .inputService) == QingTypeProgramMaintenance.version(at: app, kind: .application) else {
      throw SettingsError.invalid("更新包内的应用和输入服务版本不同。")
    }
    try QingTypeProgramMaintenance.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
  }

  static func team(_ app: URL) throws -> String? {
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    task.arguments = ["-d", "--verbose=4", app.path]
    let output = Pipe(); task.standardError = output; task.standardOutput = FileHandle.nullDevice
    try task.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw SettingsError.invalid("无法读取程序签名。") }
    let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
    let value = line.map { String($0.dropFirst("TeamIdentifier=".count)) }
    return value == "not set" ? nil : value
  }

  static func validateReceipt(_ receipt: QingTypeAppUpdateReceipt) throws {
    guard applications.contains(where: { $0.standardizedFileURL.path == URL(fileURLWithPath: receipt.destination).standardizedFileURL.path }),
          URL(fileURLWithPath: receipt.archive).lastPathComponent == "Previous.zip",
          URL(fileURLWithPath: receipt.archive).resolvingSymlinksInPath().path.hasPrefix(QingTypePaths.userDirectory.appendingPathComponent("backups").resolvingSymlinksInPath().path + "/"),
          receipt.archiveSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
      throw SettingsError.invalid("程序恢复清单不在清言管理范围内。")
    }
  }

  static func prepareUpdate(_ download: QingTypeDownloadedAsset, update: QingTypeAppUpdate) throws -> QingTypeAppUpdateReceipt {
    try QingTypePaths.checkDirectory(QingTypePaths.userDirectory)
    let expected = try update.asset.validate(repository: QingTypeAppUpdates.repository, limit: QingTypeAppUpdates.downloadLimit)
    guard download.repository == QingTypeAppUpdates.repository, download.release == update.tag,
          download.sha256 == expected, try QingTypeContent.digest(of: download.file) == expected else {
      throw SettingsError.invalid("更新文件校验失败，原程序保留。")
    }
    let current = Bundle.main.bundleURL
    guard applications.contains(where: { $0.standardizedFileURL == current.standardizedFileURL }) else {
      throw SettingsError.invalid("请先将清言放入“应用程序”后再更新。")
    }
    let lock = try QingTypeDataLock(directory: directory, exclusive: true)
    defer { withExtendedLifetime(lock) {} }
    guard !FileManager.default.fileExists(atPath: receiptURL.path) else { throw SettingsError.invalid("上一次更新尚未完成，请重新打开清言。") }
    let mount = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-update-image-\(UUID())")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: mount) }
    try QingTypeProgramMaintenance.run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-readonly", "-mountpoint", mount.path, download.file.path])
    defer { try? QingTypeProgramMaintenance.run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]) }
    let source = mount.appendingPathComponent("清言.app")
    guard try QingTypeProgramMaintenance.version(at: source, kind: .application) == update.version else { throw SettingsError.invalid("安装包版本与发行信息不同。") }
    let oldTeam = try team(current)
    let newTeam = try team(source)
    if let oldTeam, oldTeam != newTeam { throw SettingsError.invalid("新版签名团队与当前清言不同，已停止更新。") }
    let backup = QingTypePaths.userDirectory.appendingPathComponent("backups/app-update-\(UUID())")
    let receipt = try QingTypeProgramMaintenance.installApplication(source: source, destination: current, backups: backup, validate: verifySignature)
    do { try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic) }
    catch { try QingTypeProgramMaintenance.restoreApplication(receipt, validate: verifySignature); throw error }
    return receipt
  }

  @MainActor
  static func launchUpdated(_ receipt: QingTypeAppUpdateReceipt) async throws {
    try validateReceipt(receipt)
    let config = NSWorkspace.OpenConfiguration(); config.createsNewApplicationInstance = true
    config.arguments = ["--finish-app-update"]; config.activates = true
    do { _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: receipt.destination), configuration: config) }
    catch {
      try QingTypeProgramMaintenance.restoreApplication(receipt, validate: verifySignature)
      try FileManager.default.removeItem(at: receiptURL)
      throw SettingsError.invalid("无法启动新版清言，已恢复旧程序。")
    }
    NSApplication.shared.terminate(nil)
  }

  static func pendingUpdate() throws -> QingTypeAppUpdateReceipt? {
    guard FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
    let result = try JSONDecoder().decode(QingTypeAppUpdateReceipt.self, from: Data(contentsOf: receiptURL))
    try validateReceipt(result)
    guard URL(fileURLWithPath: result.destination).standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL,
          try QingTypeProgramMaintenance.version(at: Bundle.main.bundleURL, kind: .application) == result.version else { return nil }
    return result
  }

  @MainActor
  static func finishUpdate() async throws -> QingTypeDeploymentReport {
    try QingTypePaths.checkDirectory(QingTypePaths.userDirectory)
    let lock = try QingTypeDataLock(directory: directory, exclusive: true)
    defer { withExtendedLifetime(lock) {} }
    guard var receipt = try pendingUpdate() else { throw SettingsError.invalid("没有待完成的程序更新。") }
    guard receipt.attempts < 2 else { throw SettingsError.invalid("更新未能完成，请使用备份恢复程序：\(receipt.archive)。") }
    receipt.attempts += 1
    try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
    do {
      let report = try await InstallationService.install()
      try FileManager.default.removeItem(at: receiptURL)
      return report
    } catch {
      let reason = error.localizedDescription
      do {
        try QingTypeProgramMaintenance.restoreApplication(receipt, validate: verifySignature)
        try FileManager.default.removeItem(at: receiptURL)
      } catch { throw SettingsError.invalid("更新失败，程序恢复未确认。请保留 \(receipt.archive)。\(reason)") }
      throw SettingsError.invalid("更新失败，旧程序已恢复，请退出后重新打开清言。\(reason)")
    }
  }

  @MainActor
  static func uninstall() async throws -> URL {
    try QingTypePaths.checkDirectory(QingTypePaths.userDirectory)
    let fm = FileManager.default
    let control = InstallationService.payload ?? InstallationService.installedURL
    guard try QingTypeAppInstallation.version(at: control).compare("0.6.0", options: .numeric) != .orderedAscending else {
      throw SettingsError.invalid("请从新版完整清言应用执行卸载。")
    }
    let allowed = [InstallationService.installedURL] + applications
    let items = allowed.filter { fm.fileExists(atPath: $0.path) }.map { url -> QingTypeUninstallItem in
      .init(url: url, kind: url == InstallationService.installedURL ? .inputService : .application)
    }
    guard !items.isEmpty else { throw SettingsError.invalid("没有找到已安装的清言。") }
    for item in items { if let kind = item.kind { _ = try QingTypeProgramMaintenance.version(at: item.url, kind: kind) } }
    let installLock = try QingTypeInstallLock(destination: InstallationService.installedURL)
    defer { withExtendedLifetime(installLock) {} }
    let lock = try QingTypeDataLock(directory: directory, exclusive: true)
    defer { withExtendedLifetime(lock) {} }
    guard !fm.fileExists(atPath: receiptURL.path) else { throw SettingsError.invalid("请先完成上一次程序更新，再卸载。") }
    let others = ["org.qingtype.app", "org.qingtype.settings"].flatMap {
      NSRunningApplication.runningApplications(withBundleIdentifier: $0)
    }.filter { $0.processIdentifier != getpid() && !$0.isTerminated }
    guard others.isEmpty else { throw SettingsError.invalid("请先退出其他清言设置窗口，卸载已停止。") }

    let staging = QingTypePaths.userDirectory.deletingLastPathComponent().appendingPathComponent("清言卸载备份-\(UUID())")
    return try await QingTypeGuidedUninstall.run(read: {
      try await QingTypeUninstallPreflight.read(app: control)
    }, stop: {
      _ = try await InstallationService.command(["--quit"], app: control)
    }, requireStopped: {
      guard NSRunningApplication.runningApplications(withBundleIdentifier: QingTypeAppInstallation.bundleID)
        .allSatisfy({ $0.processIdentifier == getpid() || $0.isTerminated }) else {
        throw SettingsError.invalid("输入服务重新启动或尚未退出，程序保留。")
      }
    }, acquireDataLock: {
      try QingTypeDataLock(directory: QingTypePaths.userDirectory, exclusive: true)
    }, remove: {
      try await QingTypeGuidedUninstall.removePrograms(items: items, allowed: allowed,
        userData: QingTypePaths.userDirectory, staging: staging, recycle: { folder in
          await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([folder]) { locations, error in
              let actual = FileManager.default.fileExists(atPath: folder.path) ? folder : locations[folder] ?? folder
              continuation.resume(returning: .init(location: actual, error: error))
            }
          }
        })
    })
  }

  @MainActor
  static func removeUserData() async throws -> URL {
    let fm = FileManager.default
    let data = QingTypePaths.userDirectory
    guard !fm.fileExists(atPath: InstallationService.installedURL.path),
          NSRunningApplication.runningApplications(withBundleIdentifier: QingTypeAppInstallation.bundleID).isEmpty else {
      throw SettingsError.invalid("请先卸载清言输入法并退出输入服务，再删除用户数据。")
    }
    guard fm.fileExists(atPath: data.path) else { throw SettingsError.invalid("没有找到清言用户数据。") }
    try QingTypePaths.checkDirectory(data)
    let installLock = try QingTypeInstallLock(destination: InstallationService.installedURL)
    defer { withExtendedLifetime(installLock) {} }
    let otherSettings = ["org.qingtype.app", "org.qingtype.settings"].flatMap {
      NSRunningApplication.runningApplications(withBundleIdentifier: $0)
    }.filter { $0.processIdentifier != getpid() && !$0.isTerminated }
    try QingTypeUninstallGuard.requireDataRemovalSafe(installed: fm.fileExists(atPath: InstallationService.installedURL.path),
      running: !NSRunningApplication.runningApplications(withBundleIdentifier: QingTypeAppInstallation.bundleID).isEmpty,
      otherSettings: !otherSettings.isEmpty)
    guard let control = InstallationService.payload else { throw SettingsError.invalid("请从完整清言安装包打开此操作。") }
    try QingTypeUninstallPreflight.requireRemoved(await QingTypeUninstallPreflight.read(app: control))
    let dataLock = try QingTypeDataLock(directory: data, exclusive: true)
    defer { withExtendedLifetime(dataLock) {} }
    let staging = data.deletingLastPathComponent().appendingPathComponent("清言数据恢复-\(UUID())")
    _ = try QingTypeProgramMaintenance.stageUninstall(items: [.init(url: data, kind: nil)], allowed: [data], userData: data, staging: staging)
    let result: ([URL: URL], Error?) = await withCheckedContinuation { continuation in
      NSWorkspace.shared.recycle([staging]) { locations, error in continuation.resume(returning: (locations, error)) }
    }
    if let error = result.1 {
      let actual = fm.fileExists(atPath: staging.path) ? staging : result.0[staging] ?? staging
      do { try QingTypeProgramMaintenance.undoStagedUninstall(actual, allowed: [data]) }
      catch { throw SettingsError.invalid("用户数据恢复未完成，请保留恢复文件夹 \(actual.path)：\(error.localizedDescription)") }
      throw SettingsError.invalid("无法移到废纸篓，用户数据已恢复：\(error.localizedDescription)")
    }
    return result.0[staging] ?? staging
  }
}
