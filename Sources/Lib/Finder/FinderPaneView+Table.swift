import AppKit
import QuickLookUI

/// Table presentation: NSTableView data source / delegate callbacks,
/// cell-view factories for the four columns (Name / Date Modified /
/// Size / Kind), and the `FinderRowView` supply that drives hidden-
/// file dimming. Nothing in this extension mutates `items`; every
/// callback reads the snapshot produced by `FinderPaneView+Directory`.
extension FinderPaneView: NSTableViewDataSource {
  public func numberOfRows(in tableView: NSTableView) -> Int {
    items.count
  }

  /// AppKit calls this when the user clicks a column header. The new
  /// descriptors already include the flipped direction if the user
  /// clicked the active column again, and the header indicator
  /// updates on its own — all we need to do is translate the
  /// descriptor key back into our `SortKey` enum, re-sort, and
  /// reload. Selection is preserved by URL rather than row index
  /// because the sort shuffles the items under fixed row indexes;
  /// without the URL round-trip, the user's highlight would jump to
  /// whatever file landed in the same row after the sort.
  public func tableView(
    _ tableView: NSTableView,
    sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
  ) {
    guard let descriptor = tableView.sortDescriptors.first,
      let key = descriptor.key,
      let sortKey = SortKey(rawValue: key)
    else { return }
    let previouslySelectedURLs = selectedURLs
    currentSortKey = sortKey
    sortAscending = descriptor.ascending
    items = Self.sortItems(items, key: sortKey, ascending: descriptor.ascending)
    // Keep `lastLoadedItems` in lockstep with the active sort so a
    // later in-flight overlay refresh that hits the no-synthetics
    // fast path (cwdTargets empty) returns rows in the user's
    // current order rather than the pre-click one.
    lastLoadedItems = Self.sortItems(
      lastLoadedItems, key: sortKey, ascending: descriptor.ascending)
    reloadAllRows()
    selectRows(byURLs: previouslySelectedURLs)
    updateStatusBar()
  }
}

extension FinderPaneView: NSTableViewDelegate {
  public func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    guard let column = tableColumn, row < items.count else { return nil }
    let item = items[row]
    let identifier = column.identifier

    if identifier == Self.nameColumn {
      let cell =
        tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
        ?? Self.makeNameCell(identifier: identifier)
      cell.textField?.stringValue = item.name
      cell.imageView?.image = iconForRow(item)
      // Toggle the per-row in-flight spinner. Cells are recycled, so
      // the previous occupant's spinner state must be reset on every
      // `viewFor` callback even when this row isn't in-flight.
      let spinner = Self.nameCellSpinner(in: cell)
      if inFlightURLs.contains(item.url) {
        spinner?.isHidden = false
        spinner?.startAnimation(nil)
      } else {
        spinner?.stopAnimation(nil)
        spinner?.isHidden = true
      }
      return cell
    }

    let cell =
      tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
      ?? Self.makeTextCell(identifier: identifier)

