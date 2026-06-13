import AppKit

/// Column pinning: lift a column out of the horizontal scroll flow into
/// a fixed leading overlay so it stays on screen while the other columns
/// scroll *under* it (CSS `position: sticky`). Mirrors how the sidebar
/// reserves a leading `contentInsets.left` lane while overlaying on top
/// — the pinned column is that same shape applied to one of the real
/// columns, composed with the sidebar reserve so the two never clobber
/// each other.
extension PaneContainerViewController {
  /// The pinned column in `vc`'s workspace, or `nil`. At most one
  /// column per workspace is pinned.
  func pinnedColumn(in vc: WorkspaceViewController) -> ColumnModel? {
    vc.workspace.columns.first { $0.isPinned }
  }

  /// Width reserved on the leading edge for `vc`'s pinned column — its
  /// width plus a one-margin gutter — or 0 when nothing is pinned.
  /// Composed with the sidebar's `currentLeadingInset` to form the
  /// scroll view's total leading content inset, so the resting columns
  /// clear the pin while a scroll still slides them under it.
  func pinnedColumnReserve(in vc: WorkspaceViewController) -> CGFloat {
    guard let pinned = pinnedColumn(in: vc),
      let width = pinned.widthConstraint?.constant
    else { return 0 }
    return width + WorkspaceViewController.outerMargin
  }

  /// Leading content inset for `vc`: sidebar reserve + pin reserve. The
  /// one site inset writes should resolve through so the two reserves
  /// stay composed instead of overwriting one another.
  func totalLeadingInset(in vc: WorkspaceViewController) -> CGFloat {
    currentLeadingInset + pinnedColumnReserve(in: vc)
  }

  /// Leading x for a pinned column's overlay: the sidebar reserve minus
  /// any hover-peek compensation — so the pin stays put during a peek,
  /// matching the columns it overlays (which are compensated to not
  /// shift) — plus the outer gutter.
  func pinnedOverlayLeading() -> CGFloat {
    currentLeadingInset - hoverPeekScrollCompensation + WorkspaceViewController.outerMargin
  }

  /// Re-apply `vc`'s leading content inset and reposition its pinned
  /// column overlay to match the current sidebar + pin reserves. Call
  /// after anything that changes either reserve (pin / unpin, sidebar
  /// reveal where the per-vc loop doesn't already handle it).
  func applyLeadingInset(in vc: WorkspaceViewController) {
    vc.scrollView.contentInsets.left = totalLeadingInset(in: vc)
    pinnedColumn(in: vc)?.pinLeadingConstraint?.constant = pinnedOverlayLeading()
  }

  /// Tear down a column's pin overlay constraints *without* returning it
  /// to the scrolling stack — for paths that remove the column entirely
  /// (close, cross-workspace move). Callers must re-apply the affected
  /// workspace's leading inset afterwards (`applyLeadingInset(in:)`) so
  /// the freed reserve doesn't linger as a phantom gap.
  func releasePinnedOverlay(_ column: ColumnModel) {
    guard column.isPinned else { return }
    setPinnedShadow(column, enabled: false)
    removePinResizeHandle(column)
    NSLayoutConstraint.deactivate(column.pinConstraints)
    column.pinConstraints = []
    column.pinLeadingConstraint = nil
    column.isPinned = false
  }

  /// Toggle the focused column's pinned state.
  public func togglePinColumn() {
    guard let column = columns[safe: focusedColumnIndex] else { return }
    if column.isPinned {
      unpinColumn(column)
    } else {
      pinColumn(column)
    }
  }

  /// Lift `column` into the leading overlay. Assumes `column` is the
  /// focused column of the current workspace (the only interactive pin
  /// entry point).
  func pinColumn(_ column: ColumnModel) {
    let vc = currentWorkspaceVC
    // One pin per workspace: retire any existing pin first.
    if let existing = pinnedColumn(in: vc), existing !== column {
      unpinColumn(existing)
    }
    applyPin(column, in: vc)
    view.layoutSubtreeIfNeeded()
    updateHandleActiveStates()
  }

