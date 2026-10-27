import AppKit

enum LearningService {
  @MainActor
  static func run(action: String, source: URL?, saved: QingTypeSettings) async throws -> QingTypeLearningResult {
    guard try QingTypeSettings.load() == saved else { throw SettingsError.invalid("设置文件已改变，请重开设置后再操作。") }
    let appURL = DeploymentService.inputMethodURL()
    guard try QingTypeAppInstallation.version(at: appURL).compare("0.5.0", options: .numeric) != .orderedAscending else {
      throw SettingsError.invalid("请先在“开始使用”更新输入服务，再管理学习数据。")
    }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: QingTypeAppInstallation.bundleID)
    running.forEach { $0.terminate() }
    for _ in 0..<40 {
      if running.allSatisfy(\.isTerminated) { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard running.allSatisfy(\.isTerminated) else { throw SettingsError.invalid("请结束当前输入，待输入服务退出后重试。") }
    var restart = true
    defer {
      if restart && !running.isEmpty {
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
      }
    }
    let result = try await Task.detached {
      let task = Process(); task.executableURL = appURL.appendingPathComponent("Contents/MacOS/QingType")
      task.arguments = ["--learning-data-worker", action] + (source.map { [$0.path] } ?? [])
      let output = Pipe(); task.standardOutput = output
      let log = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-learning-worker-\(UUID()).log")
      FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
      let errors = try FileHandle(forWritingTo: log)
      defer { try? errors.close(); try? FileManager.default.removeItem(at: log) }
      task.standardError = errors
      try task.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
      try errors.synchronize()
      return (task.terminationStatus, data, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }.value
    if result.0 == 2 { restart = false }
    guard result.0 == 0 else { throw SettingsError.invalid("学习数据操作失败：\(result.2.suffix(1200))") }
    return try JSONDecoder().decode(QingTypeLearningResult.self, from: result.1)
  }
}
