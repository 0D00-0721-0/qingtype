import Foundation

enum QingTypeKeyboardInput {
  static func prepare(api: RimeApi_stdbool, session: RimeSessionId, key: UInt32, modifiers: UInt32) -> UInt32 {
    let passThrough = kReleaseMask.rawValue | kControlMask.rawValue | kAltMask.rawValue | kSuperMask.rawValue
    guard modifiers & passThrough == 0,
          key == UInt32(XK_Return) || key == UInt32(XK_KP_Enter),
          let input = api.get_input(session), input.pointee != 0 else { return key }
    // Rime's raw/script Return commits only up to the caret, then clears the
    // entire composition. Include the suffix before committing. The expanded
    // candidate presenter handles its own Return before reaching this path.
    api.set_caret_pos(session, strlen(input))
    // An empty keypad Enter still reaches the app unchanged. With a pending
    // composition it must finish input, just like the main Return key.
    return UInt32(XK_Return)
  }
}
