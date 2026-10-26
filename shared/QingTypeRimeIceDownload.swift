import Foundation

struct RimeIceDownload {
  var directory: URL
  var root: URL
  var provenance: String
  var sha256: String
}

enum QingTypeRimeIceDownload {
  private struct Release: Decodable {
    var tag_name: String
    var assets: [Asset]
    struct Asset: Decodable {
      var name: String
      var browser_download_url: URL
      var size: Int
      var digest: String?
    }
  }

  static func official() async throws -> RimeIceDownload {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 300
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/iDvel/rime-ice/releases/latest")!)
    request.setValue("QingType", forHTTPHeaderField: "User-Agent")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let (metadata, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, metadata.count < 2 * 1024 * 1024 else {
      throw SettingsError.invalid("无法读取雾凇官方发行信息。可稍后重试，或从完整方案文件夹导入。")
    }
    let release = try JSONDecoder().decode(Release.self, from: metadata)
    guard let asset = release.assets.first(where: { $0.name == "full.zip" }),
          asset.size > 0, asset.size <= 128 * 1024 * 1024,
          asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
          asset.browser_download_url.path.hasPrefix("/iDvel/rime-ice/releases/download/"),
          let digest = asset.digest, digest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else {
      throw SettingsError.invalid("官方完整包缺少可校验的 SHA-256，或发行格式已变化，请更新清言。")
    }
    let (temporary, downloadResponse) = try await session.download(from: asset.browser_download_url)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200,
          try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize == asset.size,
          try QingTypeContent.digest(of: temporary) == String(digest.dropFirst(7)) else {
      throw SettingsError.invalid("下载的雾凇方案与官方大小或 SHA-256 不符，已停止安装。")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-ice-download-\(UUID())")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let zip = directory.appendingPathComponent("full.zip")
      try FileManager.default.moveItem(at: temporary, to: zip)
      let root = try extract(zip, to: directory.appendingPathComponent("package"))
      return RimeIceDownload(directory: directory, root: root,
        provenance: "iDvel/rime-ice · \(release.tag_name)", sha256: String(digest.dropFirst(7)))
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  // Preflight both central and local headers before invoking the system extractor.
  // No encrypted, linked, duplicate, traversing, ZIP64, or unbounded entries.
  static func validateZIP(_ data: Data) throws {
    func fail() -> SettingsError { .invalid("雾凇 ZIP 包损坏、路径不安全或超出资源限制。") }
    func u16(_ offset: Int) throws -> Int {
      guard offset >= 0, offset + 2 <= data.count else { throw fail() }
      return Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }
    func u32(_ offset: Int) throws -> Int {
      try u16(offset) | (u16(offset + 2) << 16)
    }
    guard data.count >= 22, data.count <= 128 * 1024 * 1024 else { throw fail() }
    var end: Int?
    for index in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
      if try u32(index) == 0x06054b50, try index + 22 + u16(index + 20) == data.count { end = index; break }
    }
    guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw fail() }
    let count = try u16(end + 10)
    let start = try u32(end + 16)
    guard count > 0, count < 10000, try u16(end + 8) == count,
          start >= 0, try start + u32(end + 12) == end else { throw fail() }
    var offset = start, names = Set<String>(), total = 0
    for _ in 0..<count {
      guard try u32(offset) == 0x02014b50 else { throw fail() }
      let flags = try u16(offset + 8), method = try u16(offset + 10)
      let compressed = try u32(offset + 20), size = try u32(offset + 24)
      let nameLength = try u16(offset + 28), extra = try u16(offset + 30), comment = try u16(offset + 32)
      let next = offset + 46 + nameLength + extra + comment
      guard nameLength > 0, next <= end, flags & 1 == 0, [0, 8].contains(method),
            compressed < 0xffffffff, size <= 128 * 1024 * 1024,
            try u16(offset + 34) == 0 else { throw fail() }
      let bytes = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
      guard let name = String(data: bytes, encoding: .utf8),
            !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            !name.split(separator: "/", omittingEmptySubsequences: false).dropLast(name.hasSuffix("/") ? 1 : 0).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
            names.insert(name.lowercased()).inserted else { throw fail() }
      let mode = (try u32(offset + 38) >> 16) & 0xf000
      guard [0, 0x4000, 0x8000].contains(mode) else { throw fail() }
      let local = try u32(offset + 42)
      guard local < start, try u32(local) == 0x04034b50,
            try u16(local + 6) == flags, try u16(local + 8) == method,
            try u16(local + 26) == nameLength else { throw fail() }
      let dataStart = try local + 30 + nameLength + u16(local + 28)
      guard dataStart <= start, dataStart + compressed <= start,
            data.subdata(in: (local + 30)..<(local + 30 + nameLength)) == bytes else { throw fail() }
      total += size
      guard total <= 512 * 1024 * 1024 else { throw fail() }
      offset = next
    }
    guard offset == end else { throw fail() }
  }

  static func extract(_ archive: URL, to destination: URL) throws -> URL {
    try validateZIP(Data(contentsOf: archive, options: .mappedIfSafe))
    guard !FileManager.default.fileExists(atPath: destination.path) else { throw SettingsError.invalid("解压目标必须是新目录。") }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    task.arguments = ["-x", "-k", archive.path, destination.path]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try task.run(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { throw SettingsError.invalid("雾凇方案解压失败。") }
    if FileManager.default.fileExists(atPath: destination.appendingPathComponent("rime_ice.schema.yaml").path) { return destination }
    let children = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
    guard children.count == 1, FileManager.default.fileExists(atPath: children[0].appendingPathComponent("rime_ice.schema.yaml").path) else {
      throw SettingsError.invalid("完整包中没有雾凇方案入口。")
    }
    return children[0]
  }
}
