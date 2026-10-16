import AppKit
import SwiftUI

/// Owns the diff table: its rows, their heights, and scrolling that never jumps on its own.
///
/// It reads the layer from the model and calls the model for every change. It keeps only view
/// state itself: what you collapsed, expanded or selected, and which composers are open.
@MainActor
final class DiffPaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: ReviewWindowModel
    let windowState: ReviewWindowState
    let scrollView = NSScrollView()
    let tableView = DiffTableView()
    let metrics = CodeMetrics()

    private(set) var rows: [DiffRow] = []
    private(set) var heights: [CGFloat] = []
    private(set) var indexByID: [RowID: Int] = [:]
    private(set) var fileHeaderRows: [Int] = []
    private(set) var shownLayerID: Int?
    private var shownLayer: LayerContent?
    private var prepared = PreparedLayer(files: [])
    private var viewStates: [Int: LayerViewState] = [:]
    private var widthUsedForHeights: CGFloat = 0
    private var refreshIsScheduled = false

    private let threadMeasurer = NSHostingController(rootView: ThreadRowRoot.placeholder)
    private let overviewMeasurer = NSHostingController(rootView: LayerOverviewCard(content: .placeholder))
    private var threadHeights: [ThreadHeightKey: (content: ThreadRowContent, height: CGFloat)] = [:]
    private var overviewHeight: (content: OverviewContent, width: Int, height: CGFloat)?
    private var tokenCache: [RowID: [SyntaxToken]] = [:]

    var lineSelection: LineSelection?
    var textSelection: TextSelection?
    var dragMode = DragMode.none
    private(set) var hoveredRowID: RowID?
    private(set) var focusedThreadID: Int?
    var liveDrafts: [ComposerKey: String] = [:]
    var draftSaves: [ComposerKey: Task<Void, Never>] = [:]
    /// Every single-letter shortcut the table acted on, for the self-test.
    var shortcutsFired: [Character] = []
    private(set) var lastRewrapMilliseconds = 0.0

    init(model: ReviewWindowModel, windowState: ReviewWindowState) {
        self.model = model
        self.windowState = windowState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("DiffPaneController is built in code") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.allowsTypeSelect = false
        tableView.allowsEmptySelection = true
        tableView.usesAutomaticRowHeights = false
        tableView.rowSizeStyle = .custom
        tableView.floatsGroupRows = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = DiffColors.paneBackground
        tableView.pane = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Diff")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = DiffColors.paneBackground
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        view = scrollView
    }

    /// Picks up the model's current layer. Called after every model change the window sees.
    func scheduleRefresh() {
        guard !refreshIsScheduled else { return }
        refreshIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshIsScheduled = false
                self.refreshFromModel()
            }
        }
    }

    func refreshFromModel() {
        guard isViewLoaded else { return }
        guard let layer = model.layer else {
            if shownLayerID != nil { clear() }
            return
        }
        if layer.layerID != shownLayerID {
            show(layer)
            return
        }
        var gutterChanged = false
        if layer.files != shownLayer?.files {
            prepared = PreparedLayer(files: layer.files)
            tokenCache.removeAll()
            gutterChanged = metrics.fitNumbers(upTo: prepared.largestLineNumber)
        }
        shownLayer = layer
        rebuild()
        if gutterChanged { recomputeAllHeights() }
    }

    // MARK: Showing a layer

    private func show(_ layer: LayerContent) {
        if let shownLayerID { viewStates[shownLayerID, default: LayerViewState()].savedScroll = topVisibleAnchor() }
        shownLayerID = layer.layerID
        shownLayer = layer
        prepared = PreparedLayer(files: layer.files)
        metrics.fitNumbers(upTo: prepared.largestLineNumber)
        lineSelection = nil
        textSelection = nil
        hoveredRowID = nil
        focusedThreadID = nil
        windowState.focusedThreadID = nil
        tokenCache.removeAll()
        threadHeights.removeAll()
        widthUsedForHeights = tableView.bounds.width

        rows = buildRows()
        heights = rows.map(height(of:))
        reindex()
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        if let saved = viewState.savedScroll, let index = indexByID[saved.row] {
            scroll(toY: tableView.rect(ofRow: index).minY + saved.offset)
        } else {
            scroll(toY: 0)
        }
        updateCurrentFile()
    }

    private func clear() {
        shownLayerID = nil
        shownLayer = nil
        rows = []
        heights = []
        reindex()
        tableView.reloadData()
    }

    var viewState: LayerViewState {
        get { shownLayerID.flatMap { viewStates[$0] } ?? LayerViewState() }
        set { if let shownLayerID { viewStates[shownLayerID] = newValue } }
    }

    private func buildRows() -> [DiffRow] {
        guard let shownLayer else { return [] }
        return DiffRowBuilder(
            prepared: prepared, layer: shownLayer, layerItem: model.selectedLayer, stack: model.selectedStack,
            state: viewState, codeColumnInset: Double(metrics.codeX)).build()
    }

    // MARK: Applying changes

    /// Rebuilds the rows from the model and view state, inserting and removing only what changed.
    ///
    /// Rows are never reloaded wholesale, so an open composer keeps its view and keyboard focus.
    func rebuild() {
        guard shownLayer != nil else { return }
        apply(buildRows())
    }

    private func apply(_ newRows: [DiffRow]) {
        let anchor = topVisibleAnchor()
        let oldRows = rows
        let oldHeights = heights
        var oldByID: [RowID: (row: DiffRow, height: CGFloat)] = [:]
        for (index, row) in oldRows.enumerated() { oldByID[row.id] = (row, oldHeights[index]) }

        rows = newRows
        heights = newRows.map { row in
            if let old = oldByID[row.id], old.row == row { return old.height }
            return height(of: row)
        }
        reindex()

        let oldIDs = oldRows.map(\.id)
        let newIDs = newRows.map(\.id)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        var inserted = IndexSet()
        if oldIDs != newIDs {
            let difference = newIDs.difference(from: oldIDs)
            var removed = IndexSet()
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            tableView.beginUpdates()
            tableView.removeRows(at: removed, withAnimation: [])
            tableView.insertRows(at: inserted, withAnimation: [])
            tableView.endUpdates()
        }
        var resized = IndexSet()
        for (index, row) in newRows.enumerated() where !inserted.contains(index) {
            guard let old = oldByID[row.id], old.row != row else { continue }
            if let view = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) {
                configure(view, for: row)
            }
            if old.height != heights[index] { resized.insert(index) }
        }
        if !resized.isEmpty { tableView.noteHeightOfRows(withIndexesChanged: resized) }
        NSAnimationContext.endGrouping()
        restore(anchor)
        updateCurrentFile()
    }

    /// Changes the height of rows already in the table, keeping the top visible row in place.
    func noteHeightChanges(_ changed: IndexSet) {
        guard !changed.isEmpty else { return }
        let anchor = topVisibleAnchor()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        tableView.noteHeightOfRows(withIndexesChanged: changed)
        NSAnimationContext.endGrouping()
        restore(anchor)
    }

    func setHeight(_ height: CGFloat, ofRow index: Int) {
        heights[index] = height
        noteHeightChanges(IndexSet(integer: index))
    }

    private func reindex() {
        indexByID.removeAll(keepingCapacity: true)
        fileHeaderRows.removeAll(keepingCapacity: true)
        for (index, row) in rows.enumerated() {
            indexByID[row.id] = index
            if row.isFileHeader { fileHeaderRows.append(index) }
        }
    }

    // MARK: Width and heights

    /// The width every height was worked out for. Code rows wrap at this width too, so a row
    /// never draws more lines than its height holds during a live resize.
    var rowWidth: CGFloat { widthUsedForHeights > 1 ? widthUsedForHeights : max(400, tableView.bounds.width) }

    /// Works out every height again after the width changes, keeping the top row in place.
    func widthDidChange() {
        let width = tableView.bounds.width
        guard width > 1, abs(width - widthUsedForHeights) >= 1 else { return }
        widthUsedForHeights = width
        recomputeAllHeights()
    }

    /// Works out every row's height afresh, for a new width or a wider line-number gutter.
    func recomputeAllHeights() {
        let start = ProcessInfo.processInfo.systemUptime
        heights = rows.map(height(of:))
        noteHeightChanges(IndexSet(integersIn: 0..<rows.count))
        redrawVisibleRows()
        lastRewrapMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    func height(of row: DiffRow) -> CGFloat {
        switch row {
        case .overview(let content): measureOverview(content)
        case .fileHeader: FileHeaderView.height
        case .hunkHeader: HunkHeaderView.height
        case .gap: GapRowView.height
        case .code(let code): metrics.height(of: code.displayText, isPlainASCII: code.isPlainASCII, rowWidth: rowWidth)
        case .notice: NoticeRowView.height
        case .bigFile: BigFileRowView.height
        case .thread(let content): measureThread(content)
        case .composer(let content): ComposerRowView.height(forText: draftText(for: content.key), rowWidth: rowWidth, content: content)
        case .footer: FooterRowView.height
        }
    }

    private struct ThreadHeightKey: Hashable {
        var threadID: Int
        var width: Int
    }

    private func measureThread(_ content: ThreadRowContent) -> CGFloat {
        let key = ThreadHeightKey(threadID: content.thread.id, width: Int(rowWidth))
        if let cached = threadHeights[key], cached.content == content { return cached.height }
        threadMeasurer.rootView = ThreadRowRoot(content: content, isFocused: false, actions: ThreadCardActions())
        let size = threadMeasurer.sizeThatFits(in: CGSize(width: rowWidth, height: .greatestFiniteMagnitude))
        let height = ceil(size.height)
        threadHeights[key] = (content, height)
        return height
    }

    private func measureOverview(_ content: OverviewContent) -> CGFloat {
        if let cached = overviewHeight, cached.content == content, cached.width == Int(rowWidth) { return cached.height }
        overviewMeasurer.rootView = LayerOverviewCard(content: content)
        let size = overviewMeasurer.sizeThatFits(in: CGSize(width: rowWidth, height: .greatestFiniteMagnitude))
        let height = ceil(size.height)
        overviewHeight = (content, Int(rowWidth), height)
        return height
    }

    func tokens(for code: CodeRowContent) -> [SyntaxToken] {
        let id = RowID.line(code.path, code.line.oldNumber, code.line.newNumber)
        if let cached = tokenCache[id] { return cached }
        let tokens = SyntaxHighlighter.tokens(in: code.displayText, language: code.language)
        tokenCache[id] = tokens
        return tokens
    }

    // MARK: Table data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        heights.indices.contains(row) ? heights[row] : 1
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].isFileHeader
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let view = tableView.makeView(withIdentifier: DiffRowView.identifier, owner: nil) as? DiffRowView { return view }
        let view = DiffRowView()
        view.identifier = DiffRowView.identifier
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let content = rows[row]
        let view: NSView = switch content {
        case .overview: reuse(Self.overviewIdentifier) { HostingRowView(identifier: Self.overviewIdentifier, rootView: LayerOverviewCard(content: .placeholder)) }
        case .fileHeader: reuse(FileHeaderView.identifier) { FileHeaderView() }
        case .hunkHeader: reuse(HunkHeaderView.identifier) { HunkHeaderView() }
        case .gap: reuse(GapRowView.identifier) { GapRowView() }
        case .code: reuse(CodeRowView.identifier) { CodeRowView() }
        case .notice: reuse(NoticeRowView.identifier) { NoticeRowView() }
        case .bigFile: reuse(BigFileRowView.identifier) { BigFileRowView() }
        case .thread: reuse(Self.threadIdentifier) { HostingRowView(identifier: Self.threadIdentifier, rootView: ThreadRowRoot.placeholder) }
        case .composer: reuse(ComposerRowView.identifier) { ComposerRowView() }
        case .footer: reuse(FooterRowView.identifier) { FooterRowView() }
        }
        configure(view, for: content)
        return view
    }

    static let threadIdentifier = NSUserInterfaceItemIdentifier("thread")
    static let overviewIdentifier = NSUserInterfaceItemIdentifier("overview")

    private func reuse<View: NSView>(_ identifier: NSUserInterfaceItemIdentifier, make: () -> View) -> View {
        if let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? View { return view }
        let view = make()
        view.identifier = identifier
        return view
    }

    func configure(_ view: NSView, for row: DiffRow) {
        switch row {
        case .overview(let content):
            (view as? HostingRowView<LayerOverviewCard>)?.host.rootView = LayerOverviewCard(content: content) { [weak self] in
                self?.openComposer(.draft(.newThread(.layer)))
            }
        case .fileHeader(let content): (view as? FileHeaderView)?.show(content, pane: self)
        case .hunkHeader(let content): (view as? HunkHeaderView)?.show(content, pane: self)
        case .gap(let content): (view as? GapRowView)?.show(content, pane: self)
        case .code(let content): (view as? CodeRowView)?.show(content, pane: self)
        case .notice(let content): (view as? NoticeRowView)?.show(content, pane: self)
        case .bigFile(let content): (view as? BigFileRowView)?.show(content, pane: self)
        case .thread(let content):
            (view as? HostingRowView<ThreadRowRoot>)?.host.rootView = ThreadRowRoot(
                content: content, isFocused: focusedThreadID == content.thread.id, actions: cardActions(for: content.thread.id))
        case .composer(let content): (view as? ComposerRowView)?.show(content, text: draftText(for: content.key), pane: self)
        case .footer: break
        }
    }

    func redrawVisibleRows() {
        let visible = tableView.rows(in: scrollView.contentView.bounds)
        for index in visible.lowerBound..<visible.upperBound {
            tableView.view(atColumn: 0, row: index, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    func redrawVisibleCodeRows() {
        let visible = tableView.rows(in: scrollView.contentView.bounds)
        for index in visible.lowerBound..<visible.upperBound where rows.indices.contains(index) && rows[index].code != nil {
            tableView.view(atColumn: 0, row: index, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    func reconfigureRow(_ id: RowID) {
        guard let index = indexByID[id], let view = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) else { return }
        configure(view, for: rows[index])
    }

    func setHoveredRow(_ id: RowID?) {
        guard id != hoveredRowID else { return }
        let old = hoveredRowID
        hoveredRowID = id
        for rowID in [old, id].compactMap({ $0 }) {
            if let index = indexByID[rowID] { tableView.view(atColumn: 0, row: index, makeIfNecessary: false)?.needsDisplay = true }
        }
    }

    func setFocusedThread(_ id: Int?) {
        guard id != focusedThreadID else { return }
        let old = focusedThreadID
        focusedThreadID = id
        windowState.focusedThreadID = id
        for threadID in [old, id].compactMap({ $0 }) { reconfigureRow(.thread(threadID)) }
    }

    // MARK: Scrolling

    var visibleRect: NSRect { scrollView.contentView.bounds }

    /// The first row whose own frame reaches the top of the viewport.
    ///
    /// `row(at:)` is not used, because it returns the floating file header that covers the top.
    func topVisibleAnchor() -> ScrollAnchor? {
        let visible = visibleRect
        let range = tableView.rows(in: visible)
        guard range.length > 0, rows.indices.contains(range.location) else { return nil }
        return ScrollAnchor(row: rows[range.location].id, offset: visible.minY - tableView.rect(ofRow: range.location).minY)
    }

    private func restore(_ anchor: ScrollAnchor?) {
        guard let anchor, let index = indexByID[anchor.row] else { return }
        tableView.layoutSubtreeIfNeeded()
        scroll(toY: tableView.rect(ofRow: index).minY + anchor.offset)
    }

    func scroll(toY y: CGFloat) {
        let maxY = max(0, tableView.frame.height - visibleRect.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The height of the file header that floats over `row`, so jumps land below it.
    func stickyHeaderHeight(above row: Int) -> CGFloat {
        guard rows.indices.contains(row), !rows[row].isFileHeader, let first = fileHeaderRows.first, first < row else { return 0 }
        return FileHeaderView.height
    }

    /// Puts a row at the top of the viewport, just below the floating file header.
    func jump(toRow row: Int, leavingAbove extra: CGFloat = 0) {
        guard rows.indices.contains(row) else { return }
        tableView.layoutSubtreeIfNeeded()
        scroll(toY: tableView.rect(ofRow: row).minY - stickyHeaderHeight(above: row) - extra)
        tableView.layoutSubtreeIfNeeded()
    }

    /// How far a row sits from where `jump(toRow:)` puts it. Zero means it landed exactly.
    func jumpError(_ row: Int) -> CGFloat {
        tableView.rect(ofRow: row).minY - stickyHeaderHeight(above: row) - visibleRect.minY
    }

    /// Scrolls the least needed to show a row in full, below the floating header.
    func scrollToShow(row: Int) {
        guard rows.indices.contains(row) else { return }
        tableView.layoutSubtreeIfNeeded()
        let rect = tableView.rect(ofRow: row)
        let visible = visibleRect
        let top = visible.minY + stickyHeaderHeight(above: row)
        if rect.minY < top || rect.height > visible.height - (top - visible.minY) {
            jump(toRow: row)
        } else if rect.maxY > visible.maxY {
            scroll(toY: rect.maxY - visible.height)
        }
    }

    @objc private func didScroll() {
        updateCurrentFile()
        if hoveredRowID != nil, tableView.window?.currentEvent?.type == .scrollWheel { setHoveredRow(nil) }
    }

    private func updateCurrentFile() {
        let top = tableView.rows(in: visibleRect).location
        let header = fileHeaderRows.last { $0 <= top + 1 }
        var path: String?
        if let header, case .fileHeader(let content) = rows[header] { path = content.path }
        if windowState.currentFilePath != path { windowState.currentFilePath = path }
    }

    func fileHeaderIndex(containing row: Int) -> Int? {
        fileHeaderRows.last { $0 <= row }
    }
}

extension ThreadRowRoot {
    static let placeholder = ThreadRowRoot(
        content: ThreadRowContent(
            thread: ThreadItem(id: 0, anchor: .layer, comments: [], isResolved: false, state: .draft, anchorNote: nil, originalLines: []),
            anchorText: "", placementNote: nil, isCollapsed: false, hasComposerBelow: false, leadingInset: 0),
        isFocused: false, actions: ThreadCardActions())
}

extension OverviewContent {
    static let placeholder = OverviewContent(layer: nil, layerCount: 0, parentBranch: nil, commits: [], fileCount: 0, additions: 0, deletions: 0, threadCount: 0)
}
