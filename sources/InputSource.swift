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

  func disable(modes: [InputMode] = []) {
    let modesToDisable = modes.isEmpty ? InputMode.allCases : modes
    for (mode, inputSource) in getInputSource(modes: modesToDisable) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), enabled {
        let error = TISDisableInputSource(inputSource)
        print("Disable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      }
    }
  }

  func prepareUninstall() throws -> [[String: Any]] {
    let previous = status()
    let selected = previous.first { $0["selected"] as? Bool == true }?["id"] as? String
    func currentID() -> String? {
      guard let input = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let value = TISGetInputSourceProperty(input, kTISPropertyInputSourceID) else { return nil }
      return unsafeBitCast(value, to: CFString.self) as String
    }
    guard let current = currentID() else { throw SettingsError.invalid("无法确认当前输入源，请切换到其他输入法后再卸载。") }
    if selected != nil || current.hasPrefix("org.qingtype.") {
      let candidates = inputSources.filter { id, source in
        !id.hasPrefix("org.qingtype.") && getBool(for: source, key: kTISPropertyInputSourceIsEnabled) == true &&
          getBool(for: source, key: kTISPropertyInputSourceIsSelectCapable) == true &&
          getBool(for: source, key: kTISPropertyInputSourceIsASCIICapable) == true
      }.sorted { left, right in
        let preferred = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        return (preferred.firstIndex(of: left.key) ?? 99) < (preferred.firstIndex(of: right.key) ?? 99)
      }
      guard let fallback = candidates.first, TISSelectInputSource(fallback.value) == noErr else {
        throw SettingsError.invalid("请先切换到 ABC 等其他输入法，再卸载清言。")
      }
      guard let changed = currentID(), !changed.hasPrefix("org.qingtype.") else {
        throw SettingsError.invalid("系统尚未切换到其他输入法，已停止卸载。")
      }
    }
    for (_, source) in getInputSource(modes: InputMode.allCases) {
      if getBool(for: source, key: kTISPropertyInputSourceIsEnabled) == true,
         TISDisableInputSource(source) != noErr {
        let enabled = previous.filter { $0["enabled"] as? Bool == true }.compactMap { ($0["id"] as? String).flatMap(InputMode.init(rawValue:)) }
        if !enabled.isEmpty { enable(modes: enabled) }
        if let selected, let mode = InputMode(rawValue: selected) { select(mode: mode) }
        throw SettingsError.invalid("无法停用系统输入源，已停止卸载。")
      }
    }
    return previous
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
