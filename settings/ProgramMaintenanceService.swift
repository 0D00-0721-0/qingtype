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
  static func uninstall(removeUserData: Bool) async throws -> URL {
    try QingTypePaths.checkDirectory(QingTypePaths.userDirectory)
    let fm = FileManager.default
    let control = InstallationService.payload ?? InstallationService.installedURL
    guard try QingTypeAppInstallation.version(at: control).compare("0.6.0", options: .numeric) != .orderedAscending else {
      throw SettingsError.invalid("请从新版完整清言应用执行卸载。")
    }
    let allowed = [InstallationService.installedURL] + applications + [QingTypePaths.userDirectory]
    let items = allowed.filter { fm.fileExists(atPath: $0.path) && ($0 != QingTypePaths.userDirectory || removeUserData) }.map { url -> QingTypeUninstallItem in
      .init(url: url, kind: url == QingTypePaths.userDirectory ? nil : url == InstallationService.installedURL ? .inputService : .application)
    }
    guard !items.isEmpty else { throw SettingsError.invalid("没有找到已安装的清言。") }
    for item in items { if let kind = item.kind { _ = try QingTypeProgramMaintenance.version(at: item.url, kind: kind) } }
    let lock = try QingTypeDataLock(directory: directory, exclusive: true)
    defer { withExtendedLifetime(lock) {} }
    guard !fm.fileExists(atPath: receiptURL.path) else { throw SettingsError.invalid("请先完成上一次程序更新，再卸载。") }
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: "org.qingtype.app").filter { $0.processIdentifier != getpid() }
    others.forEach { $0.terminate() }
    let previous = try JSONDecoder().decode(QingTypeInputSourceState.self, from: await InstallationService.command(["--prepare-uninstall"], app: control))
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: QingTypeAppInstallation.bundleID).filter { $0.processIdentifier != getpid() }
    running.forEach { $0.terminate() }
    for _ in 0..<40 {
      if running.allSatisfy(\.isTerminated) { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    func restoreSource() async throws {
      if fm.fileExists(atPath: InstallationService.installedURL.path) { _ = try await InstallationService.command(["--register-input-source"]) }
      let enabled = previous.inputSources.filter { $0.enabled == true }.map(\.id).joined(separator: ",")
      let selected = previous.inputSources.first { $0.selected == true }?.id ?? ""
      _ = try await InstallationService.command(["--restore-uninstall-source", enabled, selected], app: control)
      let state = try JSONDecoder().decode(QingTypeInputSourceState.self, from: await InstallationService.command(["--status"], app: control))
      let expected = Set(previous.inputSources.filter { $0.enabled == true }.map(\.id))
      guard Set(state.inputSources.filter { $0.enabled == true }.map(\.id)) == expected else {
        throw SettingsError.invalid("程序已恢复，输入源需在系统键盘设置中重新添加。")
      }
    }
    guard running.allSatisfy(\.isTerminated) else { try await restoreSource(); throw SettingsError.invalid("输入服务尚未退出，已停止卸载。") }
    let profileLock: QingTypeDataLock
    do { profileLock = try QingTypeDataLock(directory: QingTypePaths.userDirectory, exclusive: true) }
    catch { try await restoreSource(); throw error }
    defer { withExtendedLifetime(profileLock) {} }
    let staging = QingTypePaths.userDirectory.deletingLastPathComponent().appendingPathComponent("清言卸载备份-\(UUID())")
    var stagedURL: URL?
    do {
      _ = try QingTypeProgramMaintenance.stageUninstall(items: items, allowed: allowed, userData: QingTypePaths.userDirectory, staging: staging)
      stagedURL = staging
      // As during installation, stale per-app keyboard tables can retain a
      // removed source. Only the two existing allowlisted cache names move.
      let getconf = Process(); getconf.executableURL = URL(fileURLWithPath: "/usr/bin/getconf"); getconf.arguments = ["DARWIN_USER_CACHE_DIR"]
      let output = Pipe(); getconf.standardOutput = output
      if (try? getconf.run()) != nil {
        let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        getconf.waitUntilExit()
        if getconf.terminationStatus == 0, !path.isEmpty { _ = try? QingTypeInputCache.backUp(root: URL(fileURLWithPath: path), to: staging.appendingPathComponent("input-source-cache")) }
      }
      let result: ([URL: URL], Error?) = await withCheckedContinuation { continuation in
        NSWorkspace.shared.recycle([staging]) { locations, error in continuation.resume(returning: (locations, error)) }
      }
      if let error = result.1 {
        let actual = fm.fileExists(atPath: staging.path) ? staging : result.0[staging] ?? staging
        stagedURL = actual
        throw SettingsError.invalid("无法移到废纸篓。\(error.localizedDescription)")
      }
      stagedURL = nil
      return result.0[staging] ?? staging
    } catch {
      if let stagedURL {
        do { try QingTypeProgramMaintenance.undoStagedUninstall(stagedURL, allowed: allowed); try await restoreSource() }
        catch { throw SettingsError.invalid("卸载恢复未完成，请保留恢复文件夹 \(stagedURL.path)。\(error.localizedDescription)") }
      }
      if fm.fileExists(atPath: InstallationService.installedURL.path) { try? await restoreSource() }
      throw error
    }
  }
}
