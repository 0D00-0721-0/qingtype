import Foundation
import Yams

// Runs before Rime initialization. A fallback uses a private copy of compiled
// resources, while Rime's user-data directory remains unchanged.
enum QingTypeRuntimeModel {
  struct Status: Codable {
    let message: String?
    let observedAt: Date
  }
  static let statusFilename = "qingtype-model-runtime-status.json"

  struct Preparation {
    let stagingDirectory: URL?
    let warning: String?
  }

  static func prepare(in directory: URL) throws -> Preparation {
    try QingTypePaths.checkDirectory(directory)
    let fm = FileManager.default
    let build = directory.appendingPathComponent("build", isDirectory: true)
    let hasBuild = fm.fileExists(atPath: build.path)
    if hasBuild {
      let values = try build.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw SettingsError.invalid("输入法编译目录不可安全读取。")
      }
    }

    var expected = ""
    var needsFallback = false
    var selectedSchema: String?
    do {
      let settings = try QingTypeSettings.load(from: directory)
      selectedSchema = settings.schema
      try settings.validate()
      expected = settings.activeModel?.language ?? ""
      try settings.verifyActiveModel(in: directory)
    } catch { needsFallback = true }

    let compiled = hasBuild ? try fm.contentsOfDirectory(at: build, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      .filter { $0.lastPathComponent.hasSuffix(".schema.yaml") } : []
    for file in compiled {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw SettingsError.invalid("输入方案编译文件不是普通文件。")
      }
      do {
        guard let schema = try Yams.load(yaml: String(contentsOf: file, encoding: .utf8)) as? [String: Any] else {
          throw SettingsError.invalid("输入方案编译文件无效。")
        }
        if let raw = schema["grammar"] {
          guard let grammar = raw as? [String: Any] else { needsFallback = true; continue }
          if let language = grammar["language"] {
            guard let name = language as? String else { needsFallback = true; continue }
            if !name.isEmpty && name != expected { needsFallback = true }
          }
        }
      } catch { needsFallback = true }
    }
    // Maintenance may rebuild from a custom patch. Do not start it if the
    // configured grammar differs from the verified active model.
    for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      where file.lastPathComponent.hasSuffix(".custom.yaml") {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw SettingsError.invalid("输入方案配置不是普通文件。")
      }
      do {
        guard let config = try Yams.load(yaml: String(contentsOf: file, encoding: .utf8)) as? [String: Any] else { continue }
        if let patch = config["patch"] as? [String: Any] {
          let nested = (patch["grammar"] as? [String: Any])?["language"]
          if let language = patch["grammar/language"] ?? nested {
            guard let name = language as? String else { needsFallback = true; continue }
            if !name.isEmpty && name != expected { needsFallback = true }
          }
        }
      } catch { needsFallback = true }
    }
    // A changed source schema can be recompiled during maintenance even when
    // the existing compiled schema is safe. Inspect these before starting it.
    for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      where file.lastPathComponent.hasSuffix(".schema.yaml") {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw SettingsError.invalid("输入方案源文件不是普通文件。")
      }
      do {
        guard let schema = try Yams.load(yaml: String(contentsOf: file, encoding: .utf8)) as? [String: Any] else { needsFallback = true; continue }
        if let raw = schema["grammar"] {
          guard let grammar = raw as? [String: Any] else { needsFallback = true; continue }
          if let language = grammar["language"] {
            guard let name = language as? String else { needsFallback = true; continue }
            if !name.isEmpty && name != expected { needsFallback = true }
          }
        }
      } catch { needsFallback = true }
    }
    guard needsFallback else { return Preparation(stagingDirectory: nil, warning: nil) }
    guard hasBuild, let selectedSchema,
          ["luna_pinyin_simp", "luna_pinyin", "qingtype_double_pinyin", "rime_ice"].contains(selectedSchema),
          compiled.contains(where: { $0.lastPathComponent == selectedSchema + ".schema.yaml" }) else {
      throw SettingsError.invalid("模型校验失败，且没有可用于安全降级的已编译输入方案。请在清言设置中重新导入模型并应用。")
    }

    let workspace = fm.temporaryDirectory.appendingPathComponent("qingtype-model-fallback-\(UUID())", isDirectory: true)
    let staging = workspace.appendingPathComponent("build", isDirectory: true)
    try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      try fm.copyItem(at: build, to: staging)
      for file in compiled {
        let target = staging.appendingPathComponent(file.lastPathComponent)
        guard var schema = try Yams.load(yaml: String(contentsOf: target, encoding: .utf8)) as? [String: Any] else {
          throw SettingsError.invalid("无法安全读取已编译输入方案。")
        }
        var grammar = schema["grammar"] as? [String: Any] ?? [:]
        grammar["language"] = ""
        grammar.removeValue(forKey: "collocation_prism")
        schema["grammar"] = grammar
        try Data((try Yams.dump(object: schema)).utf8).write(to: target, options: .atomic)
      }
      return Preparation(stagingDirectory: staging, warning: "语言模型或输入方案配置未通过启动校验，暂以不使用模型的方式输入；请在清言设置中检查模型并重新应用。")
    } catch {
      try? fm.removeItem(at: workspace)
      throw error
    }
  }

  static func recordStatus(_ message: String?, in directory: URL) throws {
    try QingTypePaths.checkDirectory(directory)
    let status = Status(message: message, observedAt: Date())
    try JSONEncoder().encode(status).write(to: directory.appendingPathComponent(statusFilename), options: .atomic)
  }

  static func readStatus(in directory: URL) -> Status? {
    let url = directory.appendingPathComponent(statusFilename)
    guard (try? QingTypePaths.checkDirectory(directory)) != nil,
          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let data = try? Data(contentsOf: url),
          data.count < 8192 else { return nil }
    return try? JSONDecoder().decode(Status.self, from: data)
  }
}
