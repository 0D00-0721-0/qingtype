//
//  InputSource.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit

final class SquirrelInstaller {
  enum InputMode: String, CaseIterable {
    static let primary = Self.hans
    case hans = "org.qingtype.inputmethod.QingType.Hans"
    case hant = "org.qingtype.inputmethod.QingType.Hant"
  }
  private lazy var inputSources: [String: TISInputSource] = {
    var inputSources = [String: TISInputSource]()
    var matchingSources = [InputMode: TISInputSource]()
    let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    for inputSource in sourceList {
      let sourceIDRef = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
      guard let sourceID = unsafeBitCast(sourceIDRef, to: CFString?.self) as String? else { continue }
      // print("[DEBUG] Examining input source: \(sourceID)")
      inputSources[sourceID] = inputSource
    }
    return inputSources
  }()

  func enabledModes() -> [InputMode] {
    var enabledModes = Set<InputMode>()
    for (mode, inputSource) in getInputSource(modes: InputMode.allCases) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), enabled {
        enabledModes.insert(mode)
      }
      if enabledModes.count == InputMode.allCases.count {
        break
      }
    }
    return Array(enabledModes)
  }

  func status() -> [[String: Any]] {
    InputMode.allCases.map { mode in
      guard let source = inputSources[mode.rawValue] else {
        return ["id": mode.rawValue, "registered": false]
      }
      return ["id": mode.rawValue, "registered": true,
              "enabled": getBool(for: source, key: kTISPropertyInputSourceIsEnabled) ?? false,
              "selected": getBool(for: source, key: kTISPropertyInputSourceIsSelected) ?? false,
              "selectable": getBool(for: source, key: kTISPropertyInputSourceIsSelectCapable) ?? false]
    }
  }

  func register() {
    // Register the installed URL on every update, even if a mode is enabled.
    // Enabled state alone says nothing about another process's cached source.
    let result = TISRegisterInputSource(SquirrelApp.appDir as CFURL)
    print("Register QingType: \(result) from \(SquirrelApp.appDir.path)")
    if result != noErr { exit(1) }
  }

  func enable(modes: [InputMode] = []) {
    let enabledInputModes = enabledModes()
    if !enabledInputModes.isEmpty && modes.isEmpty {
      print("User already enabled QingType method(s): \(enabledInputModes.map { $0.rawValue })")
      // keep user's manually enabled input modes.
      return
    }
    let modesToEnable = modes.isEmpty ? [.primary] : modes
    for (mode, inputSource) in getInputSource(modes: modesToEnable) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), !enabled {
        let error = TISEnableInputSource(inputSource)
        print("Enable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      }
    }
  }

  func select(mode: InputMode? = nil) {
    let enabledInputModes = enabledModes()
    let modeToSelect = mode ?? .primary
    if !enabledInputModes.contains(modeToSelect) {
      if mode != nil {
        enable(modes: [modeToSelect])
      } else {
        print("Default method not enabled yet: \(modeToSelect.rawValue)")
        return
      }
    }
    for (mode, inputSource) in getInputSource(modes: [modeToSelect]) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled),
         let selectable = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelectCapable),
         let selected = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelected),
         enabled && selectable && !selected {
        let error = TISSelectInputSource(inputSource)
        print("Selection \(error == noErr ? "succeeds" : "fails") (OSStatus \(error)) for input source: \(mode.rawValue)")
        if error != noErr { exit(1) }
      } else {
        print("Failed to select \(mode.rawValue)")
      }
    }
  }

  func disable(modes: [InputMode] = []) throws {
    let modesToDisable = modes.isEmpty ? InputMode.allCases : modes
    for (mode, inputSource) in getInputSource(modes: modesToDisable) {
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
          let value = TISGetInputSourceProperty(input, kTISPropertyInputSourceID) else { return nil }
    return unsafeBitCast(value, to: CFString.self) as String
  }

  func uninstallSnapshot() throws -> QingTypeUninstallSnapshot {
    let modes = try InputMode.allCases.map { mode -> QingTypeUninstallSnapshot.Mode in
      guard let source = inputSources[mode.rawValue] else { return .init(id: mode.rawValue, registered: false, enabled: false, selected: false) }
      guard let enabled = getBool(for: source, key: kTISPropertyInputSourceIsEnabled),
            let selected = getBool(for: source, key: kTISPropertyInputSourceIsSelected) else {
        throw SettingsError.invalid("无法确认输入源状态：\(mode.rawValue)。")
      }
      return .init(id: mode.rawValue, registered: true, enabled: enabled, selected: selected)
    }
    return .init(current: currentID(), modes: modes)
  }

  func prepareUninstall() throws -> [[String: Any]] {
    let previous = try QingTypeUninstallGuard.prepare(read: uninstallSnapshot, selectFallback: {
      let candidates = inputSources.filter { id, source in
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
      for mode in previous.modes where mode.enabled {
        guard let source = inputSources[mode.id] else { throw SettingsError.invalid("原输入源已不存在。") }
        if getBool(for: source, key: kTISPropertyInputSourceIsEnabled) != true,
           TISEnableInputSource(source) != noErr { throw SettingsError.invalid("无法恢复原输入源。") }
      }
      if let id = previous.current, id.hasPrefix(QingTypeUninstallGuard.prefix), currentID() != id {
        guard let source = inputSources[id], TISSelectInputSource(source) == noErr else { throw SettingsError.invalid("无法恢复原选中输入源。") }
      }
    })
    return previous.modes.map { ["id": $0.id, "registered": $0.registered, "enabled": $0.enabled, "selected": $0.selected] }
  }

  private func getInputSource(modes: [InputMode]) -> [InputMode: TISInputSource] {
    var matchingSources = [InputMode: TISInputSource]()
    for mode in modes {
      if let inputSource = inputSources[mode.rawValue] {
        matchingSources[mode] = inputSource
      }
    }
    return matchingSources
  }

  private func getBool(for inputSource: TISInputSource, key: CFString!) -> Bool? {
    let enabledRef = TISGetInputSourceProperty(inputSource, key)
    guard let enabled = unsafeBitCast(enabledRef, to: CFBoolean?.self) else { return nil }
    return CFBooleanGetValue(enabled)
  }
}
