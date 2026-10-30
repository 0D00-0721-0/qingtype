import AppKit
import QuartzCore

private enum CandidateColors {
  static func background(for appearance: NSAppearance) -> NSColor {
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return NSColor(srgbRed: dark ? 0.17 : 242.0 / 255,
                   green: dark ? 0.17 : 242.0 / 255,
                   blue: dark ? 0.17 : 242.0 / 255, alpha: 1)
  }
}

// Calibrated against the supplied 2x Apple Pinyin reference: a 29 pt capsule,
// 16 pt candidate type, and the first word aligned with the marked-text origin.
enum QingTypeCandidateMetrics {
  static let leading: CGFloat = 1
  static let verticalInset: CGFloat = 0.5
  static let textInset: CGFloat = 14
  static let anchorOffset: CGFloat = 16
  static let caretGap: CGFloat = 6
  static let accessoryWidth: CGFloat = 26
  static let chromeWidth = leading * 2 + accessoryWidth
  static func nativeWidth(pointSize: CGFloat) -> CGFloat {
    max(360, 6 * (2 * pointSize + 29.5) + chromeWidth)
  }
}

// A configured page size is an upper bound. Apple Pinyin keeps long phrases
// intact and displays fewer choices, rather than shrinking every cell to fit.
private struct CollapsedCandidateLayout {
  var start = 0
  var candidates: [QingTypeCandidate] = []
  var widths: [CGFloat] = []
  var width: CGFloat = 0

  init(candidates: [QingTypeCandidate], highlighted: Int, pointSize: CGFloat, pageSize: Int, screenWidth: CGFloat) {
    let chrome = QingTypeCandidateMetrics.chromeWidth
    let natural = candidates.map { max(36, ceil(($0.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: pointSize)]).width) + 25) }
    let selected = candidates.firstIndex { $0.index == highlighted } ?? 0
    var cursor = 0
    while cursor < candidates.count {
      // A single phrase wider than the usual capsule can use more of the
      // screen. It must never be forced into the old 180-point cell cap.
      let limit = min(screenWidth, max(QingTypeCandidateMetrics.nativeWidth(pointSize: pointSize), natural[cursor] + chrome))
      var end = cursor
      var total = chrome
      while end < candidates.count && end - cursor < pageSize {
        let cell = min(natural[end], max(0, limit - chrome))
        if end > cursor && total + cell > limit { break }
        total += cell
        end += 1
      }
      if selected < end {
        start = cursor
        self.candidates = Array(candidates[cursor..<end])
        widths = Array(natural[cursor..<end]).map { min($0, max(0, limit - chrome)) }
        width = end < min(candidates.count, cursor + pageSize) ? limit : total
        return
      }
      cursor = end
    }
  }
}

// The native expanded panel is a six-column grid. Long candidates occupy more
// than one column, so a first row may contain three complete phrases, not six
// truncated cells. Its width is independent of the collapsed page's word lengths.
private struct ExpandedCandidateLayout {
  struct Item {
    var frame: NSRect
    var row: Int
  }
  var width: CGFloat
  var items: [Item] = []
  var headerCount: Int { items.prefix { $0.row == 0 }.count }
  var bodyRows: Int { items.last?.row ?? 0 }

  init(candidates: [QingTypeCandidate], pointSize: CGFloat, rowHeight: CGFloat, maxWidth: CGFloat) {
    width = min(maxWidth, QingTypeCandidateMetrics.nativeWidth(pointSize: pointSize))
    // Half-point boundaries are exact in binary and avoid fractional-metric
    // overlap with the chevron while matching the 2x reference's column spacing.
    let cellWidth = floor((width - QingTypeCandidateMetrics.chromeWidth) / 6 * 2) / 2
    var row = 0
    var column = 0
    for candidate in candidates {
      let textWidth = (candidate.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: pointSize)]).width
      let span = min(6, max(1, Int(ceil((textWidth + 25) / max(1, cellWidth)))))
      if column + span > 6 { row += 1; column = 0 }
      items.append(Item(frame: NSRect(x: QingTypeCandidateMetrics.leading + CGFloat(column) * cellWidth,
                                     y: CGFloat(row) * rowHeight, width: CGFloat(span) * cellWidth, height: rowHeight), row: row))
      column += span
    }
  }
}

