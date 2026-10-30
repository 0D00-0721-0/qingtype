import Foundation
import Darwin

/// Only used for short, read-only CLI commands. Files avoid a full pipe hanging
/// the parent; timeout/output bounds apply to old or broken control binaries.
enum QingTypeReadOnlyProbe {
  static func run(_ arguments: [String], app: URL, timeout: TimeInterval = 5) async throws -> Data {
    try await Task.detached { try execute(arguments, app: app, timeout: timeout) }.value
  }

  private static func execute(_ arguments: [String], app: URL, timeout: TimeInterval) throws -> Data {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("qingtype-probe-\(UUID())")
    try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: directory) }
    let output = directory.appendingPathComponent("stdout")
    fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let task = Process()
    task.executableURL = app.appendingPathComponent("Contents/MacOS/QingType")
    task.arguments = arguments; task.standardOutput = handle; task.standardError = FileHandle.nullDevice
    try task.run()
    defer {
      if task.isRunning {
        // This PID is the temporary probe, never the running input service.
        task.terminate()
        let grace = Date().addingTimeInterval(0.2)
        while task.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        task.waitUntilExit()
      }
    }
    let deadline = Date().addingTimeInterval(timeout)
    while task.isRunning {
      let size = (try fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
      guard Date() < deadline, size <= 65_536 else {
        throw SettingsError.invalid("输入源状态查询超时或响应异常，程序保留。")
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          (try fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0 <= 65_536 else {
      throw SettingsError.invalid("无法读取输入源状态，程序保留。")
    }
    return try Data(contentsOf: output)
  }
}