  /// Structural half of pinning, shared by the interactive `pinColumn`
  /// and session restore: reparent `column` into `vc`'s leading overlay,
  /// drop it from the scrolling stack, and reserve its width. Takes the
  /// workspace VC explicitly so restore can pin a column in a workspace
  /// that isn't current, and runs no layout / scroll pass so the restore
  /// path can settle everything in one shot later.
  func applyPin(_ column: ColumnModel, in vc: WorkspaceViewController) {
    column.isPinned = true
    // Swap the stack height pin for an overlay top/bottom/leading pin.
    // The width constraint is self-referential, so it survives the
    // reparent untouched and keeps the column at its current width.
    column.heightPin?.isActive = false
    // Pull the column out of the scrolling stack before reparenting so
    // the stack's arranged list is left explicitly consistent rather
    // than relying on `removeFromSuperview`'s implicit detach.
    vc.stackView.removeArrangedSubview(column.containerView)
    column.containerView.removeFromSuperview()
    vc.view.addSubview(column.containerView, positioned: .above, relativeTo: vc.scrollView)

    let margin = WorkspaceViewController.outerMargin
    let leading = column.containerView.leadingAnchor.constraint(
      equalTo: vc.view.leadingAnchor, constant: pinnedOverlayLeading())
    let top = column.containerView.topAnchor.constraint(
      equalTo: vc.view.topAnchor, constant: margin)
    let bottom = column.containerView.bottomAnchor.constraint(
      equalTo: vc.view.bottomAnchor, constant: -margin)
    NSLayoutConstraint.activate([leading, top, bottom])
    column.pinConstraints = [leading, top, bottom]
    column.pinLeadingConstraint = leading

    // Drop the column (and its surrounding handles) from the scrolling
    // stack and reserve its width on the leading edge.
    rebuildStackView(in: vc)
    applyLeadingInset(in: vc)
    setPinnedShadow(column, enabled: true)
    installPinResizeHandle(for: column, in: vc)
  }

  /// Resize handle on the pinned column's trailing edge so the column
  /// can be dragged wider / narrower in place, with the leading reserve
  /// following. Sits in the overlay (above the scroll view), so it is
  /// always active rather than gated on focus like the in-stack handles.
  private func installPinResizeHandle(for column: ColumnModel, in vc: WorkspaceViewController) {
    let handle = PaneResizeHandle(orientation: .horizontal)
    handle.isActive = true
    vc.view.addSubview(handle, positioned: .above, relativeTo: vc.scrollView)
    let margin = WorkspaceViewController.outerMargin
    NSLayoutConstraint.activate(
      PaneResizeHandle.makeConstraints(for: handle) + [
        handle.leadingAnchor.constraint(equalTo: column.containerView.trailingAnchor),
        handle.topAnchor.constraint(equalTo: vc.view.topAnchor, constant: margin),
        handle.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor, constant: -margin),
      ])
    handle.onDrag = { [weak self, weak column, weak vc] deltaX in
      guard let self, let column, let vc, let constraint = column.widthConstraint else { return }
      // Fold owns the width while folded, mirroring the in-stack handles.
      guard !column.isFolded else { return }
      constraint.constant = max(Self.minPaneWidth, constraint.constant + deltaX)
      column.currentPreset = nil
      self.applyLeadingInset(in: vc)
    }
    column.pinResizeHandle = handle
  }

  /// Drop the pinned column's resize handle from the overlay.
  private func removePinResizeHandle(_ column: ColumnModel) {
    column.pinResizeHandle?.removeFromSuperview()
    column.pinResizeHandle = nil
  }

  /// Soft drop shadow biased to the trailing edge of a pinned column's
  /// overlay, cueing the depth that lets the scrolling columns read as
  /// passing *under* it. Cast from the column's composited content (its
  /// rounded pane surfaces with transparent gutters) rather than a
  /// `shadowPath`. Cleared when the column unpins or is removed.
  private func setPinnedShadow(_ column: ColumnModel, enabled: Bool) {
    let cv = column.containerView
    guard enabled else {
      // Only dim an existing shadow — never induce layer-backing just to
      // clear one that was never set. `masksToBounds` is intentionally
      // left as-is (NSStackView never clips, so it is harmless).
      cv.layer?.shadowOpacity = 0
      cv.layer?.shadowRadius = 0
      return
    }
    cv.wantsLayer = true
    guard let layer = cv.layer else { return }
    layer.masksToBounds = false
    layer.shadowColor = NSColor.black.cgColor
    layer.shadowOffset = CGSize(width: 5, height: 0)
    layer.shadowOpacity = 0.3
    layer.shadowRadius = 10
  }

  /// Return `column` from the leading overlay to the scrolling stack.
  func unpinColumn(_ column: ColumnModel) {
    let vc = currentWorkspaceVC
    column.isPinned = false
    setPinnedShadow(column, enabled: false)
    removePinResizeHandle(column)
    NSLayoutConstraint.deactivate(column.pinConstraints)
    column.pinConstraints = []
    column.pinLeadingConstraint = nil
    column.containerView.removeFromSuperview()

    // Re-insert into the scrolling stack, then restore the stack height
    // pin (activated after `rebuildStackView` so the column and the
    // stack share a common ancestor — see the same ordering note in
    // `insertColumn`).
    rebuildStackView(in: vc)
    let heightPin = column.containerView.heightAnchor.constraint(
      equalTo: vc.stackView.heightAnchor,
      constant: -(WorkspaceViewController.outerMargin * 2))
    heightPin.isActive = true
    column.heightPin = heightPin

    applyLeadingInset(in: vc)
    view.layoutSubtreeIfNeeded()
    updateHandleActiveStates()
    // Bring the now-scrolling column back into view next to where the
    // pin sat, mirroring unfold's scroll-to-focus.
    if let index = columns.firstIndex(where: { $0 === column }) {
      scrollToColumn(at: index)
    }
  }
}
