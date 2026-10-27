//
//  Main.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit

@main
struct SquirrelApp {
  static let userDir = QingTypePaths.userDirectory
  static let appDir = Bundle.main.bundleURL
  static let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("rime.qingtype", isDirectory: true)

  // swiftlint:disable:next cyclomatic_complexity
  static func main() {
    let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee

    let handled = autoreleasepool {
      let installer = SquirrelInstaller()
      if let index = CommandLine.arguments.firstIndex(of: "--learning-restart-probe"), CommandLine.arguments.count > index + 2 {
        if !QingTypeLearningDiagnostics.probe(api: rimeAPI, directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]), schema: CommandLine.arguments[index + 2]) { exit(1) }
        return true
      }
      if CommandLine.arguments.contains("--learning-engine-test") {
        let package = ProcessInfo.processInfo.environment["QINGTYPE_RIME_ICE_TEST_PACKAGE"].map { URL(fileURLWithPath: $0) }
        return QingTypeLearningDiagnostics.run(api: rimeAPI, package: package)
      }
      if let index = CommandLine.arguments.firstIndex(of: "--learning-data-worker"), CommandLine.arguments.count > index + 1 {
        do {
          let lock = try QingTypeDataLock(directory: userDir, exclusive: true)
          defer { withExtendedLifetime(lock) {} }
          guard NSRunningApplication.runningApplications(withBundleIdentifier: "org.qingtype.inputmethod.QingType")
            .allSatisfy({ $0.processIdentifier == getpid() }) else { throw SettingsError.invalid("输入服务仍在运行，学习数据操作已停止。") }
          let source = CommandLine.arguments.count > index + 2 ? URL(fileURLWithPath: CommandLine.arguments[index + 2]) : nil
          let report = try QingTypeLearningMaintenance.run(api: rimeAPI, action: CommandLine.arguments[index + 1], directory: userDir, source: source)
          print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(error is QingTypeLearningRecoveryError ? 2 : 1) }
        return true
      }
      if CommandLine.arguments.contains("--engine-smoke-test") {
        return QingTypeDiagnostics.runEngineTest(api: rimeAPI)
      }
      if CommandLine.arguments.contains("--factory-engine-test") {
        return QingTypeSetupDiagnostics.run(api: rimeAPI)
      }
      if CommandLine.arguments.contains("--candidate-ui-test") {
        return QingTypeDiagnostics.runCandidateTests()
      }
      if CommandLine.arguments.contains("--personal-dictionary-engine-test") {
        return QingTypePersonalDictionaryDiagnostics.run(api: rimeAPI)
      }
      if let index = CommandLine.arguments.firstIndex(of: "--rime-ice-engine-test"), CommandLine.arguments.count > index + 1 {
        return QingTypeRimeIceDiagnostics.run(api: rimeAPI, package: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
      }
      if CommandLine.arguments.contains("--preview-system") {
        QingTypeDiagnostics.showSystemPreview()
        return true
      }
      if CommandLine.arguments.contains("--preview-expanded") {
        QingTypeDiagnostics.showExpandedPreview()
        return true
      }
      if CommandLine.arguments.contains("--deploy-user-data") {
        do {
          let lock = try QingTypeDataLock(directory: userDir, exclusive: true)
          defer { withExtendedLifetime(lock) {} }
          let running = NSRunningApplication.runningApplications(withBundleIdentifier: "org.qingtype.inputmethod.QingType")
            .filter { $0.processIdentifier != getpid() }
          guard running.isEmpty else {
            throw SettingsError.invalid("清言输入法正在运行。请在清言设置中使用“保存并应用”，以便安全退出并重新部署。")
          }
          let report = try QingTypeMaintenance.deploy(api: rimeAPI)
          let data = try JSONEncoder().encode(report)
          print(String(decoding: data, as: UTF8.self))
          if !report.success { exit(1) }
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        return true
      }
      if CommandLine.arguments.count > 2 && ["--import-dictionary", "--import-model"].contains(CommandLine.arguments[1]) {
        do {
          var settings = try QingTypeSettings.load()
          let source = URL(fileURLWithPath: CommandLine.arguments[2])
          if CommandLine.arguments[1] == "--import-model" {
            let model = try QingTypeContent.importGrammar(from: source, into: userDir)
            if !settings.models.contains(where: { $0.id == model.id }) { settings.models.append(model) }
            settings.activeModelID = model.id
          } else {
            settings.dictionaries.append(try QingTypeContent.importDictionary(from: source, into: userDir))
          }
          try settings.save()
          print("导入完成，请重新部署以应用。")
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        return true
      }
      if CommandLine.arguments.contains("--preview") {
        QingTypeDiagnostics.showPreview()
        return true
      }
      let args = CommandLine.arguments
      if args.count > 1 {
        switch args[1] {
        case "--status":
          let report: [String: Any] = [
            "bundle": Bundle.main.bundleIdentifier ?? "", "userDirectory": userDir.path,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "rimeVersion": rimeAPI.get_version().map { String(cString: $0) } ?? "unknown",
            "connectionName": Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String ?? "",
            "controllerClassFound": NSClassFromString("QingType.QingTypeInputController") != nil,
            "inputSources": installer.status()
          ]
          if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
          }
          return true
        case "--quit":
          let bundleId = Bundle.main.bundleIdentifier!
          let runningSquirrels = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != getpid() }
          runningSquirrels.forEach { $0.terminate() }
          let deadline = Date().addingTimeInterval(5)
          while runningSquirrels.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
          }
          if runningSquirrels.contains(where: { !$0.isTerminated }) {
            fputs("清言尚未退出，停止替换程序。\n", stderr)
            exit(1)
          }
          return true
        case "--reload":
          DistributedNotificationCenter.default().postNotificationName(.init("QingTypeReloadNotification"), object: nil)
          return true
        case "--register-input-source", "--install":
          installer.register()
          return true
        case "--enable-input-source":
          if args.count > 2 {
            let modes = args[2...].map { SquirrelInstaller.InputMode(rawValue: $0) }.compactMap { $0 }
            if !modes.isEmpty {
              installer.enable(modes: modes)
              return true
            }
          }
          installer.enable()
          return true
        case "--disable-input-source":
          if args.count > 2 {
            let modes = args[2...].map { SquirrelInstaller.InputMode(rawValue: $0) }.compactMap { $0 }
            if !modes.isEmpty {
              installer.disable(modes: modes)
              return true
            }
          }
          installer.disable()
          return true
        case "--select-input-source":
          if args.count > 2, let mode = SquirrelInstaller.InputMode(rawValue: args[2]) {
            installer.select(mode: mode)
          } else {
            installer.select()
          }
          return true
        case "--build":
          // Notification
          SquirrelApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_update", comment: ""))
          // Build all schemas in current directory
          var builderTraits = RimeTraits.rimeStructInit()
          builderTraits.setCString("rime.qingtype-builder", to: \.app_name)
          rimeAPI.setup(&builderTraits)
          rimeAPI.deployer_initialize(nil)
          _ = rimeAPI.deploy()
          return true
        case "--sync":
          DistributedNotificationCenter.default().postNotificationName(.init("QingTypeSyncNotification"), object: nil)
          return true
        case "--help":
          print(helpDoc)
          return true
        default:
          break
        }
      }
      return false
    }
    if handled {
      return
    }

    autoreleasepool {
      let dataLock: QingTypeDataLock
      do { dataLock = try QingTypeDataLock(directory: userDir, exclusive: false) }
      catch { NSLog("QingType data is busy: %@", error.localizedDescription); return }
      defer { withExtendedLifetime(dataLock) {} }
      // CLI diagnostics above are independent. A second service instance must
      // never compete with the installed input method for its IMK endpoint.
      if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
        .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
        NSLog("QingType service already running, pid=%d", existing.processIdentifier)
        return
      }
      // find the bundle identifier and then initialize the input method server
      let main = Bundle.main
      let connectionName = main.object(forInfoDictionaryKey: "InputMethodConnectionName") as! String
      guard let server = IMKServer(name: connectionName, bundleIdentifier: main.bundleIdentifier!) else {
        NSLog("Cannot create QingType IMKServer for %@", connectionName)
        return
      }
      NSLog("QingType IMKServer ready: %@", connectionName)
      // load the bundle explicitly because in this case the input method is a
      // background only application
      let app = NSApplication.shared
      let delegate = SquirrelApplicationDelegate()
      app.delegate = delegate
      app.setActivationPolicy(.accessory)

      // opencc will be configured with relative dictionary paths
      FileManager.default.changeCurrentDirectoryPath(main.sharedSupportPath!)

      if NSApp.squirrelAppDelegate.problematicLaunchDetected() {
        print("Problematic launch detected!")
        let args = ["Problematic launch detected! Squirrel may be suffering a crash due to improper configuration. Revert previous modifications to see if the problem recurs."]
        let task = Process()
        task.executableURL = "/usr/bin/say".withCString { dir in
          URL(fileURLWithFileSystemRepresentation: dir, isDirectory: false, relativeTo: nil)
        }
        task.arguments = args
        try? task.run()
      } else {
        do { try QingTypeSettings.ensureInitialConfiguration() }
        catch { NSLog("Cannot prepare QingType settings: \(error)") }
        NSApp.squirrelAppDelegate.setupRime()
        NSApp.squirrelAppDelegate.startRime(fullCheck: false)
        NSApp.squirrelAppDelegate.loadSettings()
        print("QingType reporting!")
      }

      // finally run everything
      withExtendedLifetime(server) { app.run() }
      print("QingType is quitting...")
      rimeAPI.finalize()
    }
    return
  }

  static let helpDoc = """
Supported arguments:
Perform actions:
  --quit                     quit all QingType processes
  --reload                   deploy
  --sync                     sync user data
  --status                   report registration and runtime class status
  --build                    build all schemas in current directory
  --engine-smoke-test        test Rime in an isolated temporary directory
  --preview [--capture path] show the actual candidate panel
Install QingType:
  --install, --register-input-source    register input source
  --enable-input-source [source id...]  input source list optional
  --disable-input-source [source id...] input source list optional
  --select-input-source [source id]     input source optional
"""
}
