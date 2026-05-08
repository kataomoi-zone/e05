import AppKit
import QuickLookUI

/// Icon-grid presentation for `FinderPaneView`. The collection view
/// is a sibling to the list view's `tableView`, sharing the same
/// `items` array as data source so a directory load / sort / filter
/// runs once and both views render against the same snapshot. Mode
/// switching just flips `isHidden` on the two scroll views — no data
/// re-fetch, and the active view's `reloadData` picks up the current
/// `items` lazily.
///
/// Drag-and-drop, context menu, inline rename, undo/redo, Quick
/// Look, hidden-file dim, and in-flight placeholder rendering are
/// list-only — each needs an icon-mode-specific event path that
/// the table-view hooks don't share, so the icon view stays
/// read-only until those land.
extension FinderPaneView: NSCollectionViewDataSource {
  public func collectionView(
    _ collectionView: NSCollectionView, numberOfItemsInSection section: Int
  ) -> Int {
    items.count
  }

  public func collectionView(
    _ collectionView: NSCollectionView,
    itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    let cell = collectionView.makeItem(
      withIdentifier: FinderIconItem.identifier, for: indexPath)
    guard indexPath.item < items.count else { return cell }
    let fileItem = items[indexPath.item]
    cell.imageView?.image = iconForRow(fileItem)
    cell.textField?.stringValue = fileItem.name
    return cell
  }
}

extension FinderPaneView: NSCollectionViewDelegate {
  public func collectionView(
    _ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>
  ) {
    handleIconSelectionChange()
  }

  public func collectionView(
    _ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>
  ) {
    handleIconSelectionChange()
  }

  /// Run the same status-bar / Quick Look refresh the list view's
  /// `tableViewSelectionDidChange` does. Internal rather than
  /// private so `+Selection.swift` can fire it after programmatic
  /// `selectItems(at:scrollPosition:)` calls — AppKit itself does
  /// **not** invoke `collectionView(_:didSelectItemsAt:)` for
  /// programmatic selection, so a paste / undo restore / in-flight
  /// overlay refresh would otherwise leave the status bar stuck on
  /// the pre-selection count.
  func handleIconSelectionChange() {
    updateStatusBar()
    if QLPreviewPanel.sharedPreviewPanelExists(),
      let panel = QLPreviewPanel.shared(), panel.isVisible
    {
      panel.reloadData()
    }
  }
}

extension FinderPaneView {
  // MARK: - Setup

  func setupIconView() {
    let layout = NSCollectionViewFlowLayout()
    layout.itemSize = FinderIconItem.itemSize
    layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    layout.minimumInteritemSpacing = 8
    layout.minimumLineSpacing = 8

    iconCollectionView.collectionViewLayout = layout
    iconCollectionView.dataSource = self
    iconCollectionView.delegate = self
    iconCollectionView.allowsMultipleSelection = true
    iconCollectionView.allowsEmptySelection = true
    iconCollectionView.isSelectable = true
    iconCollectionView.backgroundColors = [.clear]
    iconCollectionView.register(
      FinderIconItem.self,
      forItemWithIdentifier: FinderIconItem.identifier)

    iconCollectionView.onFocusChanged = { [weak self] in
      self?.onFocusChanged?()
    }
    iconCollectionView.onItemDoubleClick = { [weak self] indexPath in
      guard let self, indexPath.item < self.items.count else { return }
      self.navigate(to: self.items[indexPath.item].url)
    }

    iconScrollView.documentView = iconCollectionView
    iconScrollView.hasVerticalScroller = true
    iconScrollView.hasHorizontalScroller = false
    iconScrollView.autohidesScrollers = true
    iconScrollView.drawsBackground = false
    iconScrollView.translatesAutoresizingMaskIntoConstraints = false
  }

  // MARK: - Mode switching

  /// Switch the active view mode and persist the choice for
  /// `currentURL`. Selection round-trips through `selectedURLs` so
  /// the user keeps the same files highlighted across the swap.
  /// Returns whether the mode actually changed — callers may still
  /// fire a confirmation toast on a no-op (matching the menu-action
  /// convention of always acknowledging the user's intent), but the
  /// store write and the visibility flip are skipped.
  @discardableResult
  public func setViewMode(_ mode: FinderViewMode) -> Bool {
    guard mode != currentMode else { return false }
    let preserved = selectedURLs
    let wasFirstResponder = (window?.firstResponder as? NSView)
      .map { $0.isDescendant(of: self) } ?? false

    currentMode = mode
    applyViewModeVisibility()
    reloadAllRows()
    selectRows(byURLs: preserved)
    FinderModeStore.shared.setMode(mode, for: currentURL)

    // Move first-responder onto the now-visible view so palette /
    // menu invocations don't leave keyboard focus on a hidden table
    // (or a hidden collection view going the other way). Only when
    // the focus was *already* inside this pane — switching mode on
    // a background pane shouldn't steal focus away from wherever the
    // user is actually working.
    if wasFirstResponder {
      window?.makeFirstResponder(keyboardFocusTarget)
    }
    return true
  }

  /// Re-read the persisted mode for `currentURL` and apply if
  /// different. Triggered by `FinderModeStore.didChangeNotification`
  /// so that toggling mode in pane A propagates to pane B that's
  /// showing the same directory. The notification is coarse (no
  /// `userInfo`), so every open finder pane runs this on every
  /// store mutation; the early-return on equal modes keeps the
  /// fan-out free of redundant reload churn.
  func resyncViewModeFromStore() {
    let stored = FinderModeStore.shared.mode(for: currentURL)
    guard stored != currentMode else { return }
    let preserved = selectedURLs
    currentMode = stored
    applyViewModeVisibility()
    reloadAllRows()
    selectRows(byURLs: preserved)
  }

  /// Reflect `currentMode` onto the two scroll views. Called from
  /// init, mode switch, navigation, and the cross-pane resync — the
  /// single source of truth so the visibility invariant
  /// (`scrollView.isHidden ⇔ currentMode == .icon`) is preserved
  /// without hand-rolled toggles at each call site.
  func applyViewModeVisibility() {
    scrollView.isHidden = (currentMode != .list)
    iconScrollView.isHidden = (currentMode != .icon)
  }
}
