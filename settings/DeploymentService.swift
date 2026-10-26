import AppKit

enum DeploymentService {
  static func inputMethodURL() -> URL {
    let own = Bundle.main.bundleURL
    let nestedParent = own.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if nestedParent.pathExtension == "app" { return nestedParent }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/QingType.app")
  }

  @MainActor
  static func deploy() async throws -> QingTypeDeploymentReport {
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
    defer {
      if !running.isEmpty {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
      }
    }
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
