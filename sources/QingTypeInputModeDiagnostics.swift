import AppKit
import Carbon

enum QingTypeInputModeDiagnostics {
  // Exercise the real engine with the Caps Lock translation used by the controller.
  // Callers provide an isolated profile; no events are sent to another application.
  static func checkCapsLock(api: RimeApi_stdbool, session: RimeSessionId, profile: String) throws -> Int {
    var checks = 0
    func expect(_ value: Bool, _ message: String) throws {
      guard value else { throw SettingsError.invalid("FAIL: \(profile): \(message)") }
      checks += 1
      print("PASS: \(profile): \(message)")
    }
    func committedText() -> String? {
      var commit = RimeCommit.rimeStructInit()
      guard api.get_commit(session, &commit) else { return nil }
      defer { _ = api.free_commit(&commit) }
      return commit.text.map { String(cString: $0) }
    }
    let capsKey = SquirrelKeycode.osxKeycodeToRime(keycode: UInt16(kVK_CapsLock), keychar: nil, shift: false, caps: false)
    func pressCapsLock(enabled: Bool) {
      let flags: NSEvent.ModifierFlags = enabled ? [.capsLock] : []
      // NSFlagsChanged already carries the new lock state; Rime expects the old one.
      let modifiers = SquirrelKeycode.osxModifiersToRime(modifiers: flags) ^ kLockMask.rawValue
      QingTypeInputModeSwitch.prepare(api: api, session: session, key: capsKey, modifiers: modifiers)
      _ = api.process_key(session, Int32(capsKey), Int32(modifiers))
    }
    func type(_ keys: [Int32]) {
      for key in keys { _ = api.process_key(session, key, 0) }
    }
    let nihao = "nihao".utf8.map { Int32($0) }
    api.set_option(session, "ascii_mode", false)
    type(nihao)
    api.set_caret_pos(session, 2)
    QingTypeInputModeSwitch.prepare(api: api, session: session, key: UInt32(XK_Shift_L), modifiers: 0)
    QingTypeInputModeSwitch.prepare(api: api, session: session, key: capsKey, modifiers: kReleaseMask.rawValue)
    QingTypeInputModeSwitch.prepare(api: api, session: session, key: capsKey, modifiers: kLockMask.rawValue)
    try expect(api.get_caret_pos(session) == 2, "unrelated, release and return-to-Chinese events keep the caret")
    var status = RimeStatus_stdbool.rimeStructInit()
    guard api.get_status(session, &status) else { throw SettingsError.invalid("Missing test schema status") }
    let schemaID = status.schema_id.map { String(cString: $0) }
    _ = api.free_status(&status)
    var schema = RimeConfig()
    guard let schemaID, api.schema_open(schemaID, &schema) else { throw SettingsError.invalid("Missing test schema") }
    do {
      defer { _ = api.config_close(&schema) }
      var previous = RimeConfig()
      guard api.config_get_item(&schema, "ascii_composer", &previous) else { throw SettingsError.invalid("Cannot save test binding") }
      defer { _ = api.config_set_item(&schema, "ascii_composer", &previous); _ = api.config_close(&previous) }
      guard api.config_set_string(&schema, "ascii_composer/switch_key/Caps_Lock", "commit_text") else {
        throw SettingsError.invalid("Cannot set test binding")
      }
      QingTypeInputModeSwitch.prepare(api: api, session: session, key: capsKey, modifiers: 0)
      try expect(api.get_caret_pos(session) == 2, "an explicit schema switch policy is not replaced by the default policy")
    }
    let cases: [(keys: [Int32], raw: String, name: String)] = [
      (nihao, "nihao", "plain pinyin"),
      ("nihaox".utf8.map { Int32($0) } + [XK_BackSpace], "nihao", "edited pinyin"),
      (nihao + [XK_Left], "nihao", "pinyin with a moved caret"),
      ("xi'an".utf8.map { Int32($0) }, "xi'an", "explicit syllable separator")
    ]
    for item in cases {
      api.clear_composition(session)
      api.set_option(session, "ascii_mode", false)
      type(item.keys)
      try expect(api.get_input(session).map { String(cString: $0) } == item.raw, "\(item.name) reaches the engine intact")
      pressCapsLock(enabled: true)
      try expect(committedText() == item.raw, "Caps Lock commits \(item.name) as the exact original letters")
      try expect(api.get_option(session, "ascii_mode") &&
                 (api.get_input(session).map { String(cString: $0) } ?? "").isEmpty,
                 "Caps Lock enters English mode with no leftover composition")
      _ = api.process_key(session, Int32(capsKey), Int32(kReleaseMask.rawValue | kLockMask.rawValue))
      pressCapsLock(enabled: false)
      try expect(committedText() == nil && !api.get_option(session, "ascii_mode"),
                 "release and switching back neither duplicate text nor leave English mode active")
    }
    pressCapsLock(enabled: true)
    try expect(committedText() == nil && api.get_option(session, "ascii_mode"),
               "switching with an empty composition does not insert text")
    pressCapsLock(enabled: false)
    type(nihao + [XK_Escape])
    pressCapsLock(enabled: true)
    try expect(committedText() == nil, "switching after Escape does not resurrect cancelled pinyin")
    pressCapsLock(enabled: false)
    type(nihao)
    try expect(QingTypeCandidateSource.read(api: api, session: session, startingAt: 0, limit: 64).contains { $0.text == "你好" },
               "switching back preserves normal Chinese candidates")
    api.clear_composition(session)
    return checks
  }
}