    switch identifier {
    case Self.dateColumn:
      cell.textField?.stringValue = item.displayDate
    case Self.sizeColumn:
      cell.textField?.stringValue = sizeDisplay(for: item)
      cell.textField?.alignment = .right
    case Self.kindColumn:
      cell.textField?.stringValue = item.displayKind
    default:
      cell.textField?.stringValue = ""
    }
    cell.textField?.textColor = .secondaryLabelColor
    return cell
  }

  public func tableViewSelectionDidChange(_ notification: Notification) {
    updateStatusBar()
    if QLPreviewPanel.sharedPreviewPanelExists(),
      let panel = QLPreviewPanel.shared(), panel.isVisible
    {
      panel.reloadData()
    }
  }

  /// Supply a `FinderRowView` so hidden filesystem entries (dotfiles,
  /// `~/Library`, anything with `isHidden` set) can render at reduced
  /// opacity while leaving the selection highlight at full intensity.
  /// Matches Finder's list view under `⌘⇧.`: hidden rows dim on rest,
  /// then snap back to full brightness on selection so the blue
  /// highlight reads the same for hidden and non-hidden rows.
  public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let rowView =
      tableView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? FinderRowView
      ?? FinderRowView()
    rowView.identifier = Self.rowIdentifier
    let item = (row >= 0 && row < items.count) ? items[row] : nil
    // In-flight rows share the dimmed alpha with hidden rows: both
    // signal "this row is real but not the user's primary focus". The
    // name-cell spinner is what differentiates the in-flight case
    // visually.
    rowView.dimmed = item.map { $0.isHidden || inFlightURLs.contains($0.url) } ?? false
    return rowView
  }

  // MARK: - Cell factories

  /// Identifier for the in-flight spinner subview embedded in the
  /// name cell. Used by `viewFor` to find and toggle the spinner
  /// without subclassing `NSTableCellView`.
  static let nameSpinnerIdentifier = NSUserInterfaceItemIdentifier("finder.cell.spinner")

  static func nameCellSpinner(in cell: NSTableCellView) -> NSProgressIndicator? {
    cell.subviews.first { $0.identifier == nameSpinnerIdentifier } as? NSProgressIndicator
  }

  static func makeNameCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier

    let imageView = NSImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.imageScaling = .scaleProportionallyDown

    // Plain `NSTextField` rather than the label factory. `isEditable`
    // is left `true` permanently so `beginRename`'s `editColumn` call
    // can reliably hand the cell off to the field editor on every
    // invocation — toggling editability after the cell has been
    // recycled through the reuse pool was flaky in practice (rename
    // engaged the first time but not subsequent times). A view-based
    // NSTableView does not auto-engage edit mode on click just
    // because `isEditable` is true; the cell only enters edit mode
    // when `editColumn` is called explicitly from `beginRename`.
    let textField = NSTextField()
    textField.isBordered = false
    textField.isBezeled = false
    textField.drawsBackground = false
    textField.isEditable = true
    textField.isSelectable = true
    textField.focusRingType = .none
    textField.font = .systemFont(ofSize: 13)
    textField.lineBreakMode = .byTruncatingTail
    textField.cell?.usesSingleLineMode = true
    textField.translatesAutoresizingMaskIntoConstraints = false

    // Hidden spinner kept on every name cell so the data-source
    // callback can toggle visibility without rebuilding the view
    // hierarchy (or subclassing `NSTableCellView` just to track one
    // extra subview). `controlSize = .small` matches Finder's
    // in-flight glyph size; indeterminate spinning because no real
    // progress fraction is available yet (zip(1) stderr / chunked-copy
    // counters are future work).
    let spinner = NSProgressIndicator()
    spinner.identifier = Self.nameSpinnerIdentifier
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isIndeterminate = true
    spinner.isDisplayedWhenStopped = false
    spinner.isHidden = true
    spinner.translatesAutoresizingMaskIntoConstraints = false

    cell.addSubview(imageView)
    cell.addSubview(textField)
    cell.addSubview(spinner)
    cell.imageView = imageView
    cell.textField = textField

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
      imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 16),
      imageView.heightAnchor.constraint(equalToConstant: 16),
      textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
      textField.trailingAnchor.constraint(lessThanOrEqualTo: spinner.leadingAnchor, constant: -4),
      textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      spinner.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
      spinner.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      spinner.widthAnchor.constraint(equalToConstant: 12),
      spinner.heightAnchor.constraint(equalToConstant: 12),
    ])
    return cell
  }

  static func makeTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
    let cell = NSTableCellView()
    cell.identifier = identifier

    let textField = NSTextField(labelWithString: "")
    textField.font = .systemFont(ofSize: 12)
    textField.lineBreakMode = .byTruncatingTail
    textField.translatesAutoresizingMaskIntoConstraints = false

    cell.addSubview(textField)
    cell.textField = textField

    NSLayoutConstraint.activate([
      textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
      textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
      textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }
}
