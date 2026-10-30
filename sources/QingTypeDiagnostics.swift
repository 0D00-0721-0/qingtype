import AppKit
import InputMethodKit

enum QingTypeDiagnostics {
  // These construct real AppKit controls without showing a window or posting
  // keyboard events to a host application.
  static func runCandidateTests() -> Bool {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var passed: [String] = []
    func expect(_ condition: Bool, _ name: String, detail: String = "") {
      guard condition else { fputs("FAIL: \(name)\n\(detail)\n", stderr); exit(1) }
      passed.append(name)
    }
    let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
    let size = NSSize(width: 400, height: 150)
    let ordinary = NSRect(x: -1000, y: 500, width: 1, height: 24)
    let below = QingTypeCandidatePlacement.frame(size: size, caret: ordinary, screen: screen)
    expect(below.maxY == ordinary.minY - 6 && below.minX == ordinary.minX - 16,
           "candidate text, rather than the panel edge, aligns with the marked-text origin")
    let bottomCaret = NSRect(x: -20, y: 5, width: 1, height: 24)
    let above = QingTypeCandidatePlacement.frame(size: size, caret: bottomCaret, screen: screen)
    expect(screen.contains(above) && above.minY == bottomCaret.maxY + 6, "bottom/right edge flips above and clamps on a negative-origin display")
    expect(!QingTypeCandidatePlacement.isUsable(.zero), "missing caret geometry cannot create a window at the screen origin")
    let emptyLegacyView = SquirrelView(frame: .zero)
    expect(emptyLegacyView.contentRect == .zero && emptyLegacyView.convert(range: NSRange(location: NSNotFound, length: 1)) == nil,
           "empty legacy text layout and unknown ranges yield safe geometry")
    let legacyPanel = SquirrelPanel(position: .zero)
    legacyPanel.contentView = nil
    legacyPanel.update(preedit: "", selRange: NSRange(location: 0, length: 0), caretPos: 0,
                       candidates: ["你"], comments: [], labels: [], highlighted: 0, page: 0, lastPage: true, update: true)
    expect(!legacyPanel.isVisible, "legacy panel safely skips drawing without a content view or usable position")
    legacyPanel.update(preedit: "你", selRange: NSRange(location: NSNotFound, length: 1), caretPos: 0,
                       candidates: ["你"], comments: [], labels: [], highlighted: 0, page: 0, lastPage: true, update: true)
    expect(!legacyPanel.isVisible, "legacy panel rejects an invalid marked-text range")
    legacyPanel.hide()

    var settings = QingTypeSettings()
    settings.pageSize = 7
    let values = (100..<164).map { QingTypeCandidate(index: $0, text: "词条") }
    let presenter = QingTypeCandidatePresenter(showsWindow: false)
    let identity = ObjectIdentifier(presenter.window)
    let caret = NSRect(x: 300, y: 500, width: 1, height: 24)
    var picked: Int?
    presenter.onSelect = { picked = $0 }
    presenter.update(candidates: values, highlighted: 100, settings: settings, caretRect: caret, composition: "ci")
    let window = presenter.window
    expect(window.frame.height == 29 && window.frame.minX == caret.minX - 16,
           "default native row matches the 29 pt Apple reference without changing candidate count")
    expect(!window.canBecomeKey && !window.canBecomeMain && !window.isVisible, "candidate controls do not activate or focus a host window")
    expect(window.contentView!.bounds.contains(window.toggleFrame) && !window.cellFrames.contains(where: { $0.intersects(window.toggleFrame) }),
           "collapsed chevron is inside its owner and cannot overlap candidate cells")
    expect(!presenter.handleKey(code: 123, text: nil) && !presenter.handleKey(code: 124, text: nil),
           "collapsed left/right keys remain available for editing pinyin")
    expect(!presenter.handleKey(code: 36, text: "\r"), "collapsed Return remains available for raw-pinyin commit")
    let arrow = window.contentView!.subviews.compactMap { $0 as? NSButton }.first!
    arrow.performClick(nil)
    expect(presenter.isExpanded && ObjectIdentifier(presenter.window) == identity, "the actual chevron action expands its own window")
    presenter.collapse()
    expect(presenter.handleKey(code: 125, text: nil) && presenter.isExpanded && ObjectIdentifier(presenter.window) == identity,
           "Down expands the same window without a detached arrow or overlay")
    expect(window.columns == 6 && window.cellFrames.count == 6 && !window.cellFrames.contains(where: { $0.intersects(window.toggleFrame) }),
           "expanded first row reserves a separate chevron hit area")
    window.highlight(137)
    let body = window.bodyIdentity
    let origin = window.scrollOrigin
    presenter.update(candidates: values, highlighted: 100, settings: settings, caretRect: caret, composition: "ci")
    expect(window.selectedIndex == 137 && window.bodyIdentity == body && window.scrollOrigin == origin,
           "same-composition updates preserve grid selection, view and scrolling")
    expect(presenter.handleKey(code: 49, text: " ") && picked == 137, "Space commits the highlighted absolute grid index")
    expect(presenter.handleKey(code: 53, text: nil) && !presenter.isExpanded && window.selectedIndex == 137,
           "Escape collapses without losing the selected candidate")
    picked = nil
    expect(presenter.handleKey(code: 19, text: "2") && picked == 137, "collapsed number selection maps to the adaptive visible page after collapse")
    presenter.update(candidates: values, highlighted: 100, settings: settings, caretRect: caret, composition: "cian")
    expect(window.selectedIndex == 100, "editing composition resets stale UI selection")
    presenter.expand()
    picked = nil
    expect(presenter.handleKey(code: 22, text: "6") && picked == 105, "expanded number keys select the fixed first row")
    presenter.hide()
    expect(!presenter.isExpanded && !presenter.handleKey(code: 49, text: " "), "hidden candidates do not consume typing")
    let phrases = ["发信魔性了吗", "发信模型了吗", "发信魔性了嘛", "发信模型了嘛", "发", "发信", "法", "发薪"] + Array(repeating: "词", count: 30)
    presenter.update(candidates: phrases.enumerated().map { QingTypeCandidate(index: $0.offset + 200, text: $0.element) },
                     highlighted: 200, settings: settings, caretRect: caret, composition: "faxinmoxinglema")
    presenter.expand()
    expect(window.frame.width == 397 && window.cellFrames.count == 3,
           "long phrases use three complete spans in a bounded native-width first row")
    let phraseWidth = (phrases[0] as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)]).width
    expect(window.cellFrames[0].width - 18 >= phraseWidth && window.allCellFrames[3].width - 18 >= phraseWidth,
           "long header and body phrases fit without truncation into a single short cell")
    expect(window.allCellFrames[3].minY == window.allCellFrames[4].minY &&
           window.allCellFrames[7].minY == window.allCellFrames[3].minY && window.allCellFrames[8].minY > window.allCellFrames[7].minY,
           "the body wraps variable spans at six columns and preserves engine order")
    picked = nil
    expect(presenter.handleKey(code: 20, text: "3") && picked == 202 && presenter.handleKey(code: 21, text: "4") && picked == 202,
           "expanded numbers address only visible phrases and consume unavailable digits before Rime")
    window.highlight(200)
    window.move(horizontal: 0, vertical: 1)
    expect(window.selectedIndex == 203, "Down follows the next visual row when candidates span columns")
    window.move(horizontal: 0, vertical: -1)
    expect(window.selectedIndex == 200 && !window.cellFrames.contains(where: { $0.intersects(window.toggleFrame) }),
           "Up returns to the aligned phrase and spanning headers cannot overlap the chevron")
    presenter.hide()
    let compactWords = ["你带大舅爱戴是大舅爱大舅爱的", "你带的", "你", "你好", "妳好", "逆号", "拟好", "尼"]
    presenter.update(candidates: compactWords.enumerated().map { .init(index: 300 + $0.offset, text: $0.element) },
                     highlighted: 300, settings: settings, caretRect: caret, composition: "nidaidajaidaisdjaidjaid")
    let fullWidth = (compactWords[0] as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)]).width
    expect(window.cellFrames.count < settings.pageSize && window.cellFrames[0].width - 18 >= fullWidth,
           "collapsed long phrase stays complete by reducing visible candidate count instead of adding an ellipsis")
    expect(window.frame.width <= QingTypeCandidateMetrics.nativeWidth(pointSize: 16) &&
           !window.cellFrames.contains(where: { $0.intersects(window.toggleFrame) }),
           "adaptive collapsed row keeps the native width and separate arrow")
    picked = nil
    expect(presenter.handleKey(code: 19, text: "2") && picked == 301 &&
           presenter.handleKey(code: 26, text: "7") && picked == 301, "hidden compact candidates cannot be selected by falling through to Rime")
    presenter.expand(); presenter.collapse()
    expect(window.cellFrames[0].width - 18 >= fullWidth && !presenter.isExpanded,
           "expand then collapse preserves the complete long first candidate")
    window.highlight(306)
    picked = nil
    expect(presenter.handleKey(code: 18, text: "1") && picked != 300 && picked != nil,
           "collapsing onto a later adaptive page maps its numbers to visible absolute indices")
    presenter.hide()
    let otherScreen = NSRect(x: 1440, y: -200, width: 1024, height: 768)
    let movedCaret = NSRect(x: 1600, y: 500, width: 1, height: 24)
    let movedFrame = QingTypeCandidatePlacement.frame(size: size, caret: movedCaret, screen: otherScreen)
    expect(otherScreen.contains(movedFrame) && movedFrame.minX == movedCaret.minX - 16,
           "placement after moving screens uses the new screen origin and visible bounds")
    let oversized = QingTypeCandidatePlacement.frame(size: NSSize(width: 2400, height: 1600), caret: movedCaret, screen: otherScreen)
    expect(oversized == otherScreen, "candidate placement clamps oversized content to a smaller display")
    expect(!QingTypeCandidatePlacement.isUsable(NSRect(x: CGFloat.nan, y: 10, width: 1, height: 20)) &&
           !QingTypeCandidatePlacement.isUsable(NSRect(x: 10, y: 10, width: 1, height: CGFloat.infinity)),
           "nonfinite external caret coordinates cannot position a candidate window")
    presenter.update(candidates: [.init(index: 900, text: "新会话"), .init(index: 901, text: "新候选")],
                     highlighted: 900, settings: settings, caretRect: caret, composition: "xin")
    picked = nil
    expect(!presenter.isExpanded && presenter.handleKey(code: 18, text: "1") && picked == 900 && ObjectIdentifier(window) == identity,
           "new composition after hide resets expansion and never selects an old session index")
    presenter.hide()

    func buttons(in view: NSView?) -> [NSButton] {
      guard let view else { return [] }
      return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
    let transitions = QingTypeCandidatePresenter(showsWindow: false)
    let firstSnapshot = (0..<40).map { QingTypeCandidate(index: 1000 + $0, text: "前词\($0)") }
    var transitionPick: Int?
    transitions.onSelect = { transitionPick = $0 }
    transitions.update(candidates: firstSnapshot, highlighted: 1000, settings: settings,
                       caretRect: caret, composition: "qian")
    transitions.expand()
    let oldButton = buttons(in: transitions.window.contentView).first { $0.title == "前词0" }!
    transitions.hide() // The controller calls hidePalettes on app deactivation.
    oldButton.performClick(nil)
    expect(transitionPick == nil && !transitions.handleKey(code: 49, text: " "),
           "a delayed candidate action after app deactivation cannot commit to the old client")
    transitions.update(candidates: firstSnapshot, highlighted: 1000, settings: settings,
                       caretRect: caret, composition: "qian")
    transitions.expand()
    let replacedButton = buttons(in: transitions.window.contentView).first { $0.title == "前词0" }!
    let secondSnapshot = (0..<40).map { QingTypeCandidate(index: 1000 + $0, text: "后词\($0)") }
    transitions.update(candidates: secondSnapshot, highlighted: 1000, settings: settings,
                       caretRect: caret, composition: "qian")
    replacedButton.performClick(nil)
    expect(transitionPick == nil, "a replaced candidate button cannot commit a different word that reused its index")
    transitions.window.highlight(1020)
    let delayedHover = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: transitions.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    replacedButton.mouseMoved(with: delayedHover)
    expect(transitions.window.selectedIndex == 1020,
           "a delayed hover from a replaced candidate cannot change the new snapshot selection")
    let currentButton = buttons(in: transitions.window.contentView).first { $0.title == "后词0" }!
    currentButton.performClick(nil)
    expect(transitionPick == 1000, "the current candidate button still commits after a same-index snapshot replacement")
    transitions.window.highlight(1030)
    let reordered = [secondSnapshot[17], secondSnapshot[2], QingTypeCandidate(index: 1200, text: "新词")]
    transitions.update(candidates: reordered, highlighted: 1000, settings: settings,
                       caretRect: caret, composition: "qian")
    expect(transitions.window.selectedIndex == 1017 && transitions.window.cellFrames.count == 3,
           "shrinking and reordering candidates resets a removed selection to the new first candidate")
    transitionPick = nil
    expect(transitions.handleKey(code: 18, text: "1") && transitionPick == 1017 &&
           transitions.handleKey(code: 19, text: "2") && transitionPick == 1002 &&
           transitions.handleKey(code: 20, text: "3") && transitionPick == 1200,
           "expanded numbers follow the new order and absolute indices after candidate data changes")
    expect(transitions.handleKey(code: 21, text: "4") && transitionPick == 1200,
           "a removed numbered candidate cannot fall through to the engine after a snapshot shrinks")
    transitions.window.highlight(1200)
    transitions.collapse()
    expect(transitions.handleKey(code: 18, text: "1") && transitionPick == 1017 &&
           transitions.handleKey(code: 20, text: "3") && transitionPick == 1200,
           "collapsing a reordered snapshot keeps its visible numbers mapped to the new candidates")
    transitions.update(candidates: secondSnapshot, highlighted: 1020, settings: settings,
                       caretRect: caret, composition: "qian")
    transitionPick = nil
    expect(transitions.window.selectedIndex == 1020 && transitions.handleKey(code: 49, text: " ") && transitionPick == 1020,
           "an engine-highlight change replaces the UI selection before Space commits")
    transitions.update(candidates: [], highlighted: 0, settings: settings, caretRect: caret, composition: "")
    transitionPick = nil
    currentButton.performClick(nil)
    expect(!transitions.isExpanded && transitionPick == nil && !transitions.handleKey(code: 18, text: "1"),
           "an empty candidate snapshot ends interaction and ignores retained button actions")

    let nextClient = QingTypeCandidatePresenter(showsWindow: false)
    var nextClientPick: Int?
    nextClient.onSelect = { nextClientPick = $0 }
    nextClient.update(candidates: [.init(index: 0, text: "新应用"), .init(index: 1, text: "另一词")],
                      highlighted: 0, settings: settings, caretRect: caret, composition: "xin")
    expect(!nextClient.isExpanded && nextClient.handleKey(code: 19, text: "2") && nextClientPick == 1 && transitionPick == nil,
           "a new app presenter has independent expansion, numbering and selection callbacks")
    nextClient.hide()

    // Screen bounds are Cocoa points. Inject the same lookup used by present()
    // so CI can cover mode changes and cross-display moves without reconfiguring
    // the user's display. Actual display hotplug/backing changes remain manual.
    var visibleScreen = NSRect(x: -1280, y: 0, width: 1280, height: 800)
    let displayPresenter = QingTypeCandidatePresenter(showsWindow: false, visibleScreen: { _ in visibleScreen })
    let displayWindow = displayPresenter.window
    let displayIdentity = ObjectIdentifier(displayWindow)
    let pointCaret = NSRect(x: -1000.25, y: 500.5, width: 1, height: 23.5)
    displayPresenter.update(candidates: firstSnapshot, highlighted: 1000, settings: settings,
                            caretRect: pointCaret, composition: "qian")
    displayPresenter.expand()
    displayWindow.highlight(1020)
    let logicalFrame = displayWindow.frame
    let logicalCells = displayWindow.cellFrames
    var renderedSizes: [NSSize] = []
    var renderedColorCounts: [Int] = []
    for scale in [1, 2] {
      let content = displayWindow.contentView!
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(ceil(content.bounds.width)) * scale,
        pixelsHigh: Int(ceil(content.bounds.height)) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
      bitmap.size = content.bounds.size
      bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
      let context = NSGraphicsContext(bitmapImageRep: bitmap)!
      content.displayIgnoringOpacity(content.bounds, in: context)
      renderedSizes.append(NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
      var colors = Set<Int>()
      for y in stride(from: 0, to: bitmap.pixelsHigh, by: scale) {
        autoreleasepool {
          for x in stride(from: 0, to: bitmap.pixelsWide, by: scale) {
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 {
              colors.insert(Int((color.redComponent * 255).rounded()) << 16 |
                            Int((color.greenComponent * 255).rounded()) << 8 |
                            Int((color.blueComponent * 255).rounded()))
            }
          }
        }
      }
      renderedColorCounts.append(colors.count)
    }
    expect(renderedSizes[1].width == 2 * renderedSizes[0].width && renderedSizes[1].height == 2 * renderedSizes[0].height &&
           renderedColorCounts.allSatisfy { $0 > 4 } &&
           displayWindow.frame == logicalFrame && displayWindow.cellFrames == logicalCells && displayWindow.selectedIndex == 1020,
           "1x and 2x offscreen rendering draw candidate content while preserving logical geometry and selection")
    visibleScreen = NSRect(x: -960, y: 0, width: 960, height: 600)
    let scaledCaret = NSRect(x: -800.25, y: 500.5, width: 1, height: 23.5)
    displayPresenter.update(candidates: firstSnapshot, highlighted: 1000, settings: settings,
                            caretRect: scaledCaret, composition: "qian")
    // AppKit aligns an actual NSWindow frame to backing pixels; fractional
    // logical coordinates can round by up to one point on a 1x display.
    expect(visibleScreen.contains(displayWindow.frame) && abs(displayWindow.frame.minX - (scaledCaret.minX - 16)) <= 1 &&
           displayWindow.selectedIndex == 1020 && displayPresenter.isExpanded,
           "a display-mode change to fewer logical points repositions the expanded panel without resetting selection")
    visibleScreen = NSRect(x: 800, y: -100, width: 300.5, height: 130.5)
    let crossScreenCaret = NSRect(x: 1080.25, y: -80.5, width: 1, height: 23.5)
    displayPresenter.update(candidates: firstSnapshot, highlighted: 1000, settings: settings,
                            caretRect: crossScreenCaret, composition: "qian")
    let backingPixel = 1 / max(1, displayWindow.backingScaleFactor)
    expect(visibleScreen.insetBy(dx: -backingPixel, dy: -backingPixel).contains(displayWindow.frame) &&
           displayWindow.frame.width <= visibleScreen.width + backingPixel &&
           displayWindow.selectedIndex == 1020 && ObjectIdentifier(displayWindow) == displayIdentity,
           "moving the expanded panel to a smaller fractional-point display clamps within a backing pixel and preserves selection",
           detail: "screen=\(visibleScreen), frame=\(displayWindow.frame), backingPixel=\(backingPixel), selected=\(displayWindow.selectedIndex)")
    expect(displayWindow.cellFrames.allSatisfy { displayWindow.contentView!.bounds.contains($0) && !$0.intersects(displayWindow.toggleFrame) },
           "a smaller display keeps every numbered header inside the panel and clear of the chevron")
    var displayPick: Int?
    displayPresenter.onSelect = { displayPick = $0 }
    let headerButtons = buttons(in: displayWindow.contentView).filter { $0.title.hasPrefix("前词") && $0.accessibilityLabel()?.hasPrefix("1 ") == true }
    expect(headerButtons.count == 1 && displayPresenter.handleKey(code: 18, text: "1") && displayPick == 1000,
           "the visible first-row number still selects its absolute candidate after display and mode changes")
    displayPresenter.hide()
    displayPick = nil
    let staleDisplayButton = headerButtons[0]
    staleDisplayButton.performClick(nil)
    expect(displayPick == nil && !displayPresenter.isExpanded,
           "leaving the app after a display change cancels old candidate callbacks")
    transitions.hide()

    // Animate real AppKit windows offscreen, without sending keys to a client.
    // Observe intermediate geometry rather than asserting exact scheduler times.
    let animationScreen = NSRect(x: -6000, y: 0, width: 1440, height: 900)
    let animationCaret = NSRect(x: -5700, y: 500, width: 1, height: 24)
    var reducedMotion = false
    let animated = QingTypeCandidatePresenter(visibleScreen: { _ in animationScreen }, reduceMotion: { reducedMotion })
    let animatedWindow = animated.window
    func drainAnimation() -> [NSRect] {
      let deadline = Date().addingTimeInterval(1)
      var frames = [animatedWindow.frame]
      while animatedWindow.isTransitioning && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.008))
        frames.append(animatedWindow.frame)
      }
      return frames
    }
    animated.update(candidates: firstSnapshot, highlighted: 1000, settings: settings,
                    caretRect: animationCaret, composition: "qian")
    let surface = animatedWindow.contentView!
    let firstAnimatedButton = buttons(in: surface).first { $0.title == "前词0" }!
    let compactFrame = animatedWindow.frame
    expect(!animatedWindow.isTransitioning && compactFrame.height == 29,
           "first appearance does not delay input with a disclosure animation")
    animated.expand()
    expect(animatedWindow.isTransitioning && animatedWindow.frame == compactFrame &&
           animatedWindow.contentView === surface && buttons(in: surface).contains { $0 === firstAnimatedButton },
           "expansion starts from the existing surface and reuses matching header controls")
    let expansionFrames = drainAnimation()
    let expandedFrame = animatedWindow.frame
    expect(!animatedWindow.isTransitioning && expandedFrame.height > compactFrame.height &&
           expansionFrames.contains { $0.height > compactFrame.height && $0.height < expandedFrame.height } &&
           expansionFrames.allSatisfy { abs($0.maxY - compactFrame.maxY) <= 1 },
           "nonblocking expansion has intermediate sizes and keeps its caret-facing edge anchored")
    expect(firstAnimatedButton.frame.height == 28 && firstAnimatedButton.bounds.height == 28 &&
           !animatedWindow.canBecomeKey && !animatedWindow.canBecomeMain,
           "animated candidates keep glyph scale and never take keyboard focus")
    let expandedBody = animatedWindow.bodyIdentity
    animated.collapse()
    expect(animatedWindow.isTransitioning && animatedWindow.bodyIdentity == expandedBody && expandedBody != nil,
           "collapse retains the rows while the shrinking surface clips them")
    let collapseFrames = drainAnimation()
    expect(!animatedWindow.isTransitioning && animatedWindow.frame == compactFrame && animatedWindow.bodyIdentity == nil &&
           collapseFrames.contains { $0.height > compactFrame.height && $0.height < expandedFrame.height },
           "collapse finishes at the original capsule and releases the hidden rows")
    animated.expand()
    RunLoop.current.run(until: Date().addingTimeInterval(0.025))
    let interruptedFrame = animatedWindow.frame
    animated.collapse()
    expect(animatedWindow.frame == interruptedFrame && animatedWindow.isTransitioning,
           "reversing an expansion starts from its current window size instead of jumping to an endpoint")
    animated.expand()
    _ = drainAnimation()
    expect(animated.isExpanded && animatedWindow.frame == expandedFrame && animatedWindow.bodyIdentity != nil,
           "rapid expand-collapse-expand ignores stale completion cleanup")
    animated.collapse()
    animated.hide()
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    expect(!animatedWindow.isVisible && !animatedWindow.isTransitioning && !animated.isExpanded,
           "hiding during a transition cancels it without a delayed window reappearance")
    animated.update(candidates: firstSnapshot, highlighted: 1000, settings: settings,
                    caretRect: animationCaret, composition: "qian")
    animated.expand()
    animated.update(candidates: secondSnapshot, highlighted: 1000, settings: settings,
                    caretRect: animationCaret, composition: "hou")
    var animatedPick: Int?
    animated.onSelect = { animatedPick = $0 }
    expect(!animatedWindow.isTransitioning && animatedWindow.frame == expandedFrame &&
           animated.handleKey(code: 18, text: "1") && animatedPick == 1000 &&
           buttons(in: surface).contains { $0.title == "后词0" },
           "typing during a transition settles immediately and keeps the current number mapping")
    reducedMotion = true
    animated.collapse()
    expect(!animatedWindow.isTransitioning && animatedWindow.frame == compactFrame,
           "Reduce Motion collapses immediately")
    animated.expand()
    expect(!animatedWindow.isTransitioning && animatedWindow.frame == expandedFrame,
           "Reduce Motion expands immediately")
    animated.collapse()
    reducedMotion = false
    let lowCaret = NSRect(x: -5700, y: 40, width: 1, height: 24)
    animated.update(candidates: firstSnapshot, highlighted: 1000, settings: settings,
                    caretRect: lowCaret, composition: "qian")
    let lowerFrame = animatedWindow.frame
    animated.expand()
    expect(animatedWindow.isTransitioning && animatedWindow.frame == lowerFrame && lowerFrame.maxY < lowCaret.minY,
           "expanding across the lower screen edge starts an upward transition from the visible capsule")
    let upwardFrames = drainAnimation()
    let upperFrame = animatedWindow.frame
    expect(!animatedWindow.isTransitioning && upperFrame.minY > lowCaret.maxY && animationScreen.contains(upperFrame) &&
           upwardFrames.contains { $0.height > lowerFrame.height && $0.height < upperFrame.height },
           "screen-edge expansion has intermediate sizes and finishes above the caret")
    animated.collapse()
    let upwardCollapseFrames = drainAnimation()
    let upperCapsule = animatedWindow.frame
    expect(!animatedWindow.isTransitioning && upperCapsule.height == lowerFrame.height &&
           abs(upperCapsule.minY - upperFrame.minY) <= 1 &&
           upwardCollapseFrames.allSatisfy { abs($0.minY - upperFrame.minY) <= 1 } &&
           upwardCollapseFrames.contains { $0.height > upperCapsule.height && $0.height < upperFrame.height },
           "upward collapse stays above the caret and animates toward its fixed lower edge")
    animated.update(candidates: firstSnapshot, highlighted: 1000, settings: settings,
                    caretRect: lowCaret, composition: "qian")
    expect(animatedWindow.frame == upperCapsule,
           "an unchanged input-context refresh cannot move the upper capsule back below the caret")
    animated.expand()
    let upperExpansionFrames = drainAnimation()
    expect(animatedWindow.frame == upperFrame &&
           upperExpansionFrames.allSatisfy { abs($0.minY - upperCapsule.minY) <= 1 } &&
           upperExpansionFrames.contains { $0.height > upperCapsule.height && $0.height < upperFrame.height },
           "reopening an upper capsule grows upward with a fixed lower edge")
    animated.collapse()
    animated.expand()
    animated.hide()
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    expect(!animatedWindow.isVisible && !animatedWindow.isTransitioning,
           "hiding during rapid upward toggles cancels every pending transition")
    let bottomAnimationCaret = NSRect(x: -5700, y: 2, width: 1, height: 24)
    animated.update(candidates: firstSnapshot, highlighted: 1000, settings: settings,
                    caretRect: bottomAnimationCaret, composition: "qian")
    let initiallyUpper = animatedWindow.frame
    animated.expand()
    let initiallyUpperFrames = drainAnimation()
    expect(initiallyUpper.minY > bottomAnimationCaret.maxY && animatedWindow.frame.height > initiallyUpper.height &&
           initiallyUpperFrames.allSatisfy { abs($0.minY - initiallyUpper.minY) <= 1 } &&
           initiallyUpperFrames.contains { $0.height > initiallyUpper.height && $0.height < animatedWindow.frame.height },
           "a capsule initially above the caret also expands upward with intermediate frames")
    reducedMotion = true
    animated.collapse()
    expect(!animatedWindow.isTransitioning && animatedWindow.frame == initiallyUpper,
           "Reduce Motion preserves the upper placement while collapsing without animation")
    animated.hide()
    print("PASS: \(passed.count) candidate placement and interaction checks")
    passed.forEach { print("PASS: \($0)") }
    return true
  }

  // Runs in an isolated temporary directory, without registering an input source.
  static func runEngineTest(api: RimeApi_stdbool) -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qingtype-test-\(UUID())")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer {
        if ProcessInfo.processInfo.environment["QINGTYPE_KEEP_TEST_DATA"] == "1" {
          print("Test directory: \(directory.path)")
        } else { try? FileManager.default.removeItem(at: directory) }
      }
      var settings = QingTypeSettings()
      let fixture = directory.appendingPathComponent("fixture.dict.yaml")
      let extraCandidates = (1...12).map { "候选外观测试\($0)\tqi yan\t\(100000 + $0)\n" }.joined()
      try ("---\nname: fixture\nversion: '1'\n...\n清言词库已接通\tqing yan ce shi\t10000\n" + extraCandidates)
        .write(to: fixture, atomically: true, encoding: .utf8)
      settings.dictionaries = [try QingTypeContent.importDictionary(from: fixture, into: directory)]
      settings.phrases = [QuickPhrase(code: "qingyan", text: "清言输入法")]
      try settings.save(to: directory)
      var traits = RimeTraits.rimeStructInit()
      traits.setCString(Bundle.main.sharedSupportPath!, to: \.shared_data_dir)
      traits.setCString(directory.path, to: \.user_data_dir)
      traits.setCString(directory.path, to: \.log_dir)
      traits.setCString("rime.qingtype.test", to: \.app_name)
      api.setup(&traits)
      api.initialize(nil)
      defer { api.finalize() }
      if api.start_maintenance(true) { api.join_maintenance_thread() }
      var session = api.create_session()
      guard session != 0 else { throw SettingsError.invalid("Could not create Rime session") }
      defer { _ = api.destroy_session(session) }
      var passed: [String] = []
      func expect(_ condition: Bool, _ name: String) throws {
        guard condition else { throw SettingsError.invalid("FAIL: \(name)") }
        passed.append(name)
      }
      func type(_ text: String) { for key in text.utf8 { _ = api.process_key(session, Int32(key), 0) } }
      func candidates() -> [String] {
        var context = RimeContext_stdbool.rimeStructInit()
        guard api.get_context(session, &context) else { return [] }
        defer { _ = api.free_context(&context) }
        guard let values = context.menu.candidates else { return [] }
        return (0..<Int(context.menu.num_candidates)).map { String(cString: values[$0].text) }
      }
      try expect(api.select_schema(session, "luna_pinyin_simp"), "select simplified pinyin")
      type("nihao")
      let words = candidates()
      try expect(words.contains("你好"), "nihao produces 你好")
      try expect(words.count == 5, "configured page size")
      _ = api.process_key(session, Int32(XK_Page_Down), 0)
      try expect(!candidates().isEmpty && candidates() != words, "candidate paging")
      _ = api.process_key(session, Int32(XK_Escape), 0)
      try expect(candidates().isEmpty, "escape clears composition")
      type("nihaoo")
      _ = api.process_key(session, Int32(XK_BackSpace), 0)
      try expect(candidates().contains("你好"), "backspace updates candidates")
      _ = api.process_key(session, Int32(XK_Escape), 0)
      type("nihao")
      let selected = candidates().firstIndex(of: "你好")!
      try expect(api.select_candidate_on_current_page(session, selected), "select candidate")
      var commit = RimeCommit.rimeStructInit()
      try expect(api.get_commit(session, &commit), "receive commit")
      let committed = commit.text.map { String(cString: $0) }
      _ = api.free_commit(&commit)
      try expect(committed == "你好", "commit equals 你好")
      type("qiyan")
      let pageBeforeRead = candidates()
      let expanded = QingTypeCandidateSource.read(api: api, session: session, startingAt: 0, limit: 12)
      try expect(expanded.count > settings.pageSize, "native window receives candidates beyond the first row")
      try expect(Array(expanded.prefix(pageBeforeRead.count)).map(\.text) == pageBeforeRead && candidates() == pageBeforeRead,
                 "reading more candidates preserves the displayed page and order")
      let later = expanded[settings.pageSize + 1]
      try expect(api.highlight_candidate(session, later.index), "native highlight synchronizes a candidate on a later page")
      _ = api.process_key(session, Int32(Character("2").asciiValue!), 0)
      var expandedCommit = RimeCommit.rimeStructInit()
      try expect(api.get_commit(session, &expandedCommit), "numeric selection commits from the expanded page")
      let expandedText = expandedCommit.text.map { String(cString: $0) }
      _ = api.free_commit(&expandedCommit)
      try expect(expandedText == later.text, "expanded-page selection keeps the correct global candidate index")
      type("qingyan")
      try expect(candidates().contains("清言输入法"), "custom phrase is available")
      _ = api.process_key(session, Int32(XK_Escape), 0)
      type("qingyanceshi")
      try expect(candidates().contains("清言词库已接通"), "imported dictionary participates in full pinyin")
      _ = api.process_key(session, Int32(XK_Escape), 0)
      // Compile and exercise the bundled double pinyin schema as well.
      settings.schema = "qingtype_double_pinyin"
      try settings.save(to: directory)
      _ = api.destroy_session(session)
      session = 0
      // Match the input method's reload lifecycle, including clearing cached schemas.
      api.finalize()
      api.initialize(nil)
      if api.start_maintenance(true) { api.join_maintenance_thread() }
      session = api.create_session()
      try expect(api.select_schema(session, "qingtype_double_pinyin"), "select Xiaohe double pinyin")
      type("nihc")
      try expect(candidates().contains("你好"), "nihc produces 你好 in Xiaohe")
      _ = api.process_key(session, Int32(XK_Escape), 0)
      type("qkyjceui")
      try expect(candidates().contains("清言词库已接通"), "imported dictionary participates in Xiaohe")
      let report: [String: Any] = ["result": "passed", "checks": passed, "candidates": words,
                                  "userDirectoryIsolated": true]
      print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
      return true
    } catch {
      fputs("\(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }

  static func showExpandedPreview() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let panel = QingTypeExpandedCandidates()
    let words = CommandLine.arguments.contains("--sample-long")
      ? ["发信魔性了吗", "发信模型了吗", "发信魔性了嘛", "发信模型了嘛", "发", "发信", "法", "发薪", "罚", "伐", "乏", "阀", "阀芯", "珐", "発", "髮", "筏", "砝", "垡", "發", "廢", "撥", "髪", "罰", "眨", "閥", "泛", "凡", "烦", "翻", "繁", "帆"]
      : ["你好", "妳好", "逆号", "拟好", "你", "拟", "尼", "呢", "妮", "倪", "泥", "霓", "昵", "腻", "匿", "铌", "怩", "睨", "溺", "鲵", "旎", "祢", "猊", "倪", "麑", "薿", "輗", "蜺", "伲", "坭", "你们", "拟定", "逆向", "泥土", "你好啊", "你好呀"]
    let candidates = words.enumerated().map { QingTypeCandidate(index: $0.offset, text: $0.element) }
    panel.onPick = { index in
      print("Selected candidate index: \(index)")
      fflush(stdout)
      if !CommandLine.arguments.contains("--keep-open") { app.terminate(nil) }
    }
    panel.onToggle = { print("Collapsed expanded candidate preview"); app.terminate(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      let screen = NSScreen.main!.visibleFrame
      let anchor = NSRect(x: screen.midX - 200, y: screen.midY + 100, width: 400, height: 28)
      panel.present(candidates: candidates, highlighted: 0, caretRect: anchor, fontSize: 16, pageSize: 7, expanded: true)
      if let flag = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.count > flag + 1 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
          }
          app.terminate(nil)
        }
      }
    }
    withExtendedLifetime(panel) { app.run() }
  }

  static func showSystemPreview() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let panel = QingTypeCandidatePresenter(showsWindow: !CommandLine.arguments.contains("--capture"))
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      var settings = (try? QingTypeSettings.load()) ?? QingTypeSettings()
      if let flag = CommandLine.arguments.firstIndex(of: "--preview-font"), CommandLine.arguments.count > flag + 1,
         let size = Int(CommandLine.arguments[flag + 1]), (12...32).contains(size) { settings.fontSize = size }
      let words: [String]
      if CommandLine.arguments.contains("--sample-native-long") {
        words = ["你带大舅爱戴是大舅爱大舅爱的", "你带的", "你", "你好", "妳好", "逆号", "拟好", "尼"]
      } else if CommandLine.arguments.contains("--sample-ni") {
        words = ["你", "拟", "尼", "泥", "呢", "妳", "妮", "倪", "霓", "昵", "腻", "匿", "铌"]
      } else { words = ["你好", "拟好", "你", "呢", "泥", "妳", "倪", "霓", "昵", "腻", "匿", "铌"] }
      panel.update(candidates: words.enumerated().map { QingTypeCandidate(index: $0.offset, text: $0.element) },
                   highlighted: 0, settings: settings,
                   caretRect: NSRect(x: NSScreen.main!.frame.midX - 150, y: NSScreen.main!.frame.midY, width: 1, height: 24))
      if let flag = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.count > flag + 1 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
          if let view = panel.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
          }
          panel.hide()
          app.terminate(nil)
        }
      }
    }
    if !CommandLine.arguments.contains("--keep-open") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 12) { panel.hide(); app.terminate(nil) }
    }
    withExtendedLifetime(panel) { app.run() }
  }

  static func showPreview() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = SquirrelApplicationDelegate()
    app.delegate = delegate
    try? QingTypeSettings.ensureInitialConfiguration()
    guard delegate.startRime(fullCheck: false) else { return }
    delegate.rimeAPI.join_maintenance_thread()
    delegate.loadSettings()
    // Application launch creates the panel, so present it after launch finishes.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      delegate.loadSettings()
      guard let panel = delegate.panel else { return }
      let inline = (try? QingTypeSettings.load().inlinePreedit) ?? true
      panel.position = NSRect(x: NSScreen.main!.frame.midX - 100, y: NSScreen.main!.frame.midY, width: 1, height: 24)
      panel.update(preedit: inline ? "" : "ni hao", selRange: NSRange(location: 0, length: 0), caretPos: inline ? 0 : 6,
                   candidates: ["你好", "拟好", "你", "呢", "泥"], comments: Array(repeating: "", count: 5),
                   labels: ["1", "2", "3", "4", "5"], highlighted: 0, page: 0, lastPage: false, update: true)
      if let flag = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.count > flag + 1 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(
              to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
          }
          app.terminate(nil)
        }
      }
    }
    withExtendedLifetime(delegate) { app.run() }
  }
}
