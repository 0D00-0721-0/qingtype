import Foundation

final class FakeUninstallSources {
  let hans = "org.qingtype.inputmethod.QingType.Hans"
  let hant = "org.qingtype.inputmethod.QingType.Hant"
  var current: String? = "com.apple.keylayout.ABC"
  var enabled: Set<String> = []
  var hasFallback = true
  var failDisable = false
  var silentDisable = false
  var failRestore = false
  var fallbackCalls = 0

  func read() throws -> QingTypeUninstallSnapshot {
    .init(current: current, modes: [hans, hant].map { .init(id: $0, registered: true, enabled: enabled.contains($0), selected: current == $0) }, parentEnabled: false)
  }
  func fallback() throws {
    fallbackCalls += 1
    guard hasFallback else { throw SettingsError.invalid("no fallback") }
    current = "com.apple.keylayout.ABC"
  }
  func disable() throws {
    if failDisable { enabled.remove(hans); throw SettingsError.invalid("disable failed") }
    if !silentDisable { enabled.removeAll() }
  }
  func restore(_ previous: QingTypeUninstallSnapshot) throws {
    if failRestore { throw SettingsError.invalid("restore failed") }
    enabled = Set(previous.modes.filter(\.enabled).map(\.id)); current = previous.current
  }
  func prepare() throws -> QingTypeUninstallSnapshot {
    try QingTypeUninstallGuard.prepare(read: read, selectFallback: fallback, disable: disable, restore: restore)
  }
}

