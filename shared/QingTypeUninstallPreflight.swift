import Foundation

/// Uninstall requires the user to remove QingType from the input source list
/// first: macOS 27 cannot reliably disable a parent input source from a process
/// (the API reports success while the source stays enabled), so the installer
/// must not try. This check only reads state and never changes it.
enum QingTypeUninstallPreflight {
  static func blockedReason(for state: QingTypeInputSourceState) -> String? {
    let enabled = state.inputSources.filter { $0.enabled == true }
    guard !enabled.isEmpty else { return nil }
    return "清言输入源仍在系统输入列表中。请先在「系统设置 → 键盘 → 文字输入 → 输入源」移除清言，再回来卸载；程序、配置和用户数据都未更改。"
  }
}
