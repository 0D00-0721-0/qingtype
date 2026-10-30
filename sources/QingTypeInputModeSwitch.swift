import Foundation

enum QingTypeInputModeSwitch {
  static func prepare(api: RimeApi_stdbool, session: RimeSessionId, key: UInt32, modifiers: UInt32) {
    guard key == UInt32(XK_Caps_Lock), modifiers == 0,
          !api.get_option(session, "ascii_mode"),
          let input = api.get_input(session) else { return }
    let end = strlen(input)
    guard api.get_caret_pos(session) < end, capsLockStyle(api: api, session: session) == "commit_code" else { return }
    // Rime's commit_code uses the composition up to the caret. Include the
    // unconfirmed suffix before switching; confirmed segments remain confirmed.
    api.set_caret_pos(session, end)
  }

  private static func capsLockStyle(api: RimeApi_stdbool, session: RimeSessionId) -> String? {
    var status = RimeStatus_stdbool.rimeStructInit()
    guard api.get_status(session, &status) else { return nil }
    let schemaID = status.schema_id.map { String(cString: $0) }
    _ = api.free_status(&status)
    guard let schemaID else { return nil }
    var schema = RimeConfig()
    guard api.schema_open(schemaID, &schema) else { return nil }
    defer { _ = api.config_close(&schema) }
    var bindings = RimeConfigIterator()
    // Match AsciiComposer's lookup: a schema's map replaces the default map,
    // including an empty map or a map without a Caps Lock binding.
    if api.config_begin_map(&bindings, &schema, "ascii_composer/switch_key") {
      api.config_end(&bindings)
      return api.config_get_cstring(&schema, "ascii_composer/switch_key/Caps_Lock").map { String(cString: $0) }
    }
    var defaults = RimeConfig()
    guard api.config_open("default", &defaults) else { return nil }
    defer { _ = api.config_close(&defaults) }
    return api.config_get_cstring(&defaults, "ascii_composer/switch_key/Caps_Lock").map { String(cString: $0) }
  }
}