@main
struct UninstallSafetyTests {
  static func main() async throws {
    func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
      guard value() else { throw SettingsError.invalid(message) }
    }
    func expectFailure(_ action: () throws -> Void, _ message: String) throws -> Error {
      do { try action() } catch { return error }
      throw SettingsError.invalid("Expected failure: \(message)")
    }
    func expectFailureAsync(_ action: () async throws -> Void, _ message: String) async throws -> Error {
      do { try await action() } catch { return error }
      throw SettingsError.invalid("Expected failure: \(message)")
    }
    var assertionRejectedSuccess = false
    do { _ = try expectFailure({}, "successful operation") } catch { assertionRejectedSuccess = true }
    try expect(assertionRejectedSuccess, "failure assertion must reject a successful operation")
    var asyncAssertionRejectedSuccess = false
    do { _ = try await expectFailureAsync({}, "successful operation") } catch { asyncAssertionRejectedSuccess = true }
    try expect(asyncAssertionRejectedSuccess, "async failure assertion must reject a successful operation")
    let inactive = FakeUninstallSources(); inactive.enabled = [inactive.hans]
    _ = try inactive.prepare()
    try expect(inactive.enabled.isEmpty && inactive.fallbackCalls == 0, "non-current source should be disabled without switching")
    let active = FakeUninstallSources(); active.enabled = [active.hans]; active.current = active.hans
    _ = try active.prepare()
    try expect(active.current == "com.apple.keylayout.ABC" && active.enabled.isEmpty && active.fallbackCalls == 1, "current source must switch before disable")
    let parentDisabled = QingTypeUninstallSnapshot(current: "com.apple.keylayout.ABC", modes: [
      .init(id: active.hans, registered: true, enabled: true, selected: false)
    ], parentEnabled: false)
    _ = try expectFailure({ try QingTypeUninstallGuard.verify(parentDisabled) }, "enabled mode despite disabled parent")
    try QingTypeUninstallGuard.verify(.init(current: "com.apple.keylayout.ABC", modes: [
      .init(id: active.hans, registered: true, enabled: false, selected: false)
    ], parentEnabled: false))
    _ = try expectFailure({ try QingTypeUninstallGuard.verify(.init(current: "com.apple.keylayout.ABC", modes: [
      .init(id: active.hans, registered: true, enabled: false, selected: false)
    ])) }, "unknown parent with registered mode")
    try QingTypeUninstallGuard.verify(.init(current: "com.apple.keylayout.ABC", modes: [
      .init(id: active.hans, registered: false, enabled: false, selected: false)
    ]))
    let parentEnabled = QingTypeUninstallSnapshot(current: "com.apple.keylayout.ABC", modes: [
      .init(id: active.hans, registered: true, enabled: false, selected: false)
    ], parentEnabled: true)
    _ = try expectFailure({ try QingTypeUninstallGuard.verify(parentEnabled) }, "enabled parent source")
    let inconsistentSelection = QingTypeUninstallSnapshot(current: "com.apple.keylayout.ABC", modes: [
      .init(id: active.hans, registered: true, enabled: true, selected: true)
    ], parentEnabled: false)
    _ = try expectFailure({ try QingTypeUninstallGuard.verify(inconsistentSelection) }, "selected mode despite disabled parent")
    let noFallback = FakeUninstallSources(); noFallback.enabled = [noFallback.hans]; noFallback.current = noFallback.hans; noFallback.hasFallback = false
    _ = try expectFailure({ _ = try noFallback.prepare() }, "no fallback")
    try expect(noFallback.fallbackCalls == 1 && noFallback.current == noFallback.hans && noFallback.enabled == [noFallback.hans], "no fallback keeps source")
    for silent in [false, true] {
      let failed = FakeUninstallSources(); failed.enabled = [failed.hans, failed.hant]; failed.current = failed.hans
      failed.failDisable = !silent; failed.silentDisable = silent
      _ = try expectFailure({ _ = try failed.prepare() }, "disable failure")
      try expect(failed.current == failed.hans && failed.enabled == [failed.hans, failed.hant], "disable failure restores prior source")
    }
    let unknown = FakeUninstallSources(); unknown.current = nil; unknown.enabled = [unknown.hans]
    _ = try expectFailure({ _ = try unknown.prepare() }, "missing current source")
    try expect(unknown.enabled == [unknown.hans], "unknown current source must stop before mutation")
    let unrecovered = FakeUninstallSources(); unrecovered.current = unrecovered.hans; unrecovered.enabled = [unrecovered.hans]; unrecovered.failDisable = true; unrecovered.failRestore = true
    let recoveryError = try expectFailure({ _ = try unrecovered.prepare() }, "recovery failure")
    try expect(recoveryError.localizedDescription.contains("恢复未确认"), "failed restoration must be reported")
    var reads = 0
    let selectionError = try expectFailure({
      _ = try QingTypeUninstallGuard.prepare(read: {
        reads += 1
        return .init(current: "com.apple.keylayout.ABC", modes: [.init(id: inactive.hans, registered: true, enabled: true, selected: reads > 1)])
      }, selectFallback: {}, disable: { throw SettingsError.invalid("disable failed") }, restore: { _ in })
    }, "selection recovery")
    try expect(selectionError.localizedDescription.contains("恢复未确认"), "selection mismatch must not be reported as recovered")
    let snapshot = QingTypeInputSourceState(inputSources: [.init(id: inactive.hans, registered: true, enabled: true, selected: false)])
    var preparationRemoved = false
    _ = try await expectFailureAsync({
      try await QingTypeUninstallTransaction.run(prepare: { throw SettingsError.invalid("disable failed") }, verify: {}, stop: {}, remove: { preparationRemoved = true }, restore: { _ in })
    }, "preparation")
    try expect(!preparationRemoved, "failed deactivation must never move the application")
    for failedStep in ["verify-before", "stop", "verify-after", "remove"] {
      var verifyCount = 0, moved = false, restored = false
      _ = try await expectFailureAsync({
        try await QingTypeUninstallTransaction.run(prepare: { snapshot }, verify: {
          verifyCount += 1
          if failedStep == (verifyCount == 1 ? "verify-before" : "verify-after") { throw SettingsError.invalid("injected verification failure") }
        }, stop: {
          if failedStep == "stop" { throw SettingsError.invalid("injected stop failure") }
        }, remove: {
          if failedStep == "remove" { throw SettingsError.invalid("injected move failure") }
          moved = true
        }, restore: { _ in restored = true })
      }, "transaction at \(failedStep)")
      try expect(!moved && restored, "failure at \(failedStep) must keep the app and restore input source")
    }
    var didRemove = false
    try await QingTypeUninstallTransaction.run(prepare: { snapshot }, verify: {}, stop: {}, remove: { didRemove = true }, restore: { _ in throw SettingsError.invalid("unexpected restore") })
    try expect(didRemove, "successful deactivation may move the program")
    let fakeApp = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-uninstall-control-\(UUID())")
    defer { try? FileManager.default.removeItem(at: fakeApp) }
    let binary = fakeApp.appendingPathComponent("Contents/MacOS/QingType")
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\necho old-help\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    var oldRejected = false
    do { try await QingTypeUninstallTransaction.checkControl(fakeApp) } catch { oldRejected = true }
    try expect(oldRejected, "old control binary must not be invoked with an unsupported command")
    try Data("#!/bin/sh\necho --verify-uninstall\n".utf8).write(to: binary)
    try await QingTypeUninstallTransaction.checkControl(fakeApp)
    for state in [(true, false, false), (false, true, false), (false, false, true)] {
      var rejected = false
      do { try QingTypeUninstallGuard.requireDataRemovalSafe(installed: state.0, running: state.1, otherSettings: state.2) }
      catch { rejected = true }
      try expect(rejected, "data removal must reject an active input method or settings process")
    }
    try QingTypeUninstallGuard.requireDataRemovalSafe(installed: false, running: false, otherSettings: false)
    var invalidRejected = false
    do { try QingTypeUninstallGuard.validateModeIDs([inactive.hans, "not-a-mode"], valid: [inactive.hans, inactive.hant]) }
    catch { invalidRejected = true }
    try expect(invalidRejected, "invalid source IDs must not fall through to disabling all modes")
    try QingTypeUninstallGuard.validateModeIDs([inactive.hans], valid: [inactive.hans, inactive.hant])
    print("PASS: current and non-current source, missing fallback, explicit and silent disable failure, unknown current and failed recovery")
    print("PASS: uninstall verifies before and after stop, aborts and restores on failures, moves only on success")
  }
}
