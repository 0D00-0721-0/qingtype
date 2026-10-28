import Foundation

/// What the installer currently sees on disk. Detection only reads the
/// filesystem; it never changes the installed program or the user's data.
enum QingTypeInstallationState: String, Equatable {
  case notInstalled
  case installedSameVersion
  case installedOlderVersion
  case installedNewerVersion
  case corrupted
}

struct QingTypeInstallationStatus: Equatable {
  var state: QingTypeInstallationState
  var installedVersion: String?
  var payloadVersion: String?
  /// Human-readable problems found while inspecting the installed program.
  var problems: [String] = []
  /// Leftover `.qingtype-stage-*` directories from an interrupted transaction.
  var leftoverStaging: [String] = []
}

/// The operation the install button should perform for a given status.
enum QingTypeInstallAction: Equatable {
  case install
  case deployOnly
  case update
  case repair
  case blockedNewer
  case reinstall
}

enum QingTypeInstallationCheck {
  /// Files a usable input method must contain. Configuration, learning data and
  /// models live outside the bundle and are deliberately not listed here.
  static let requiredFiles = [
    "Contents/MacOS/QingType",
    "Contents/Frameworks/librime.1.dylib",
    "Contents/SharedSupport/luna_pinyin.dict.yaml",
  ]

  static func inspect(destination: URL, payload: URL?,
                      signature: ((URL) throws -> Void)? = nil) -> QingTypeInstallationStatus {
    let manager = FileManager.default
    let payloadVersion = payload.flatMap { try? QingTypeAppInstallation.version(at: $0) }
    var problems: [String] = []
    if payload != nil, payloadVersion == nil {
      problems.append("清言应用内嵌的输入法程序不完整。")
    }
    var leftover: [String] = []
    if let entries = try? manager.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) {
      leftover = entries.filter { $0.hasPrefix(".qingtype-stage-") }.sorted()
    }
    guard manager.fileExists(atPath: destination.path) else {
      return .init(state: .notInstalled, installedVersion: nil, payloadVersion: payloadVersion,
                   problems: problems, leftoverStaging: leftover)
    }
    var installedVersion: String?
    do {
      installedVersion = try QingTypeAppInstallation.version(at: destination)
    } catch {
      problems.append(error.localizedDescription)
    }
    for relative in requiredFiles where !manager.fileExists(atPath: destination.appendingPathComponent(relative).path) {
      problems.append("缺少 \(relative)。")
    }
    if installedVersion != nil, let signature {
      do { try signature(destination) } catch { problems.append(error.localizedDescription) }
    }
    if installedVersion == nil || !problems.isEmpty {
      return .init(state: .corrupted, installedVersion: installedVersion, payloadVersion: payloadVersion,
                   problems: problems, leftoverStaging: leftover)
    }
    guard let installed = installedVersion, let expected = payloadVersion else {
      // No embedded payload (for example the settings app running from the
      // input-method copy): the best we can do is redeploy the existing one.
      return .init(state: .installedSameVersion, installedVersion: installedVersion, payloadVersion: payloadVersion,
                   problems: problems, leftoverStaging: leftover)
    }
    let order = expected.compare(installed, options: .numeric)
    let state: QingTypeInstallationState = order == .orderedSame ? .installedSameVersion
      : order == .orderedDescending ? .installedOlderVersion
      : .installedNewerVersion
    return .init(state: state, installedVersion: installed, payloadVersion: expected,
                 problems: problems, leftoverStaging: leftover)
  }

  static func action(for status: QingTypeInstallationStatus) -> QingTypeInstallAction {
    switch status.state {
    case .notInstalled: return .install
    case .installedSameVersion: return .deployOnly
    case .installedOlderVersion: return .update
    case .installedNewerVersion: return .blockedNewer
    case .corrupted: return .repair
    }
  }

  /// Re-checks the program after a transaction. Only a matching version with all
  /// required files present counts as a successful install.
  static func verify(destination: URL, expectedVersion: String?,
                     signature: ((URL) throws -> Void)? = nil) throws {
    let installed = try QingTypeAppInstallation.version(at: destination)
    if let expectedVersion, installed != expectedVersion {
      throw SettingsError.invalid("安装后的版本是 \(installed)，与安装包 \(expectedVersion) 不一致，安装已回退。")
    }
    for relative in requiredFiles where !FileManager.default.fileExists(atPath: destination.appendingPathComponent(relative).path) {
      throw SettingsError.invalid("安装后的输入法缺少 \(relative)，安装已回退。")
    }
    if let signature { try signature(destination) }
  }

  /// Full signature check for the installed program. Slower than the file
  /// checks, so callers run it off the main thread during status refresh.
  static func verifySignature(at app: URL) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    task.arguments = ["--verify", "--deep", "--strict", app.path]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
      throw SettingsError.invalid("输入法代码签名校验失败，建议使用「修复安装」。")
    }
  }
}
