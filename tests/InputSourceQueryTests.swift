import Foundation
import InputMethodKit

// InputSource.swift only needs this URL when register() is explicitly invoked.
// Tests never register, enable, disable or select a real system input source.
enum SquirrelApp {
  static let appDir = URL(fileURLWithPath: "/synthetic/QingType.app")
}

@main
struct InputSourceQueryTests {
  static func main() throws {
    var checks = 0
    func expect(_ value: Bool, _ label: String) throws {
      guard value else { throw SettingsError.invalid("FAIL: \(label)") }
      checks += 1
    }
    func rejects(_ label: String, _ action: () throws -> Void) throws {
      do { try action() } catch { checks += 1; return }
      throw SettingsError.invalid("FAIL: expected input-source query error: \(label)")
    }
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
      throw SettingsError.invalid("Cannot obtain a read-only TIS fixture")
    }
    let array: [AnyObject] = [source]
    try expect(try QingTypeInputSourceQuery.decode(array).count == 1, "Swift source array is accepted")
    try expect(try QingTypeInputSourceQuery.decode(array as CFArray).count == 1, "CF source array bridges safely")
    try expect(try QingTypeInputSourceQuery.decode([] as [AnyObject]).isEmpty, "valid empty array is distinct from API failure")
    let invalidResults: [Any?] = [nil, "not an array", NSNumber(value: 1),
      ["not a source"], [NSNull()], [source, "mixed element" as NSString] as [AnyObject]]
    for (index, value) in invalidResults.enumerated() {
      try rejects("nil/wrong bridge \(index)") { _ = try QingTypeInputSourceQuery.decode(value) }
    }

    let idKey = kTISPropertyInputSourceID as String
    let enabledKey = kTISPropertyInputSourceIsEnabled as String
    let selectedKey = kTISPropertyInputSourceIsSelected as String
    let capableKey = kTISPropertyInputSourceIsSelectCapable as String
    let values: [String: AnyObject] = [
      idKey: SquirrelInstaller.InputMode.hans.rawValue as NSString,
      enabledKey: NSNumber(value: true), selectedKey: NSNumber(value: true), capableKey: NSNumber(value: true)
    ]
    func fixture(_ result: Any?, properties: [String: AnyObject]? = nil) -> SquirrelInstaller {
      let properties = properties ?? values
      return SquirrelInstaller(sourceQuery: { result }, propertyQuery: { _, key in
        properties[key as String].map { Unmanaged.passUnretained($0).toOpaque() }
      })
    }
    let valid = fixture(array as CFArray)
    let status = try valid.status()
    try expect(status[0]["registered"] as? Bool == true && status[0]["selected"] as? Bool == true,
               "valid QingType status is preserved")
    try expect(try valid.enabledModes() == [.hans], "enabled modes use checked properties")
    try valid.enable() // Already enabled: no TIS mutation.
    try valid.select(mode: .hans) // Already selected: no TIS mutation.

    let missing = fixture([] as [AnyObject])
    try expect(try missing.enabledModes().isEmpty, "no QingType source is a valid empty result")
    try expect(try missing.status().allSatisfy { $0["registered"] as? Bool == false },
               "confirmed source absence is reported as unregistered")
    var unrelated = values; unrelated[idKey] = "com.example.unrelated" as NSString
    try expect(try fixture(array, properties: unrelated).status().allSatisfy { $0["registered"] as? Bool == false },
               "unrelated sources do not imply QingType registration")

    for (index, result) in invalidResults.enumerated() {
      let installer = fixture(result)
      try rejects("status \(index)") { _ = try installer.status() }
      try rejects("enabledModes \(index)") { _ = try installer.enabledModes() }
      try rejects("enable \(index)") { try installer.enable() }
      try rejects("select \(index)") { try installer.select(mode: .hans) }
      try rejects("disable \(index)") { try installer.disable() }
      try rejects("legacy snapshot \(index)") { _ = try installer.uninstallSnapshot() }
    }
    var propertyReads = 0
    let malformed = SquirrelInstaller(sourceQuery: { [source, "wrong CF type" as NSString] as [AnyObject] },
      propertyQuery: { _, _ in propertyReads += 1; return nil })
    try rejects("mixed CF elements") { _ = try malformed.status() }
    try expect(propertyReads == 0, "invalid elements never reach TIS property access")

    for key in [idKey, enabledKey, selectedKey, capableKey] {
      var missingProperty = values; missingProperty.removeValue(forKey: key)
      try rejects("missing property \(key)") { _ = try fixture(array, properties: missingProperty).status() }
      var wrongProperty = values
      wrongProperty[key] = key == idKey ? NSNumber(value: true) : "wrong CF type" as NSString
      try rejects("wrong property type \(key)") { _ = try fixture(array, properties: wrongProperty).status() }
    }
    var unknownEnabled = values; unknownEnabled.removeValue(forKey: enabledKey)
    try rejects("enabledModes missing flag") { _ = try fixture(array, properties: unknownEnabled).enabledModes() }
    try rejects("enable missing flag") { try fixture(array, properties: unknownEnabled).enable() }
    for key in [selectedKey, capableKey] {
      var unknown = values; unknown.removeValue(forKey: key)
      try rejects("select missing flag \(key)") { try fixture(array, properties: unknown).select(mode: .hans) }
    }
    var numericFlag = values; numericFlag[enabledKey] = NSNumber(value: 1)
    try rejects("CFNumber is not CFBoolean") { _ = try fixture(array, properties: numericFlag).enabledModes() }
    var disabled = values; disabled[enabledKey] = NSNumber(value: false)
    try expect(try fixture(array, properties: disabled).enabledModes().isEmpty,
               "known false enabled flag remains a valid disabled state")

    let actual = try SquirrelInstaller().status()
    try expect(Set(actual.compactMap { $0["id"] as? String }) == Set(SquirrelInstaller.InputMode.allCases.map(\.rawValue)),
               "real read-only system query retains the status schema")
    print("PASS: \(checks) safe TIS query, bridge, property and error-propagation checks; no source mutations")
  }
}
