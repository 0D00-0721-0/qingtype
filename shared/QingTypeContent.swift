import Foundation
import CryptoKit
import Yams

struct DictionaryAsset: Codable, Equatable, Identifiable {
  var id: String
  var name: String
  var tables: [String]
  var wordCount: Int
  var enabled = true
  var importedAt = Date()
}

struct GrammarAsset: Codable, Equatable, Identifiable {
  var id: String
  var name: String
  var language: String
  var byteCount: Int64
  var sha256: String
  var variant: String?
  var importedAt = Date()
}

enum QingTypeContent {
  static func digest(of url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func importGrammar(from source: URL, into directory: URL) throws -> GrammarAsset {
    guard source.pathExtension.lowercased() == "gram" else {
      throw SettingsError.invalid("请选择 Rime 的 .gram 语言模型文件。")
    }
    let file = try FileHandle(forReadingFrom: source)
    let header = try file.read(upToCount: 44) ?? Data()
    try file.close()
    guard header.starts(with: Data("Rime::Grammar/1.0".utf8)) else {
      throw SettingsError.invalid("这个文件不是支持的 Rime 语法模型。")
    }
    let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 1024 else { throw SettingsError.invalid("模型文件过小，可能尚未下载完整。") }
    guard header.count == 44 else { throw SettingsError.invalid("模型头部不完整。") }
    let (units, offset) = header.withUnsafeBytes {
      (UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 36, as: UInt32.self)),
       Int32(littleEndian: $0.loadUnaligned(fromByteOffset: 40, as: Int32.self)))
    }
    let start = Int64(40) + Int64(offset)
    guard units > 0, start >= 44, start + Int64(units) * 4 <= Int64(size) else {
      throw SettingsError.invalid("模型索引超出文件范围，文件可能已损坏或下载不完整。")
    }
    let hash = try digest(of: source)
    let language = "qingtype_model_" + hash
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(language + ".gram")
    if !FileManager.default.fileExists(atPath: destination.path) {
      let staging = directory.appendingPathComponent(".import-\(UUID()).gram")
      defer { try? FileManager.default.removeItem(at: staging) }
      try FileManager.default.copyItem(at: source, to: staging)
      guard try digest(of: staging) == hash else { throw SettingsError.invalid("模型复制校验失败，请重新导入。") }
      try FileManager.default.moveItem(at: staging, to: destination)
    }
    let name = source.deletingPathExtension().lastPathComponent
    return GrammarAsset(id: hash, name: name, language: language, byteCount: Int64(size), sha256: hash,
                        variant: name.contains("zh-hans") ? "hans" : name.contains("zh-hant") ? "hant" : nil)
  }

  // Read dictionary data only. Dependencies stay inside the selected file's folder.
  // A flat list is returned because Rime does not recursively expand import_tables.
  static func importDictionary(from source: URL, into directory: URL) throws -> DictionaryAsset {
    guard source.lastPathComponent.hasSuffix(".dict.yaml") else {
      throw SettingsError.invalid("请选择 Rime 的 .dict.yaml 词库文件。")
    }
    let manager = FileManager.default
    let root = source.deletingLastPathComponent().resolvingSymlinksInPath()
    let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var visiting = Set<String>()
    var tableNames: [String: String] = [:]
    var output: [String: Data] = [:]
    var count = 0
    var displayName = source.lastPathComponent.replacingOccurrences(of: ".dict.yaml", with: "")

    func read(_ url: URL, isRoot: Bool = false) throws {
      let url = url.resolvingSymlinksInPath().standardizedFileURL
      guard url.pathComponents.starts(with: root.pathComponents), url.pathComponents.count > root.pathComponents.count else {
        throw SettingsError.invalid("词库依赖超出了所选词库所在的文件夹。")
      }
      guard !visiting.contains(url.path) else { throw SettingsError.invalid("词库包含循环依赖：\(url.lastPathComponent)") }
      if tableNames[url.path] != nil { return }
      visiting.insert(url.path)
      defer { visiting.remove(url.path) }
      guard manager.fileExists(atPath: url.path) else {
        throw SettingsError.invalid("缺少词库依赖：\(url.lastPathComponent)。请将依赖放在词库文件夹内。")
      }
      let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
      let lines = text.components(separatedBy: "\n")
      guard let separator = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "..." }),
            var header = try Yams.load(yaml: lines[..<separator].joined(separator: "\n")) as? [String: Any],
            let name = header["name"] as? String, !name.isEmpty else {
        throw SettingsError.invalid("\(url.lastPathComponent) 缺少有效的 Rime 词库头部或结束标记。")
      }
      guard !header.keys.contains(where: { $0.hasPrefix("__") }) else {
        throw SettingsError.invalid("暂不支持在词库头部引用其他配置；请导入独立词库或 import_tables 词库包。")
      }
      if isRoot { displayName = name }
      let ownedName = "qingtype_dict_\(id)_\(tableNames.count)"
      // Reserve a name before visiting dependencies; cycles are checked above.
      tableNames[url.path] = ownedName
      let imports = header["import_tables"] as? [String] ?? []
      if header["import_tables"] != nil && !(header["import_tables"] is [String]) {
        throw SettingsError.invalid("\(url.lastPathComponent) 的 import_tables 格式不正确。")
      }
      var ownedImports: [String] = []
      for entry in imports {
        guard !entry.hasPrefix("/"), !entry.contains("\\"),
              !entry.split(separator: "/").contains(".."),
              entry.range(of: "^[A-Za-z0-9_./-]+$", options: .regularExpression) != nil else {
          throw SettingsError.invalid("词库依赖路径不受支持：\(entry)")
        }
        let dependency = root.appendingPathComponent(entry + ".dict.yaml").resolvingSymlinksInPath().standardizedFileURL
        try read(dependency)
        ownedImports.append(tableNames[dependency.path]!)
      }
      header["name"] = ownedName
      if !imports.isEmpty { header["import_tables"] = ownedImports }
      let body = lines[(separator + 1)...].joined(separator: "\n")
      count += body.components(separatedBy: "\n").filter {
        let line = $0.trimmingCharacters(in: .whitespaces)
        return !line.isEmpty && !line.hasPrefix("#")
      }.count
      let normalized = "# Imported by QingType.\n---\n" + (try Yams.dump(object: header)) + "...\n" + body
      output[ownedName + ".dict.yaml"] = Data(normalized.utf8)
    }
    try read(source, isRoot: true)
    guard count > 0 else { throw SettingsError.invalid("词库中没有可导入的词条。") }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let staging = directory.appendingPathComponent(".dictionary-import-\(id)")
    try manager.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: staging) }
    for (name, data) in output { try data.write(to: staging.appendingPathComponent(name), options: .atomic) }
    var moved: [URL] = []
    do {
      for name in output.keys.sorted() {
        let target = directory.appendingPathComponent(name)
        try manager.moveItem(at: staging.appendingPathComponent(name), to: target)
        moved.append(target)
      }
    } catch {
      for url in moved { try? manager.removeItem(at: url) }
      throw error
    }
    return DictionaryAsset(id: id, name: displayName, tables: tableNames.values.sorted(), wordCount: count)
  }
}
