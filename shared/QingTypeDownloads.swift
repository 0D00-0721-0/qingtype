import Foundation

struct QingTypeTransferProgress {
  var received: Int64
  var total: Int64
  var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
}

struct QingTypeRelease: Decodable {
  var tag_name: String
  var assets: [Asset]
  struct Asset: Decodable {
    var name: String
    var browser_download_url: URL
    var size: Int64
    var digest: String?
    func validate(repository: String, limit: Int64) throws -> String {
      guard size > 0, size <= limit, browser_download_url.scheme == "https",
            browser_download_url.host == "github.com",
            browser_download_url.path.hasPrefix("/\(repository)/releases/download/"),
            let digest, digest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else {
        throw SettingsError.invalid("官方资源缺少有效的大小或 SHA-256 校验信息，请稍后重试或更新清言。")
      }
      return String(digest.dropFirst(7))
    }
  }
}

struct QingTypeDownloadedAsset {
  var directory: URL
  var file: URL
  var sha256: String
  var release: String
  var repository: String
}

enum QingTypeDownloads {
  private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let limit: Int64
    let progress: @Sendable (QingTypeTransferProgress) -> Void
    init(limit: Int64, progress: @escaping @Sendable (QingTypeTransferProgress) -> Void) { self.limit = limit; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
      if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel(); return }
      progress(.init(received: totalBytesWritten, total: totalBytesExpectedToWrite))
    }
  }

  static func release(repository: String, tag: String) async throws -> QingTypeRelease {
    // Callers use an internal catalog; no user-controlled URLs or credentials.
    guard ["iDvel/rime-ice", "amzxyz/rime-wanxiang-data"].contains(repository),
          ["latest", "LTS"].contains(tag) else { throw SettingsError.invalid("未知的组件来源。") }
    let suffix = tag == "latest" ? "latest" : "tags/" + tag
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/\(suffix)")!)
    request.timeoutInterval = 45
    request.setValue("QingType", forHTTPHeaderField: "User-Agent")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2 * 1024 * 1024 else {
      throw SettingsError.invalid("无法读取官方组件信息，请检查网络后重试，也可以从本地文件导入。")
    }
    return try JSONDecoder().decode(QingTypeRelease.self, from: data)
  }

  static func download(repository: String, tag: String, filename: String, limit: Int64,
                       progress: @escaping @Sendable (QingTypeTransferProgress) -> Void = { _ in }) async throws -> QingTypeDownloadedAsset {
    let release = try await release(repository: repository, tag: tag)
    guard let asset = release.assets.first(where: { $0.name == filename }),
          filename == URL(fileURLWithPath: filename).lastPathComponent else { throw SettingsError.invalid("官方发行中没有找到所需组件。") }
    let hash = try asset.validate(repository: repository, limit: limit)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 1800
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let delegate = ProgressDelegate(limit: asset.size, progress: progress)
    let (file, response) = try await session.download(from: asset.browser_download_url, delegate: delegate)
    defer { try? FileManager.default.removeItem(at: file) }
    try Task.checkCancellation()
    guard (response as? HTTPURLResponse)?.statusCode == 200,
          try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(asset.size),
          try QingTypeContent.digest(of: file) == hash else {
      throw SettingsError.invalid("下载的组件与官方大小或 SHA-256 不符，已停止安装，请重试。")
    }
    try Task.checkCancellation()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-download-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      let target = directory.appendingPathComponent(filename)
      try FileManager.default.moveItem(at: file, to: target)
      return .init(directory: directory, file: target, sha256: hash, release: release.tag_name, repository: repository)
    } catch { try? FileManager.default.removeItem(at: directory); throw error }
  }
}

enum QingTypeWanxiang {
  static let repository = "amzxyz/rime-wanxiang-data"
  static func filename(schema: String) -> String { "wanxiang-lts-zh-" + (schema == "luna_pinyin" ? "hant" : "hans") + ".gram" }
  static func download(schema: String, progress: @escaping @Sendable (QingTypeTransferProgress) -> Void = { _ in }) async throws -> QingTypeDownloadedAsset {
    try await QingTypeDownloads.download(repository: repository, tag: "LTS", filename: filename(schema: schema), limit: 1024 * 1024 * 1024, progress: progress)
  }
}
