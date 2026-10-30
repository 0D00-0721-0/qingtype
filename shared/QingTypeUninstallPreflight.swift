import Foundation

/// A fresh, read-only snapshot. A disabled parent may retain enabled modes;
/// those stored preferences alone do not make the input method selectable.
struct QingTypeGuidedUninstallState: Codable, Equatable {
  var format = 1
  var current: String?
  var parentEnabled: Bool?
  var modes: [Mode]
  var inputAvailable: Bool {
    parentEnabled == true && modes.contains { $0.registered && $0.enabled == true }
  }
  struct Mode: Codable, Equatable {
    var id: String
    var registered: Bool
    var enabled: Bool?
    var selected: Bool?
  }
}

enum QingTypeUninstallDecision: Equatable {
  case checking, removeInputSource, ready, unknown
  var message: String {
    switch self {
    case .checking: return "正在检查系统输入源状态…"
    case .removeInputSource: return "请先切换到 ABC 等其他输入源，再在「系统设置 → 键盘 → 文字输入 → 输入源」移除清言，完成后回来卸载。"
    case .ready: return "系统输入源已移除，可以卸载程序；个人数据将保留。"
    case .unknown: return "暂时无法确认系统输入源状态，程序保留。请重新检查；如仍失败，请导出诊断摘要。"
    }
  }
}

enum QingTypeUninstallPreflight {
  static func decision(for state: QingTypeGuidedUninstallState) -> QingTypeUninstallDecision {
    let prefix = QingTypeUninstallGuard.prefix
    let ids = Set([prefix + ".Hans", prefix + ".Hant"])
    guard state.format == 1, let current = state.current, !current.isEmpty,
          let parent = state.parentEnabled, state.modes.count == ids.count,
          Set(state.modes.map(\.id)) == ids,
          state.modes.allSatisfy({ mode in
            mode.registered ? mode.enabled != nil && mode.selected != nil : mode.enabled != true && mode.selected != true
          }) else { return .unknown }
    if current == prefix || current.hasPrefix(prefix + ".") { return .removeInputSource }
    guard !state.modes.contains(where: { $0.selected == true }) else { return .unknown }
    return parent ? .removeInputSource : .ready
  }

  static func requireRemoved(_ state: QingTypeGuidedUninstallState) throws {
    let result = decision(for: state)
    guard result == .ready else { throw SettingsError.invalid(result.message) }
  }

  static func read(app: URL) async throws -> QingTypeGuidedUninstallState {
    let help = String(decoding: try await QingTypeReadOnlyProbe.run(["--help"], app: app), as: UTF8.self)
    guard help.split(whereSeparator: \.isWhitespace).contains("--uninstall-status") else {
      throw SettingsError.invalid("卸载状态查询程序版本过旧，请从新版完整清言应用执行卸载。")
    }
    let data = try await QingTypeReadOnlyProbe.run(["--uninstall-status"], app: app)
    let state = try JSONDecoder().decode(QingTypeGuidedUninstallState.self, from: data)
    guard decision(for: state) != .unknown else { throw SettingsError.invalid(QingTypeUninstallDecision.unknown.message) }
    return state
  }

  // Compatibility for old isolated tests/callers. Missing parent/current state
  // is never sufficient to authorize the production guided workflow.
  static func blockedReason(for state: QingTypeInputSourceState) -> String? {
    if state.inputSources.contains(where: { $0.enabled == true || $0.selected == true }) {
      return QingTypeUninstallDecision.removeInputSource.message
    }
    let ids = Set([QingTypeUninstallGuard.prefix + ".Hans", QingTypeUninstallGuard.prefix + ".Hant"])
    if state.inputSources.count == ids.count, Set(state.inputSources.map(\.id)) == ids,
       state.inputSources.allSatisfy({ !$0.registered }) { return nil }
    return QingTypeUninstallDecision.unknown.message
  }
}
