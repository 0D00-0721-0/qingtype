import AppKit
import InputMethodKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let server = IMKServer(name: "QingType_CandidateProbe", bundleIdentifier: "org.qingtype.inputmethod.QingType")!
let panel = IMKCandidates(server: server, panelType: Int(kIMKSingleRowSteppingCandidatePanel))!
panel.setCandidateData(["你好", "拟好", "你", "呢", "泥"])
panel.setSelectionKeys([18, 19, 20, 21, 23])
panel.setAttributes([NSAttributedString.Key.font: NSFont.systemFont(ofSize: 16)])
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
  panel.setCandidateFrameTopLeft(NSPoint(x: 600, y: 500))
  panel.show()
  print("Windows: \(app.windows.count)")
  print("Native candidate frame: \(panel.candidateFrame()) visible: \(panel.isVisible())")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { app.terminate(nil) }
app.run()
