import AppKit

enum QingTypeSystemDiagnostics {
  static func report(api: RimeApi_stdbool, installer: SquirrelInstaller) throws -> [String: Any] {
    var result: [String: Any] = ["format": "org.qingtype.diagnostics", "version": 1,
      "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
      "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
      "architecture": QingTypeAppUpdates.architecture,
      "rimeVersion": api.get_version().map { String(cString: $0) } ?? "unknown",
      "inputSources": try installer.status(), "dataLocation": "~/Library/QingType"]
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

  static func stress(api: RimeApi_stdbool, cycles: Int, minimumSeconds: Double = 0) -> Bool {
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
      var totalMS = 0.0, measuredCycles = 0
      var verifiedCommits = 0, editedCompositions = 0, cancelledCompositions = 0
      var selected: Int?
      presenter.onSelect = { index in
        if api.select_candidate(session, index) { selected = index }
      }
      struct MemoryPoint {
        var elapsedSeconds: Double
        var measuredCycles: Int
        var residentKB: Int
      }
      var memory: [MemoryPoint] = []
      var memoryTruncated = false
      var started: UInt64?
      var nextSample: Double = 1
      func elapsed() -> Double {
        started.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000_000 } ?? 0
      }
      func sampleMemory() throws {
        guard let rss = autoreleasepool(invoking: { residentKB(getpid()) }), rss > 0 else {
          throw SettingsError.invalid("压力测试无法确认进程内存，未生成成功结果。")
        }
        let point = MemoryPoint(elapsedSeconds: elapsed(), measuredCycles: measuredCycles, residentKB: rss)
        if memory.count < 1024 { memory.append(point) }
        else { memory[memory.count - 1] = point; memoryTruncated = true }
      }
      var index = 0
      while index < cycles + 100 || elapsed() < minimumSeconds {
        try autoreleasepool {
          let start = DispatchTime.now().uptimeNanoseconds
          _ = api.process_key(session, Int32(XK_Escape), 0)
          let input = words[index % words.count]
          for key in input.utf8 { _ = api.process_key(session, Int32(key), 0) }
          if index % 7 == 0 {
            _ = api.process_key(session, Int32(Character("x").asciiValue!), 0)
            _ = api.process_key(session, Int32(XK_BackSpace), 0)
            guard api.get_input(session).map({ String(cString: $0) }) == input else {
              throw SettingsError.invalid("压力测试退格后的输入不一致。")
            }
            if index >= 100 { editedCompositions += 1 }
          }
          let candidates = QingTypeCandidateSource.read(api: api, session: session, startingAt: 0, limit: 64)
          guard !candidates.isEmpty else { throw SettingsError.invalid("压力测试出现空候选。") }
          presenter.update(candidates: candidates, highlighted: candidates[0].index, settings: settings,
                           caretRect: NSRect(x: 300, y: 500, width: 1, height: 24), composition: input)
          if index % 10 == 0 { presenter.expand() } else { presenter.collapse() }
          if index % words.count == words.count - 1 {
            _ = api.process_key(session, Int32(XK_Escape), 0)
            presenter.hide()
            guard api.get_input(session).map({ String(cString: $0) }) ?? "" == "" else {
              throw SettingsError.invalid("压力测试取消组合未完成。")
            }
            if index >= 100 { cancelledCompositions += 1 }
          } else {
            selected = nil
            guard presenter.handleKey(code: 49, text: " "),
                  let selected, let expected = candidates.first(where: { $0.index == selected })?.text else {
              throw SettingsError.invalid("压力测试无法选择当前候选。")
            }
            var commit = RimeCommit.rimeStructInit()
            guard api.get_commit(session, &commit) else { throw SettingsError.invalid("压力测试没有收到上屏文字。") }
            let text = commit.text.map { String(cString: $0) }
            _ = api.free_commit(&commit)
            guard text == expected else { throw SettingsError.invalid("压力测试上屏文字与候选不一致。") }
            if index >= 100 { verifiedCommits += 1 }
          }
          if index >= 100 {
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            measuredCycles += 1; totalMS += duration
            if times.count < 8192 {
              times.append(duration)
            } else {
              // Uniform reservoir sampling avoids unbounded timing storage and
              // does not alias the periodic expand/edit/cancel workload.
              let replacement = Int.random(in: 0..<measuredCycles)
              if replacement < times.count { times[replacement] = duration }
            }
          }
        }
        if index == 99 { started = DispatchTime.now().uptimeNanoseconds; try sampleMemory() }
        if index >= 100, elapsed() >= nextSample { try sampleMemory(); nextSample = elapsed() + 1 }
        index += 1
        if index > 100, minimumSeconds > 0 { Thread.sleep(forTimeInterval: 0.01) }
      }
      presenter.hide()
      try sampleMemory()
      let sorted = times.sorted()
      let report: [String: Any] = ["format": "org.qingtype.engine-stress", "formatVersion": 2, "workloadVersion": 2,
        "cycles": measuredCycles, "requestedCycles": cycles, "minimumSeconds": minimumSeconds, "elapsedSeconds": elapsed(),
        "dataIsolated": true, "hostKeyboardEvents": false, "optionalModelLoaded": false,
        "realApplicationInputVerified": false,
        "verifiedCommits": verifiedCommits, "editedCompositions": editedCompositions, "cancelledCompositions": cancelledCompositions,
        "averageEngineAndLayoutMS": totalMS / Double(measuredCycles),
        "p95EngineAndLayoutMS": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
        "latencySampleCount": times.count, "latencySampling": "reservoir-up-to-8192",
        "warmResidentKB": memory[0].residentKB, "finalResidentKB": memory.last!.residentKB,
        "memorySamplesTruncated": memoryTruncated,
        "memorySamples": memory.map { point -> [String: Any] in
          ["elapsedSeconds": point.elapsedSeconds, "measuredCycles": point.measuredCycles, "residentKB": point.residentKB]
        }]
      print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
      return true
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
  }
}
