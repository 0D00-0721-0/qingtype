import Foundation

struct QingTypeUninstallSnapshot {
  struct Mode {
    var id: String
    var registered: Bool
    var enabled: Bool
    var selected: Bool
  }
  var current: String?
  var modes: [Mode]
  // Check the parent as well as the individual input modes.
  var parentEnabled: Bool? = nil
}

enum QingTypeUninstallGuard {
  static let prefix = "org.qingtype.inputmethod.QingType"

  static func validateModeIDs(_ ids: [String], valid: Set<String>) throws {
    guard ids.allSatisfy(valid.contains) else { throw SettingsError.invalid("输入源标识无效，未停用任何输入源。") }
  }

  static func requireDataRemovalSafe(installed: Bool, running: Bool, otherSettings: Bool) throws {
    guard !installed && !running else { throw SettingsError.invalid("请先卸载清言输入法并退出输入服务，再删除用户数据。") }
    guard !otherSettings else { throw SettingsError.invalid("请先退出其他清言设置窗口，用户数据未删除。") }
  }

  static func verify(_ state: QingTypeUninstallSnapshot) throws {
    guard let current = state.current, !current.hasPrefix(prefix),
          state.modes.allSatisfy({ !$0.enabled && !$0.selected }),
          (state.parentEnabled == false ||
           (state.parentEnabled == nil && state.modes.allSatisfy({ !$0.registered }))) else {
      throw SettingsError.invalid("未确认切换到其他输入源并停用清言，已停止卸载并保留程序。请检查系统输入法列表；若仍无法停用，请在清言设置中导出诊断。")
    }
  }

  static func prepare(read: () throws -> QingTypeUninstallSnapshot,
                      selectFallback: () throws -> Void,
                      disable: () throws -> Void,
                      restore: (QingTypeUninstallSnapshot) throws -> Void) throws -> QingTypeUninstallSnapshot {
    let previous = try read()
    guard let current = previous.current else { throw SettingsError.invalid("无法确认当前输入源，已停止卸载。") }
    var changed = false
    do {
      if current.hasPrefix(prefix) || previous.modes.contains(where: \.selected) {
        changed = true
        try selectFallback()
        guard let replacement = try read().current, !replacement.hasPrefix(prefix) else {
          throw SettingsError.invalid("系统尚未切换到其他输入源。")
        }
      }
      changed = true
      try disable()
      try verify(read())
      return previous
    } catch {
      let reason = error.localizedDescription
      if changed {
        do {
          try restore(previous)
          let after = try read()
          let oldEnabled = Set(previous.modes.filter(\.enabled).map(\.id))
          let newEnabled = Set(after.modes.filter(\.enabled).map(\.id))
          let oldSelected = Set(previous.modes.filter(\.selected).map(\.id))
          let newSelected = Set(after.modes.filter(\.selected).map(\.id))
          guard oldEnabled == newEnabled, oldSelected == newSelected, previous.current == after.current,
                previous.parentEnabled == after.parentEnabled else {
            throw SettingsError.invalid("输入源状态与卸载前不同。")
          }
        } catch { throw SettingsError.invalid("卸载已停止，输入源恢复未确认：\(reason)；\(error.localizedDescription)") }
      }
      throw SettingsError.invalid("卸载已停止，原输入源状态已恢复：\(reason)")
    }
  }
}
