import AppKit

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
    width = min(maxWidth, max(360, 6 * (2 * pointSize + 29.5) + QingTypeCandidateMetrics.chromeWidth))
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

  static func frame(size: NSSize, caret: NSRect, screen: NSRect) -> NSRect {
    let width = min(size.width, screen.width)
    let height = min(size.height, screen.height)
    let below = caret.minY - QingTypeCandidateMetrics.caretGap - height
    let above = caret.maxY + QingTypeCandidateMetrics.caretGap
    let y = below >= screen.minY ? below : above
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
  private let scroll = NSScrollView()
  private var numberedCandidates: [QingTypeCandidate] = []
  private var expanded = false
  private var vertical = false
  private var fontSize = 18
  private var pageSize = 7
  private var caretRect = NSRect.zero
  private var renderedCandidates: [QingTypeCandidate] = []
  private var renderedStyle = ""
  private var expandedLayout: ExpandedCandidateLayout?
  private(set) var columns = 6
  private(set) var selectedIndex = 0
  private(set) var hasMoreCandidates = false
  private(set) var toggleFrame = NSRect.zero
  private(set) var cellFrames: [NSRect] = []
  private(set) var allCellFrames: [NSRect] = []
  var scrollOrigin: NSPoint { scroll.contentView.bounds.origin }
  var bodyIdentity: ObjectIdentifier? { scroll.documentView.map(ObjectIdentifier.init) }

  init() {
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
  }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  func present(candidates: [QingTypeCandidate], highlighted: Int, caretRect: NSRect,
               fontSize: Int, pageSize: Int, expanded: Bool, vertical: Bool = false, show: Bool = true) {
    guard !candidates.isEmpty else { orderOut(nil); return }
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
    let screen = (NSScreen.screens.first { $0.frame.intersects(caretRect) } ?? NSScreen.main)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let maxWidth = min(600, screen.width)
    let offset = candidates.firstIndex { $0.index == highlighted } ?? 0
    let pageStart = expanded ? 0 : offset / self.pageSize * self.pageSize
    let row = Array(candidates.dropFirst(pageStart).prefix(self.pageSize))
    var widths = row.map { min(180, max(36, ($0.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: pointSize)]).width + 25)) }
    // Reserve the chevron's entire hit region, even for the last candidate.
    let chromeWidth = QingTypeCandidateMetrics.chromeWidth
    var width = min(maxWidth, widths.reduce(chromeWidth, +))
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
    let frame = QingTypeCandidatePlacement.frame(size: NSSize(width: width, height: height), caret: caretRect, screen: screen)
    if self.frame != frame { setFrame(frame, display: false) }
    appearance = NSApp.effectiveAppearance
    setAccessibilityLabel(expanded ? "展开的清言候选" : "清言候选")
    let style = "\(fontSize):\(pageSize):\(expanded):\(vertical):\(pageStart):\(width):\(height)"
    let rebuild = renderedCandidates != candidates || renderedStyle != style
    if rebuild {
      renderedCandidates = candidates
      renderedStyle = style
      let background = CandidateBackdrop(frame: NSRect(origin: .zero, size: frame.size))
      background.wantsLayer = true
      background.layer?.cornerRadius = expanded ? 16 : (vertical ? 12 : height / 2)
      background.layer?.borderWidth = 0.5
      background.layer?.masksToBounds = true
      contentView = background
      let header = CandidateRowsView(frame: NSRect(x: 0, y: inset, width: width, height: expanded ? rowHeight : height - inset * 2))
      header.rowHeight = rowHeight
      background.addSubview(header)
      let body = CandidateRowsView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(bodyRows) * rowHeight))
      body.rowHeight = rowHeight
      scroll.frame = NSRect(x: 0, y: rowHeight + inset, width: width, height: bodyHeight)
      scroll.drawsBackground = false
      scroll.borderType = .noBorder
      scroll.hasVerticalScroller = true
      scroll.autohidesScrollers = true
      scroll.scrollerStyle = .overlay
      scroll.documentView = body
      if expanded { background.addSubview(scroll) }
      cells = []
      cellFrames = []
      allCellFrames = []
      let displayed = expanded ? candidates : row
      numberedCandidates = Array(displayed.prefix(headerCount))
      if !expanded && !vertical {
        let available = width - chromeWidth
        let total = widths.reduce(0, +)
        if total > available { widths = widths.map { $0 * available / total } }
      }
      let leading = QingTypeCandidateMetrics.leading
      var x = leading
      for (index, candidate) in displayed.enumerated() {
        let inHeader = !expanded || index < headerCount
        let cell = CandidateCell(candidate: candidate, number: inHeader ? index + 1 : nil, pointSize: pointSize)
        if let grid {
          cell.frame = grid.items[index].frame.offsetBy(dx: 0, dy: inHeader ? 0 : -rowHeight)
        } else if vertical {
          cell.frame = NSRect(x: leading, y: CGFloat(index) * rowHeight, width: width - chromeWidth, height: rowHeight)
        } else {
          cell.frame = NSRect(x: x, y: 0, width: widths[index], height: rowHeight)
          x += widths[index]
        }
        cell.onPick = { [weak self] index in self?.onPick?(index) }
        cell.onHover = { [weak self] index in self?.highlight(index, scrollToSelection: false) }
        (inHeader ? header : body).addSubview(cell)
        cells.append(cell)
        allCellFrames.append(cell.frame.offsetBy(dx: 0, dy: inset + (inHeader ? 0 : rowHeight)))
        if inHeader { cellFrames.append(cell.frame.offsetBy(dx: 0, dy: inset)) }
      }
      toggleFrame = .zero
      if expanded || hasMoreCandidates {
        let toggle = NSButton(image: NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: expanded ? "收起候选" : "展开候选")!, target: self, action: #selector(toggle))
        toggle.isBordered = false
        toggle.refusesFirstResponder = true
        toggle.image = toggle.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        toggle.contentTintColor = .secondaryLabelColor
        toggle.toolTip = expanded ? "收起候选（Esc）" : "展开候选（↓）"
        toggle.setAccessibilityLabel(expanded ? "收起候选" : "展开候选")
        toggleFrame = NSRect(x: width - leading - QingTypeCandidateMetrics.accessoryWidth, y: inset,
                             width: QingTypeCandidateMetrics.accessoryWidth, height: rowHeight)
        toggle.frame = toggleFrame
        if !expanded && !vertical {
          let divider = NSBox(frame: NSRect(x: toggleFrame.minX, y: 4.5, width: 0.5, height: max(0, height - 9)))
          divider.boxType = .separator
          background.addSubview(divider)
        }
        background.addSubview(toggle)
      }
    }
    updateHighlight(scrollToSelection: rebuild || selectionChanged)
    if show && !isVisible { orderFrontRegardless() }
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