// IMKTextInput's line rectangle and NSWindow frames both use Cocoa screen
// coordinates. Never combine an IMKCandidates frame with a second window.
enum QingTypeCandidatePlacement {
  static func isUsable(_ rect: NSRect) -> Bool {
    [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.height > 0 && rect.width >= 0
  }

  static func frame(size: NSSize, caret: NSRect, screen: NSRect, preferAbove: Bool = false) -> NSRect {
    let width = min(size.width, screen.width)
    let height = min(size.height, screen.height)
    let below = caret.minY - QingTypeCandidateMetrics.caretGap - height
    let above = caret.maxY + QingTypeCandidateMetrics.caretGap
    let y = !preferAbove && below >= screen.minY ? below : above
    return NSRect(x: min(max(caret.minX - QingTypeCandidateMetrics.anchorOffset, screen.minX), screen.maxX - width),
                  y: min(max(y, screen.minY), screen.maxY - height), width: width, height: height)
  }
}

private class CandidateContentView: NSView {
  override var isFlipped: Bool { true }
  override var allowsVibrancy: Bool { false }
}

private final class CandidateBackdrop: CandidateContentView {
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    layer?.backgroundColor = CandidateColors.background(for: effectiveAppearance).cgColor
    layer?.borderColor = NSColor.separatorColor.cgColor
  }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private final class CandidateCell: NSButton {
  let candidate: QingTypeCandidate
  let number: Int?
  let pointSize: CGFloat
  var selectedCandidate = false { didSet { needsDisplay = true } }
  var onPick: ((Int) -> Void)?
  var onHover: ((Int) -> Void)?

  init(candidate: QingTypeCandidate, number: Int?, pointSize: CGFloat) {
    self.candidate = candidate
    self.number = number
    self.pointSize = pointSize
    super.init(frame: .zero)
    title = candidate.text
    toolTip = candidate.text
    isBordered = false
    refusesFirstResponder = true
    setButtonType(.momentaryPushIn)
    target = self
    action = #selector(pick)
    setAccessibilityLabel(number.map { "\($0) \(candidate.text)" } ?? candidate.text)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var isFlipped: Bool { true }
  override var allowsVibrancy: Bool { false }
  override var acceptsFirstResponder: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    // Only a real mouse movement changes selection; opening the window under
    // a stationary pointer must not select a different candidate.
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
  }
  override func mouseMoved(with event: NSEvent) { onHover?(candidate.index) }
  @objc private func pick() { onPick?(candidate.index) }

  override func draw(_ dirtyRect: NSRect) {
    if selectedCandidate {
      NSColor.controlAccentColor.setFill()
      let pill = NSRect(x: 1, y: 2, width: bounds.width - 4, height: bounds.height - 4)
      NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
    }
    if let number {
      let label = NSAttributedString(string: "\(number)", attributes: [
        .font: NSFont.systemFont(ofSize: max(8, pointSize * 0.46)),
        .foregroundColor: selectedCandidate ? NSColor.white : .secondaryLabelColor
      ])
      label.draw(at: NSPoint(x: 4, y: (bounds.height - label.size().height) / 2))
    }
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    let text = NSAttributedString(string: candidate.text, attributes: [
      .font: NSFont.systemFont(ofSize: pointSize),
      .foregroundColor: selectedCandidate ? NSColor.white : .labelColor,
      .paragraphStyle: style
    ])
    text.draw(in: NSRect(x: QingTypeCandidateMetrics.textInset, y: (bounds.height - text.size().height) / 2,
                        width: max(0, bounds.width - 18), height: text.size().height))
  }
}

private final class CandidateRowsView: CandidateContentView {
  var rowHeight: CGFloat = 28
  override func draw(_ dirtyRect: NSRect) {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    (dark ? NSColor.white : .black).withAlphaComponent(0.07).setStroke()
    let lines = NSBezierPath()
    var y = rowHeight
    while y < bounds.height {
      lines.move(to: NSPoint(x: 0, y: y))
      lines.line(to: NSPoint(x: bounds.width, y: y))
      y += rowHeight
    }
    lines.lineWidth = 0.5
    lines.stroke()
  }
}

// One panel owns the row, chevron, and expanded grid. It never activates the
// input-method application or becomes the client's first responder.
final class QingTypeExpandedCandidates: NSPanel {
  var onPick: ((Int) -> Void)?
  var onHighlight: ((Int) -> Void)?
  var onToggle: (() -> Void)?
  private var candidates: [QingTypeCandidate] = []
  private var cells: [CandidateCell] = []
  private let backdrop = CandidateBackdrop(frame: .zero)
  private let scroll = NSScrollView()
  private var disclosureButton: NSButton?
  private let reduceMotion: () -> Bool
  private var transitionID = 0
  private(set) var isTransitioning = false
  private var numberedCandidates: [QingTypeCandidate] = []
  private var expanded = false
  private var placedAbove = false
  private var vertical = false
  private var fontSize = 18
  private var pageSize = 7
  private var caretRect = NSRect.zero
  private var renderedCandidates: [QingTypeCandidate] = []
  private var renderedStyle = ""
  private var expandedLayout: ExpandedCandidateLayout?
  private let visibleScreen: (NSRect) -> NSRect
  private(set) var columns = 6
  private(set) var selectedIndex = 0
  private(set) var hasMoreCandidates = false
  private(set) var toggleFrame = NSRect.zero
  private(set) var cellFrames: [NSRect] = []
  private(set) var allCellFrames: [NSRect] = []
  var scrollOrigin: NSPoint { scroll.contentView.bounds.origin }
  var bodyIdentity: ObjectIdentifier? { scroll.documentView.map(ObjectIdentifier.init) }

