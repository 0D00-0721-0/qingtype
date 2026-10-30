//
//  InputSource.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit

enum QingTypeInputSourceQuery {
  // Validate every CF element before asking the Swift bridge for TIS objects.
  static func decode(_ result: Any?) throws -> [TISInputSource] {
    guard let result else { throw SettingsError.invalid("系统输入源查询失败。") }
    guard let objects = result as? [AnyObject],
          objects.allSatisfy({ CFGetTypeID($0) == TISInputSourceGetTypeID() }),
          let sources = result as? [TISInputSource] else {
      throw SettingsError.invalid("系统输入源查询返回了异常类型。")
    }
    return sources
  }
}

final class SquirrelInstaller {
  typealias PropertyQuery = (TISInputSource, CFString) -> UnsafeMutableRawPointer?
  private let sourceQuery: () -> Any?
  private let propertyQuery: PropertyQuery

  init(sourceQuery: @escaping () -> Any? = { TISCreateInputSourceList(nil, true)?.takeRetainedValue() },
       propertyQuery: @escaping PropertyQuery = { TISGetInputSourceProperty($0, $1) }) {
    self.sourceQuery = sourceQuery
    self.propertyQuery = propertyQuery
  }

  enum InputMode: String, CaseIterable {
    static let primary = Self.hans
    case hans = "org.qingtype.inputmethod.QingType.Hans"
    case hant = "org.qingtype.inputmethod.QingType.Hant"
  }
  private var inputSources: [String: TISInputSource] {
    get throws {
      var inputSources = [String: TISInputSource]()
      for inputSource in try QingTypeInputSourceQuery.decode(sourceQuery()) {
        guard let value = propertyQuery(inputSource, kTISPropertyInputSourceID),
              CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue()) == CFStringGetTypeID() else {
          throw SettingsError.invalid("系统输入源标识无法确认。")
        }
        let sourceID = unsafeBitCast(value, to: CFString.self) as String
        inputSources[sourceID] = inputSource
      }
      return inputSources
    }
  }

  func enabledModes() throws -> [InputMode] {
    var enabledModes = Set<InputMode>()
    for (mode, inputSource) in try getInputSource(modes: InputMode.allCases) {
      guard let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled) else {
        throw SettingsError.invalid("无法确认输入源启用状态：\(mode.rawValue)。")
      }
      if enabled { enabledModes.insert(mode) }
      if enabledModes.count == InputMode.allCases.count {
        break
      }
    }
    return Array(enabledModes)
  }

  func status() throws -> [[String: Any]] {
    let sources = try inputSources
    return try InputMode.allCases.map { mode in
      guard let source = sources[mode.rawValue] else {
        return ["id": mode.rawValue, "registered": false]
      }
      guard let enabled = getBool(for: source, key: kTISPropertyInputSourceIsEnabled),
            let selected = getBool(for: source, key: kTISPropertyInputSourceIsSelected),
            let selectable = getBool(for: source, key: kTISPropertyInputSourceIsSelectCapable) else {
        throw SettingsError.invalid("无法确认输入源状态：\(mode.rawValue)。")
      }
      return ["id": mode.rawValue, "registered": true,
              "enabled": enabled, "selected": selected, "selectable": selectable]
    }
  }

  func guidedUninstallState() throws -> QingTypeGuidedUninstallState {
    let prefix = QingTypeUninstallGuard.prefix
    func query(all: Bool) throws -> [TISInputSource] {
      guard let result = TISCreateInputSourceList(nil, all),
            let sources = result.takeRetainedValue() as? [TISInputSource] else {
        throw SettingsError.invalid("系统输入源查询失败，程序保留。")
      }
      return sources
    }
    func identifier(_ source: TISInputSource) throws -> String {
      guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
            CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue()) == CFStringGetTypeID() else {
        throw SettingsError.invalid("输入源标识无法确认，程序保留。")
      }
      return unsafeBitCast(value, to: CFString.self) as String
    }
    // Query the full enabled list, which always includes a keyboard source.
    // On this Mac a filtered query with no matching parent returns nil; that
    // cannot distinguish 'removed' from an API failure. A successful full list
    // with no parent is explicit negative evidence, not an assumed success.
    let enabledIDs = try Set(query(all: false).map(identifier))
    let installed = try query(all: true)
    var byID: [String: TISInputSource] = [:]
    for source in installed {
      let id = try identifier(source)
      guard id == prefix || id.hasPrefix(prefix + ".") else { continue }
      guard byID[id] == nil else { throw SettingsError.invalid("输入源状态重复，程序保留。") }
      byID[id] = source
    }
    let modes = try InputMode.allCases.map { mode -> QingTypeGuidedUninstallState.Mode in
      guard let source = byID[mode.rawValue] else {
        return .init(id: mode.rawValue, registered: false, enabled: false, selected: false)
      }
      guard let enabled = getBool(for: source, key: kTISPropertyInputSourceIsEnabled),
            let selected = getBool(for: source, key: kTISPropertyInputSourceIsSelected) else {
        throw SettingsError.invalid("输入源状态无法确认，程序保留。")
      }
      return .init(id: mode.rawValue, registered: true, enabled: enabled, selected: selected)
    }
    return .init(current: currentID(), parentEnabled: enabledIDs.contains(prefix), modes: modes)
  }

  func register() {
    // Register the installed URL on every update, even if a mode is enabled.
    // Enabled state alone says nothing about another process's cached source.
    let result = TISRegisterInputSource(SquirrelApp.appDir as CFURL)
    print("Register QingType: \(result) from \(SquirrelApp.appDir.path)")
    if result != noErr { exit(1) }
  }

  func enable(modes: [InputMode] = []) throws {
    let enabledInputModes = try enabledModes()
    if !enabledInputModes.isEmpty && modes.isEmpty {
      print("User already enabled QingType method(s): \(enabledInputModes.map { $0.rawValue })")
      // keep user's manually enabled input modes.
      return
    }
    let modesToEnable = modes.isEmpty ? [.primary] : modes
    for (mode, inputSource) in try getInputSource(modes: modesToEnable) {
      guard let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled) else {
        throw SettingsError.invalid("无法确认输入源启用状态：\(mode.rawValue)。")
      }
      if !enabled {
        let error = TISEnableInputSource(inputSource)
        print("Enable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      }
    }
  }

  func select(mode: InputMode? = nil) throws {
    let enabledInputModes = try enabledModes()
    let modeToSelect = mode ?? .primary
    if !enabledInputModes.contains(modeToSelect) {
      if mode != nil {
        try enable(modes: [modeToSelect])
      } else {
        print("Default method not enabled yet: \(modeToSelect.rawValue)")
        return
      }
    }
    for (mode, inputSource) in try getInputSource(modes: [modeToSelect]) {
      guard let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled),
            let selectable = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelectCapable),
            let selected = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelected) else {
        throw SettingsError.invalid("无法确认输入源选择状态：\(mode.rawValue)。")
      }
      if enabled && selectable {
        if selected {
          print("Input source already selected: \(mode.rawValue)")
        } else {
          let error = TISSelectInputSource(inputSource)
          print("Selection \(error == noErr ? "succeeds" : "fails") (OSStatus \(error)) for input source: \(mode.rawValue)")
          if error != noErr { exit(1) }
        }
      } else {
        print("Failed to select \(mode.rawValue)")
      }
    }
  }

  func disable(modes: [InputMode] = []) throws {
    let modesToDisable = modes.isEmpty ? InputMode.allCases : modes
    for (mode, inputSource) in try getInputSource(modes: modesToDisable) {
      guard let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled) else {
        throw SettingsError.invalid("无法确认输入源状态：\(mode.rawValue)。")
      }
      if enabled {
        let error = TISDisableInputSource(inputSource)
        guard error == noErr else { throw SettingsError.invalid("无法停用输入源 \(mode.rawValue)（\(error)）。") }
      }
    }
  }

  private func currentID() -> String? {
    guard let input = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let value = TISGetInputSourceProperty(input, kTISPropertyInputSourceID),
          CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue()) == CFStringGetTypeID() else { return nil }
    return unsafeBitCast(value, to: CFString.self) as String
  }

  func uninstallSnapshot() throws -> QingTypeUninstallSnapshot {
    let sources = try inputSources
    let parentEnabled: Bool?
    if let parent = sources[QingTypeUninstallGuard.prefix] {
      guard let enabled = getBool(for: parent, key: kTISPropertyInputSourceIsEnabled) else {
        throw SettingsError.invalid("无法确认清言父输入源状态，已停止卸载。")
      }
      parentEnabled = enabled
    } else { parentEnabled = nil }
    let modes = try InputMode.allCases.map { mode -> QingTypeUninstallSnapshot.Mode in
      guard let source = sources[mode.rawValue] else { return .init(id: mode.rawValue, registered: false, enabled: false, selected: false) }
      guard let enabled = getBool(for: source, key: kTISPropertyInputSourceIsEnabled),
            let selected = getBool(for: source, key: kTISPropertyInputSourceIsSelected) else {
        throw SettingsError.invalid("无法确认输入源状态：\(mode.rawValue)。")
      }
      return .init(id: mode.rawValue, registered: true, enabled: enabled, selected: selected)
    }
    return .init(current: currentID(), modes: modes, parentEnabled: parentEnabled)
  }

  func prepareUninstall() throws -> [[String: Any]] {
    let previous = try QingTypeUninstallGuard.prepare(read: uninstallSnapshot, selectFallback: {
      let candidates = try inputSources.filter { id, source in
        !id.hasPrefix("org.qingtype.") && getBool(for: source, key: kTISPropertyInputSourceIsEnabled) == true &&
          getBool(for: source, key: kTISPropertyInputSourceIsSelectCapable) == true
      }.sorted { left, right in
        let preferred = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        func rank(_ source: (key: String, value: TISInputSource)) -> Int {
          preferred.firstIndex(of: source.key) ?? (getBool(for: source.value, key: kTISPropertyInputSourceIsASCIICapable) == true ? 2 : 3)
        }
        let a = rank(left), b = rank(right)
        return a == b ? left.key < right.key : a < b
      }
      guard let fallback = candidates.first, TISSelectInputSource(fallback.value) == noErr else {
        throw SettingsError.invalid("请先切换到 ABC 等其他输入法，再卸载清言。")
      }
    }, disable: { try disable() }, restore: { previous in
      let sources = try inputSources
      for mode in previous.modes where mode.enabled {
        guard let source = sources[mode.id] else { throw SettingsError.invalid("原输入源已不存在。") }
        if getBool(for: source, key: kTISPropertyInputSourceIsEnabled) != true,
           TISEnableInputSource(source) != noErr { throw SettingsError.invalid("无法恢复原输入源。") }
      }
      if let id = previous.current, id.hasPrefix(QingTypeUninstallGuard.prefix), currentID() != id {
        guard let source = sources[id], TISSelectInputSource(source) == noErr else { throw SettingsError.invalid("无法恢复原选中输入源。") }
      }
    })
    return previous.modes.map { ["id": $0.id, "registered": $0.registered, "enabled": $0.enabled, "selected": $0.selected] }
  }

  private func getInputSource(modes: [InputMode]) throws -> [InputMode: TISInputSource] {
    let sources = try inputSources
    var matchingSources = [InputMode: TISInputSource]()
    for mode in modes {
      if let inputSource = sources[mode.rawValue] {
        matchingSources[mode] = inputSource
      }
    }
    return matchingSources
  }

  private func getBool(for inputSource: TISInputSource, key: CFString!) -> Bool? {
    guard let value = propertyQuery(inputSource, key),
          CFGetTypeID(Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue()) == CFBooleanGetTypeID() else { return nil }
    let enabled = unsafeBitCast(value, to: CFBoolean.self)
    return CFBooleanGetValue(enabled)
  }
}
