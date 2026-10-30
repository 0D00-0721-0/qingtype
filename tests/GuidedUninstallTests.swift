import Foundation

@main
struct GuidedUninstallTests {
  static func main() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("qingtype-guided-test-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    var checks = 0
    func expect(_ value: Bool, _ label: String) throws {
      guard value else { throw SettingsError.invalid("FAIL: \(label)") }; checks += 1
    }
    func rejects(_ label: String = "rejection", _ action: () async throws -> Void) async throws {
      do { try await action() } catch { checks += 1; return }
      throw SettingsError.invalid("FAIL: expected guided uninstall rejection: \(label)")
    }
    let prefix = QingTypeUninstallGuard.prefix
    let ready = QingTypeGuidedUninstallState(current: "com.apple.keylayout.ABC", parentEnabled: false,
      modes: ["Hans", "Hant"].map { .init(id: prefix + "." + $0, registered: true, enabled: false, selected: false) })
    try expect(QingTypeUninstallPreflight.decision(for: ready) == .ready, "removed source is ready")
    var latent = ready; latent.modes[0].enabled = true
    try expect(QingTypeUninstallPreflight.decision(for: latent) == .ready, "disabled parent may retain an enabled, unselected mode")
    try expect(!latent.inputAvailable, "a removed parent cannot advertise ready Chinese input")
    var available = latent; available.parentEnabled = true
    try expect(available.inputAvailable, "an enabled parent and mode make Chinese input available")
    var enabled = ready; enabled.parentEnabled = true
    try expect(QingTypeUninstallPreflight.decision(for: enabled) == .removeInputSource, "enabled parent blocks even with disabled modes")
    var active = ready; active.current = prefix + ".Hans"; active.modes[0].selected = true
    try expect(QingTypeUninstallPreflight.decision(for: active) != .ready, "current QingType blocks despite parent flag")
    for index in 0..<8 {
      var invalid = ready
      switch index {
      case 0: invalid.current = nil
      case 1: invalid.parentEnabled = nil
      case 2: invalid.modes = []
      case 3: invalid.modes.removeLast()
      case 4: invalid.modes[1].id = invalid.modes[0].id
      case 5: invalid.modes[0].enabled = nil
      case 6: invalid.modes[0].selected = nil
      default: invalid.modes[0].selected = true
      }
      try expect(QingTypeUninstallPreflight.decision(for: invalid) != .ready, "unknown/inconsistent snapshot \(index) blocks")
    }
    let profile = root.appendingPathComponent("profile")
    try fm.createDirectory(at: profile, withIntermediateDirectories: false)
    let sentinel = Data("synthetic dictionary, learning, models and settings".utf8)
    for name in ["personal.txt", "learning.userdb", "settings.json", "model.gram"] { try sentinel.write(to: profile.appendingPathComponent(name)) }
    for failure in ["initial", "stop", "after-stop", "relaunch", "lock", "move", "trash", "trash-partial", "none"] {
      let app = root.appendingPathComponent(failure + "/QingType.app")
      try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
      let info = ["CFBundleIdentifier": prefix, "CFBundleExecutable": "QingType", "CFBundleShortVersionString": "0.6.5"]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
      try sentinel.write(to: app.appendingPathComponent("Contents/MacOS/QingType"))
      try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("Contents/MacOS/QingType").path)
      var reads = 0, stopped = false, moved = false
      let work = {
        _ = try await QingTypeGuidedUninstall.run(read: {
          reads += 1
          return failure == "initial" || (failure == "after-stop" && reads > 1) ? enabled : ready
        }, stop: {
          if failure == "stop" { throw SettingsError.invalid("injected stop failure") }; stopped = true
        }, requireStopped: {
          if failure == "relaunch" { throw SettingsError.invalid("injected service relaunch") }
        }, acquireDataLock: {
          if failure == "lock" { throw SettingsError.invalid("injected lock failure") }
          return try QingTypeDataLock(directory: profile, exclusive: true)
        }, remove: {
          moved = true
          return try await QingTypeGuidedUninstall.removePrograms(items: [.init(url: app, kind: .inputService)], allowed: [app], userData: profile,
            staging: root.appendingPathComponent("stage-" + failure), afterMove: {
              if failure == "move" { throw SettingsError.invalid("injected move failure") }
            }, recycle: { stage in
              if failure == "trash" { throw SettingsError.invalid("injected trash failure") }
              let trash = root.appendingPathComponent("trash-" + failure)
              try fm.moveItem(at: stage, to: trash)
              if failure == "trash-partial" { return .init(location: trash, error: SettingsError.invalid("injected partial recycle failure")) }
              return .init(location: trash)
            })
        })
      }
      if failure == "none" { try await work(); try expect(!fm.fileExists(atPath: app.path) && reads == 2 && stopped, "successful production flow verifies after stop and moves program") }
      else {
        try await rejects(failure, work)
        try expect(fm.fileExists(atPath: app.path), "\(failure) preserves/restores the program")
        if ["initial", "stop", "after-stop", "relaunch", "lock"].contains(failure) { try expect(!moved, "\(failure) never enters removal") }
        if failure == "initial" { try expect(!stopped, "enabled source is rejected before stopping service") }
      }
      for name in ["personal.txt", "learning.userdb", "settings.json", "model.gram"] {
        try expect(try Data(contentsOf: profile.appendingPathComponent(name)) == sentinel, "\(failure) preserves \(name)")
      }
    }
    let fake = root.appendingPathComponent("probe.app")
    let binary = fake.appendingPathComponent("Contents/MacOS/QingType")
    try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    func script(_ value: String) throws { try Data(value.utf8).write(to: binary); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path) }
    let json = String(decoding: try JSONEncoder().encode(ready), as: UTF8.self)
    try script("#!/bin/sh\nif [ \"$1\" = --help ]; then echo --uninstall-status; else echo '\(json)'; fi\n")
    try expect(try await QingTypeUninstallPreflight.read(app: fake) == ready, "read-only subprocess decodes the versioned probe")
    try script("#!/bin/sh\necho old-help\n")
    try await rejects { _ = try await QingTypeUninstallPreflight.read(app: fake) }
    for output in ["invalid-json", "{}", "{\"format\":2}"] {
      try script("#!/bin/sh\nif [ \"$1\" = --help ]; then echo --uninstall-status; else echo '\(output)'; fi\n")
      try await rejects { _ = try await QingTypeUninstallPreflight.read(app: fake) }
    }
    try script("#!/bin/sh\necho --uninstall-status\nexit 1\n")
    try await rejects { _ = try await QingTypeUninstallPreflight.read(app: fake) }
    try script("#!/bin/sh\nexec sleep 10\n")
    let start = Date()
    try await rejects { _ = try await QingTypeReadOnlyProbe.run(["--help"], app: fake, timeout: 0.15) }
    try expect(Date().timeIntervalSince(start) < 2, "hung probe has a bounded wait")
    try script("#!/bin/sh\nhead -c 70000 /dev/zero\n")
    try await rejects { _ = try await QingTypeReadOnlyProbe.run(["--help"], app: fake) }
    print("PASS: \(checks) guided uninstall state, production flow, rollback, data retention and bounded probe checks")
  }
}
