import Foundation

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

enum QingTypeInstallCommands {
  static func run(_ arguments: [String], app: URL) async throws -> Data {
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

  static func verifySignature(_ app: URL) throws {
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    task.arguments = ["--verify", "--deep", "--strict", app.path]
    task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
    try task.run(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw SettingsError.invalid("输入法程序签名校验失败，请重新下载清言。") }
  }

  static func cacheRoot() throws -> URL {
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/getconf"); task.arguments = ["DARWIN_USER_CACHE_DIR"]
    let output = Pipe(); task.standardOutput = output
    try task.run(); let path = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines); task.waitUntilExit()
    guard task.terminationStatus == 0, !path.isEmpty, path.hasPrefix("/") else { throw SettingsError.invalid("无法确定输入源缓存目录，安装已停止。") }
    return URL(fileURLWithPath: path)
  }
}

final class QingTypeInstallationSession {
  typealias Command = ([String], URL) async throws -> Data
  let before: QingTypeInputSourceState
  let cacheRoot: URL
  let cacheBackup: URL
  let command: Command

  init(before: QingTypeInputSourceState, cacheRoot: URL, cacheBackup: URL, command: @escaping Command = QingTypeInstallCommands.run) {
    self.before = before; self.cacheRoot = cacheRoot; self.cacheBackup = cacheBackup; self.command = command
  }

  static func state(app: URL, command: Command = QingTypeInstallCommands.run) async throws -> QingTypeInputSourceState {
    let state = try JSONDecoder().decode(QingTypeInputSourceState.self, from: await command(["--status"], app))
    let expected = Set(["org.qingtype.inputmethod.QingType.Hans", "org.qingtype.inputmethod.QingType.Hant"])
    guard state.inputSources.count == expected.count, Set(state.inputSources.map(\.id)) == expected else {
      throw SettingsError.invalid("无法确认完整输入源状态，已停止安装。")
    }
    return state
  }

  func activate(app: URL) async throws {
    _ = try QingTypeInputCache.backUp(root: cacheRoot, to: cacheBackup)
    _ = try await command(["--register-input-source"], app)
    for _ in 0..<3 {
      _ = try await command(["--enable-input-source", "org.qingtype.inputmethod.QingType.Hans"], app)
      if try await Self.state(app: app, command: command).enabled { return }
      try await Task.sleep(nanoseconds: 800_000_000)
    }
    throw SettingsError.invalid("系统未确认启用清言输入源。")
  }

  func restore(app: URL, existed: Bool) async throws {
    var errors: [String] = []
    do { try QingTypeInputCache.restore(root: cacheRoot, from: cacheBackup) }
    catch { errors.append(error.localizedDescription) }
    do {
      if existed { _ = try await command(["--register-input-source"], app) }
      let enabled = before.inputSources.filter { $0.enabled == true }.map(\.id)
      let disabled = before.inputSources.filter { $0.enabled != true }.map(\.id)
      if !disabled.isEmpty { _ = try await command(["--disable-input-source"] + disabled, app) }
      if !enabled.isEmpty { _ = try await command(["--enable-input-source"] + enabled, app) }
      if let selected = before.inputSources.first(where: { $0.selected == true }) {
        _ = try await command(["--select-input-source", selected.id], app)
      }
      let after = try await Self.state(app: app, command: command)
      for previous in before.inputSources {
        guard let current = after.inputSources.first(where: { $0.id == previous.id }),
              current.registered == previous.registered,
              (current.enabled == true) == (previous.enabled == true),
              (current.selected == true) == (previous.selected == true) else {
          throw SettingsError.invalid("系统输入源状态与安装前不同，请在键盘设置中检查；首次安装的系统注册可能仍保留。")
        }
      }
    } catch { errors.append(error.localizedDescription) }
    if !errors.isEmpty { throw SettingsError.invalid(errors.joined(separator: "；")) }
  }
}