  init(visibleScreen: ((NSRect) -> NSRect)? = nil, reduceMotion: (() -> Bool)? = nil) {
    self.reduceMotion = reduceMotion ?? { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    self.visibleScreen = visibleScreen ?? { caret in
      (NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main)?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    title = "清言候选"
    level = .popUpMenu
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    acceptsMouseMovedEvents = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    backdrop.wantsLayer = true
    backdrop.layer?.borderWidth = 0.5
    backdrop.layer?.masksToBounds = true
    backdrop.layer?.cornerCurve = .continuous
    contentView = backdrop
    if let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "展开候选") {
      let button = NSButton(image: image, target: self, action: #selector(toggle))
      button.isBordered = false
      button.refusesFirstResponder = true
      button.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
      button.contentTintColor = .secondaryLabelColor
      disclosureButton = button
    }
  }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  func present(candidates: [QingTypeCandidate], highlighted: Int, caretRect: NSRect,
               fontSize: Int, pageSize: Int, expanded: Bool, vertical: Bool = false, show: Bool = true,
               animate: Bool = false) {
    guard !candidates.isEmpty else { orderOut(nil); return }
    let presentationChanged = self.expanded != expanded
    let sameContext = self.candidates == candidates && self.caretRect == caretRect &&
      self.fontSize == fontSize && self.pageSize == max(1, pageSize) && self.vertical == vertical
    let selectionChanged = self.selectedIndex != highlighted
    self.candidates = candidates
    self.selectedIndex = highlighted
    self.caretRect = caretRect
    self.fontSize = fontSize
    self.pageSize = max(1, pageSize)
    self.expanded = expanded
    self.vertical = vertical
    let pointSize = CGFloat(fontSize)
    let rowHeight = max(28, pointSize + 10)
    let screen = visibleScreen(caretRect)
    let maxWidth = min(600, screen.width)
    let offset = candidates.firstIndex { $0.index == highlighted } ?? 0
    let compact = CollapsedCandidateLayout(candidates: candidates, highlighted: highlighted, pointSize: pointSize,
                                           pageSize: self.pageSize, screenWidth: screen.width)
    let pageStart = expanded ? 0 : vertical ? offset / self.pageSize * self.pageSize : compact.start
    let row = vertical ? Array(candidates.dropFirst(pageStart).prefix(self.pageSize)) : compact.candidates
    let widths = vertical ? row.map { max(36, ($0.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: pointSize)]).width + 25) } : compact.widths
    // Reserve the chevron's entire hit region, even for the last candidate.
    let chromeWidth = QingTypeCandidateMetrics.chromeWidth
    var width = compact.width
    if vertical { width = min(maxWidth, max(160, (widths.max() ?? 100) + chromeWidth)) }
    let grid = expanded ? ExpandedCandidateLayout(candidates: candidates, pointSize: pointSize, rowHeight: rowHeight, maxWidth: maxWidth) : nil
    expandedLayout = grid
    if let grid { width = grid.width }
    columns = expanded ? 6 : (vertical ? 1 : row.count)
    let headerCount = grid?.headerCount ?? row.count
    hasMoreCandidates = candidates.count > headerCount
    let bodyRows = grid?.bodyRows ?? 0
    let bodyHeight = min(CGFloat(min(4, bodyRows)) * rowHeight, max(0, screen.height - rowHeight - 12))
    let inset = QingTypeCandidateMetrics.verticalInset
    let height = (expanded ? rowHeight + bodyHeight : (vertical ? rowHeight * CGFloat(row.count) : rowHeight)) + inset * 2
    // Once expansion needs the upper side, keep that side while the input
    // context is unchanged. A shorter capsule must not jump below the caret
    // again on collapse or an otherwise identical refresh.
    let frame = QingTypeCandidatePlacement.frame(size: NSSize(width: width, height: height), caret: caretRect,
                                                screen: screen, preferAbove: sameContext && isVisible && placedAbove)
    placedAbove = frame.minY >= caretRect.maxY
    // An explicit disclosure also animates when its destination is above the
    // caret. Typing and caret/app changes still settle immediately.
    let willAnimate = animate && presentationChanged && sameContext && show && isVisible && !reduceMotion()
    stopTransition()
    if !willAnimate && self.frame != frame { setFrame(frame, display: false) }
    appearance = NSApp.effectiveAppearance
    setAccessibilityLabel(expanded ? "展开的清言候选" : "清言候选")
    let style = "\(fontSize):\(pageSize):\(expanded):\(vertical):\(pageStart):\(width):\(height)"
    let rebuild = renderedCandidates != candidates || renderedStyle != style
    var movingViews: [(NSView, NSRect)] = []
    let duration = expanded ? 0.18 : 0.14
    if rebuild {
      renderedCandidates = candidates
      renderedStyle = style
      let oldCells = cells
      // Keep one surface throughout the transition. New rows are revealed by
      // clipping as the window grows; glyphs are never stretched as a bitmap.
      backdrop.subviews.filter { $0 !== scroll && $0 !== disclosureButton }.forEach { $0.removeFromSuperview() }
      let radius = expanded ? 16 : (vertical ? 12 : height / 2)
      let previousRadius = backdrop.layer?.presentation()?.cornerRadius ?? backdrop.layer?.cornerRadius ?? radius
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      backdrop.layer?.cornerRadius = radius
      CATransaction.commit()
      if willAnimate {
        let rounding = CABasicAnimation(keyPath: "cornerRadius")
        rounding.fromValue = previousRadius
        rounding.toValue = radius
        rounding.duration = duration
        rounding.timingFunction = CAMediaTimingFunction(name: .easeOut)
        backdrop.layer?.add(rounding, forKey: "disclosureRadius")
      }
      let header = CandidateRowsView(frame: NSRect(x: 0, y: inset, width: width, height: expanded ? rowHeight : height - inset * 2))
      header.rowHeight = rowHeight
      backdrop.addSubview(header)
      let body = CandidateRowsView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(bodyRows) * rowHeight))
      body.rowHeight = rowHeight
      scroll.drawsBackground = false
      scroll.borderType = .noBorder
      scroll.hasVerticalScroller = true
      scroll.autohidesScrollers = true
      scroll.scrollerStyle = .overlay
      if expanded {
        scroll.frame = NSRect(x: 0, y: rowHeight + inset, width: width, height: bodyHeight)
        scroll.documentView = body
        backdrop.addSubview(scroll)
      } else if !willAnimate {
        scroll.removeFromSuperview()
        scroll.documentView = nil
      }
      cells = []
      cellFrames = []
      allCellFrames = []
      let displayed = expanded ? candidates : row
      numberedCandidates = Array(displayed.prefix(headerCount))
      let leading = QingTypeCandidateMetrics.leading
      var x = leading
      for (index, candidate) in displayed.enumerated() {
        let inHeader = !expanded || index < headerCount
        let number = inHeader ? index + 1 : nil
        let reused = willAnimate && inHeader ? oldCells.first {
          $0.candidate == candidate && $0.number == number && $0.pointSize == pointSize
        } : nil
        let cell = reused ?? CandidateCell(candidate: candidate, number: number, pointSize: pointSize)
        let previousFrame = cell.frame
        if let grid {
          cell.frame = grid.items[index].frame.offsetBy(dx: 0, dy: inHeader ? 0 : -rowHeight)
        } else if vertical {
          cell.frame = NSRect(x: leading, y: CGFloat(index) * rowHeight, width: width - chromeWidth, height: rowHeight)
        } else {
          cell.frame = NSRect(x: x, y: 0, width: widths[index], height: rowHeight)
          x += widths[index]
        }
        let targetFrame = cell.frame
        if reused != nil {
          cell.frame = previousFrame
          movingViews.append((cell, targetFrame))
        }
        cell.onPick = { [weak self, weak cell] index in
          guard let self, let cell, self.cells.contains(where: { $0 === cell }) else { return }
          self.onPick?(index)
        }
        cell.onHover = { [weak self, weak cell] index in
          guard let self, let cell, self.cells.contains(where: { $0 === cell }) else { return }
          self.highlight(index, scrollToSelection: false)
        }
        (inHeader ? header : body).addSubview(cell)
        cells.append(cell)
        allCellFrames.append(targetFrame.offsetBy(dx: 0, dy: inset + (inHeader ? 0 : rowHeight)))
        if inHeader { cellFrames.append(targetFrame.offsetBy(dx: 0, dy: inset)) }
      }
      toggleFrame = .zero
      if let toggle = disclosureButton, expanded || hasMoreCandidates {
        toggle.toolTip = expanded ? "收起候选（Esc）" : "展开候选（↓）"
        toggle.setAccessibilityLabel(expanded ? "收起候选" : "展开候选")
        toggleFrame = NSRect(x: width - leading - QingTypeCandidateMetrics.accessoryWidth, y: inset,
                             width: QingTypeCandidateMetrics.accessoryWidth, height: rowHeight)
        if willAnimate { movingViews.append((toggle, toggleFrame)) }
        else { toggle.frame = toggleFrame; toggle.frameCenterRotation = expanded ? 180 : 0 }
        if !expanded && !vertical {
          let divider = NSBox(frame: NSRect(x: toggleFrame.minX, y: 4.5, width: 0.5, height: max(0, height - 9)))
          divider.boxType = .separator
          backdrop.addSubview(divider)
        }
        backdrop.addSubview(toggle)
      } else { disclosureButton?.removeFromSuperview() }
    }
    updateHighlight(scrollToSelection: rebuild || selectionChanged)
    if willAnimate {
      isTransitioning = true
      let id = transitionID
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.animator().setFrame(frame, display: true)
        for (view, target) in movingViews { view.animator().frame = target }
        self.disclosureButton?.animator().frameCenterRotation = expanded ? 180 : 0
      }, completionHandler: { [weak self] in
        guard let self, self.transitionID == id else { return }
        self.isTransitioning = false
        if !self.expanded {
          self.scroll.removeFromSuperview()
          self.scroll.documentView = nil
        }
      })
    }
    if show && !isVisible { orderFrontRegardless() }
  }

  private func stopTransition() {
    transitionID += 1
    guard isTransitioning else { return }
    isTransitioning = false
    // AppKit documents a zero-duration animator assignment as cancellation;
    // a later completion must never remove a newer session's rows.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      self.animator().setFrame(self.frame, display: false)
      for cell in self.cells { cell.animator().frame = cell.frame }
      if let toggle = self.disclosureButton {
        toggle.animator().frame = toggle.frame
        toggle.animator().frameCenterRotation = toggle.frameCenterRotation
      }
    }
    backdrop.layer?.removeAnimation(forKey: "disclosureRadius")
  }

  override func orderOut(_ sender: Any?) {
    stopTransition()
    super.orderOut(sender)
  }

  @objc private func toggle() { onToggle?() }

  private func updateHighlight(scrollToSelection: Bool) {
    cells.forEach { $0.selectedCandidate = $0.candidate.index == selectedIndex }
    if scrollToSelection, let cell = cells.first(where: { $0.candidate.index == selectedIndex }), cell.superview === scroll.documentView {
      cell.scrollToVisible(cell.bounds)
    }
  }

  func highlight(_ index: Int, scrollToSelection: Bool = true) {
    guard candidates.contains(where: { $0.index == index }), index != selectedIndex else { return }
    selectedIndex = index
    // Selection stays in the UI until commit; hovering must not change Rime's
    // page and cause a new snapshot to start halfway through the grid.
    if !expanded && !cells.contains(where: { $0.candidate.index == index }) {
      present(candidates: candidates, highlighted: index, caretRect: caretRect, fontSize: fontSize,
              pageSize: pageSize, expanded: false, vertical: vertical, show: isVisible)
    } else { updateHighlight(scrollToSelection: scrollToSelection) }
    onHighlight?(index)
  }

  func move(horizontal: Int, vertical: Int) {
    guard let offset = candidates.firstIndex(where: { $0.index == selectedIndex }) else { return }
    if let grid = expandedLayout, vertical != 0 {
      let current = grid.items[offset]
      let row = current.row + vertical
      let options = grid.items.indices.filter { grid.items[$0].row == row }
      if let next = options.min(by: { abs(grid.items[$0].frame.midX - current.frame.midX) < abs(grid.items[$1].frame.midX - current.frame.midX) }) {
        highlight(candidates[next].index)
      }
      return
    }
    let next = min(candidates.count - 1, max(0, offset + horizontal + vertical * (self.vertical ? 1 : max(1, columns))))
    highlight(candidates[next].index)
  }
  func pickSelected() {
    guard candidates.contains(where: { $0.index == selectedIndex }) else { return }
    onPick?(selectedIndex)
  }
  func pickNumber(_ number: Int) -> Bool {
    guard number > 0, number <= numberedCandidates.count else { return false }
    onPick?(numberedCandidates[number - 1].index)
    return true
  }
}
