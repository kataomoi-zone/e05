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
    let previouslySelectedURLs: [URL] = tableView.selectedRowIndexes.compactMap {
      $0 < items.count ? items[$0].url : nil
    }
    currentSortKey = sortKey
    sortAscending = descriptor.ascending
    items = Self.sortItems(items, key: sortKey, ascending: descriptor.ascending)
    tableView.reloadData()
    var restored = IndexSet()
    for url in previouslySelectedURLs {
      if let idx = items.firstIndex(where: { $0.url == url }) {
        restored.insert(idx)
      }
    }
    if !restored.isEmpty {
      tableView.selectRowIndexes(restored, byExtendingSelection: false)
    }
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
      return cell
    }

    let cell =
      tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
      ?? Self.makeTextCell(identifier: identifier)

    switch identifier {
    case Self.dateColumn:
      cell.textField?.stringValue = item.displayDate
    case Self.sizeColumn:
      cell.textField?.stringValue = item.displaySize
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
    rowView.dimmed = row >= 0 && row < items.count && items[row].isHidden
    return rowView
  }

  // MARK: - Cell factories

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

    cell.addSubview(imageView)
    cell.addSubview(textField)
    cell.imageView = imageView
    cell.textField = textField

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
      imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 16),
      imageView.heightAnchor.constraint(equalToConstant: 16),
      textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
      textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
      textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
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
