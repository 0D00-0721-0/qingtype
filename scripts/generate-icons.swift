import AppKit

let folders = Array(CommandLine.arguments.dropFirst())
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("QingType-\(UUID()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    NSColor(srgbRed: 0.12, green: 0.43, blue: 0.69, alpha: 1).setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: Double(pixels) * 0.035, dy: Double(pixels) * 0.035),
                 xRadius: Double(pixels) * 0.22, yRadius: Double(pixels) * 0.22).fill()
    let text = "清" as NSString
    let font = NSFont.systemFont(ofSize: Double(pixels) * 0.63, weight: .medium)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let textSize = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (Double(pixels) - textSize.width) / 2, y: (Double(pixels) - textSize.height) / 2), withAttributes: attributes)
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
  }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", folders[0] + "/QingType.icns"]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(1) }
for folder in folders.dropFirst() {
  let destination = URL(fileURLWithPath: folder).appendingPathComponent("QingType.icns")
  try? FileManager.default.removeItem(at: destination)
  try FileManager.default.copyItem(atPath: folders[0] + "/QingType.icns", toPath: destination.path)
}
let menu = NSView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
let label = NSTextField(labelWithString: "清")
label.font = .systemFont(ofSize: 15, weight: .medium)
label.textColor = .black
label.frame = NSRect(x: 1, y: 0, width: 17, height: 18)
menu.addSubview(label)
try menu.dataWithPDF(inside: menu.bounds).write(to: URL(fileURLWithPath: folders[0] + "/qingtype-menu.pdf"))
