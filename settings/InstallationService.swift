import AppKit

struct QingTypeInputSourceState: Decodable {
  var inputSources: [Source]
  struct Source: Decodable {
    var id: String
    var registered: Bool
    var enabled: Bool?
    var selected: Bool?
  }
  var enabled: Bool { inputSources.contains { $0.id.hasSuffix(".Hans") && $0.registered && $0.enabled == true } }
  var selected: Bool { inputSources.contains { $0.selected == true } }
}

enum InstallationService {
  static let installedURL = QingTypePaths.userDirectory.deletingLastPathComponent().appendingPathComponent("Input Methods/QingType.app")
  static var payload: URL? {
    guard let resources = Bundle.main.resourceURL else { return nil }
    let url = resources.appendingPathComponent("InputMethod/QingType.app")
    return (try? QingTypeAppInstallation.version(at: url)) == nil ? nil : url
  }
  static var installedVersion: String? { try? QingTypeAppInstallation.version(at: installedURL) }

  static func command(_ arguments: [String], app: URL = installedURL) async throws -> Data {
    try await Task.detached {
      let task = Process(); task.executableURL = app.appendingPathComponent("Contents/MacOS/QingType"); task.arguments = arguments
      let output = Pipe(); task.standardOutput = output
      let log = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-install-\(UUID()).log")
      FileManager.default.createFile(atPath: log.path, contents: nil)
      let errors = try FileHandle(forWritingTo: log)
      defer { try? errors.close(); try? FileManager.default.removeItem(at: log) }
      task.standardError = errors
      try task.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
      guard task.terminationStatus == 0 else {
        let details = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        throw SettingsError.invalid("输入法操作失败：\(details.suffix(1200))")
      }
      return data
    }.value
  }
  static func state() async throws -> QingTypeInputSourceState { try JSONDecoder().decode(QingTypeInputSourceState.self, from: await command(["--status"])) }

  @MainActor
  static func install() async throws -> QingTypeDeploymentReport {
    let source = payload
    guard source != nil || installedVersion != nil else { throw SettingsError.invalid("没有找到输入法程序，请从完整的清言应用重新安装。") }
    if let source {
      let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
      task.arguments = ["--verify", "--deep", "--strict", source.path]
      task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
      try task.run(); task.waitUntilExit()
      guard task.terminationStatus == 0 else { throw SettingsError.invalid("输入法程序校验失败，请重新下载清言。") }
    }
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
    func activate() async throws {
      let getconf = Process(); getconf.executableURL = URL(fileURLWithPath: "/usr/bin/getconf"); getconf.arguments = ["DARWIN_USER_CACHE_DIR"]
      let output = Pipe(); getconf.standardOutput = output
      try getconf.run(); let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines); getconf.waitUntilExit()
      if getconf.terminationStatus == 0, !path.isEmpty { _ = try QingTypeInputCache.backUp(root: URL(fileURLWithPath: path), to: backup.appendingPathComponent("input-source-cache")) }
      _ = try await command(["--register-input-source"])
      for _ in 0..<3 {
        _ = try await command(["--enable-input-source"])
        if try await state().enabled { break }
        try await Task.sleep(nanoseconds: 800_000_000)
      }
      guard try await state().enabled else { throw SettingsError.invalid("程序已复制，但系统尚未启用清言。请打开键盘设置添加清言后重试。") }
      let settings = try QingTypeSettings.load()
      report = try await QingTypeConfigurationApply.apply(settings, to: QingTypePaths.userDirectory) {
        try await DeploymentService.runWorker(appURL: installedURL)
      }
    }
    if let source {
      try await QingTypeAppInstallation.install(source: source, destination: installedURL, backups: backup, activate: activate)
    } else { try await activate() }
    guard let report else { throw SettingsError.invalid("输入法尚未完成初始化。") }
    return report
  }
}
