import Foundation

enum QingTypeUninstallTransaction {
  static func checkControl(_ app: URL) async throws {
    let help = try await QingTypeInstallCommands.run(["--help"], app: app)
    guard String(decoding: help, as: UTF8.self).contains("--verify-uninstall") else {
      throw SettingsError.invalid("卸载控制程序版本过旧，请先构建或打开新版清言。")
    }
  }

  static func run(prepare: () async throws -> QingTypeInputSourceState,
                  verify: () async throws -> Void,
                  stop: () async throws -> Void,
                  remove: () throws -> Void,
                  restore: (QingTypeInputSourceState) async throws -> Void) async throws {
    let previous = try await prepare()
    do {
      try await verify()
      try await stop()
      try await verify()
      try remove()
    } catch {
      let reason = error.localizedDescription
      do { try await restore(previous) }
      catch { throw SettingsError.invalid("卸载已停止，输入源恢复未确认：\(reason)；\(error.localizedDescription)") }
      throw SettingsError.invalid("卸载已停止，原输入源已恢复：\(reason)")
    }
  }
}
