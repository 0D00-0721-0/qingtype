import AppKit

enum QingTypeSystemDiagnostics {
  static func report(api: RimeApi_stdbool, installer: SquirrelInstaller) -> [String: Any] {
    var result: [String: Any] = ["format": "org.qingtype.diagnostics", "version": 1,
      "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
      "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
      "architecture": QingTypeAppUpdates.architecture,
      "rimeVersion": api.get_version().map { String(cString: $0) } ?? "unknown",
      "inputSources": installer.status(), "dataLocation": "~/Library/QingType"]
    if let settings = try? QingTypeSettings.load() {
      result["settingsReadable"] = true; result["configuration"] = QingTypeDiagnosticSummary.configuration(settings)
    } else { result["settingsReadable"] = false }
    result["screens"] = NSScreen.screens.map { ["width": $0.frame.width, "height": $0.frame.height, "scale": $0.backingScaleFactor] }
    let catalog: [(String, String, [String])] = [
      ("TextEdit", "com.apple.TextEdit", ["/System/Applications/TextEdit.app"]),
      ("Safari", "com.apple.Safari", ["/Applications/Safari.app"]),
      ("Notes", "com.apple.Notes", ["/System/Applications/Notes.app"]),
      ("Terminal", "com.apple.Terminal", ["/System/Applications/Utilities/Terminal.app"]),
      ("QQ", "com.tencent.qq", ["/Applications/QQ.app"]),
      ("WeChat", "com.tencent.xinWeChat", ["/Applications/WeChat.app", "/Applications/微信.app"]),
      ("VS Code", "com.microsoft.VSCode", ["/Applications/Visual Studio Code.app"]),
      ("Word", "com.microsoft.Word", ["/Applications/Microsoft Word.app"]),
      ("Pages", "com.apple.iWork.Pages", ["/Applications/Pages.app"])]
    result["applications"] = catalog.map { name, id, paths -> [String: Any] in
      let bundle = paths.compactMap { Bundle(path: $0) }.first { $0.bundleIdentifier == id }
      var app: [String: Any] = ["name": name, "foundAtStandardLocation": bundle != nil]
      if let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         version.range(of: "^[0-9][0-9A-Za-z.() -]{0,50}$", options: .regularExpression) != nil { app["version"] = version }
      return app
    }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: QingTypeAppInstallation.bundleID).filter { $0.processIdentifier != getpid() }
    result["runningServiceCount"] = running.count
    if let first = running.first, let rss = residentKB(first.processIdentifier) { result["serviceResidentMB"] = Double(rss) / 1024 }
    return result
  }

  static func residentKB(_ pid: pid_t) -> Int? {
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/ps"); task.arguments = ["-o", "rss=", "-p", String(pid)]
    let output = Pipe(); task.standardOutput = output; task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func stress(api: RimeApi_stdbool, cycles: Int) -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-stress-\(UUID())")
    var initialized = false
    var session: RimeSessionId = 0
    defer {
      if session != 0 { _ = api.destroy_session(session) }
      if initialized { api.finalize() }
      try? FileManager.default.removeItem(at: directory)
    }
    do {
      var settings = QingTypeSettings(); settings.learningEnabled = false; settings.pageSize = 7
      try settings.save(to: directory)
      guard try QingTypeMaintenance.deploy(api: api, directory: directory).success else { throw SettingsError.invalid("压力测试初始化失败。") }
      QingTypeLearningDiagnostics.initialize(api: api, directory: directory); initialized = true
      session = api.create_session()
      guard session != 0, api.select_schema(session, settings.schema) else { throw SettingsError.invalid("压力测试无法创建输入会话。") }
      let app = NSApplication.shared; app.setActivationPolicy(.accessory)
      let presenter = QingTypeCandidatePresenter(showsWindow: false)
      let words = ["nihao", "xuexi", "zhongguo", "jisuanji", "wojintianxuexijisuanjiwangluo"]
      var times: [Double] = []
      var before: Int?
      for index in 0..<(cycles + 100) {
        try autoreleasepool {
          let start = DispatchTime.now().uptimeNanoseconds
          _ = api.process_key(session, Int32(XK_Escape), 0)
          let input = words[index % words.count]
          for key in input.utf8 { _ = api.process_key(session, Int32(key), 0) }
          let candidates = QingTypeCandidateSource.read(api: api, session: session, startingAt: 0, limit: 64)
          guard !candidates.isEmpty else { throw SettingsError.invalid("压力测试出现空候选。") }
          presenter.update(candidates: candidates, highlighted: candidates[0].index, settings: settings,
                           caretRect: NSRect(x: 300, y: 500, width: 1, height: 24), composition: input)
          if index % 10 == 0 { presenter.expand() } else { presenter.collapse() }
          if index >= 100 { times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
        }
        if index == 99 { before = residentKB(getpid()) }
      }
      presenter.hide()
      let sorted = times.sorted()
      let report: [String: Any] = ["format": "org.qingtype.engine-stress", "cycles": cycles,
        "dataIsolated": true, "hostKeyboardEvents": false, "optionalModelLoaded": false,
        "averageEngineAndLayoutMS": times.reduce(0, +) / Double(times.count),
        "p95EngineAndLayoutMS": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
        "warmResidentKB": before ?? 0, "finalResidentKB": residentKB(getpid()) ?? 0]
      print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
      return true
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
  }
}
