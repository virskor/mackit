import Foundation

/// Which items are checked for cleaning, and the rules that decide it.
///
/// Everything "what is selected" lives here — the item ids, the general
/// page's row-level curation (rows the scan found nothing for), and the
/// remembered selection — so the policy is stated once instead of being
/// spread across the view model: what a fresh scan pre-checks, what a toggle
/// moves, what a clean leaves behind, and what gets remembered. The view
/// model owns exactly one instance and delegates to it; nothing else mutates
/// the selection.
///
/// Operations that need to know which items exist (a row's items, a sub-row's
/// items) take the item list as a parameter: the item list belongs to the
/// scan, the selection belongs here.
@MainActor
@Observable
final class CleanupSelection {
    /// Item ids the user has checked.
    ///
    /// Ids of items a clean deleted are dropped, so this never holds stale
    /// entries — the row-level check that outlives those items lives in
    /// `handCheckedRows`.
    private(set) var ids: Set<String> = []

    /// General-page rows checked outside the item selection.
    ///
    /// Three kinds of rows need it: rows the scan found nothing for — their
    /// checkbox cannot be derived from items that do not exist; rows arriving
    /// with the remembered selection, which must show checked even when the
    /// new scan finds nothing for them; and rows whose items a clean just
    /// deleted, which must keep showing the user's curation instead of
    /// reading as "the user changed their mind".
    private(set) var handCheckedRows: Set<String> = []

    /// The remembered row selection; nil means "never saved" and falls back
    /// to the built-in default.
    ///
    /// The setter is for reading the shared file at startup (and for tests
    /// standing in for a saved selection): it changes the state without
    /// persisting, unlike `rememberCurrentRows` / `restoreDefaultSelection`,
    /// which are user actions and do persist.
    var rememberedRows: Set<String>? {
        get { storedRememberedRows }
        set { storedRememberedRows = newValue }
    }

    private var storedRememberedRows: Set<String>?

    /// Called when a user action changes the remembered selection, so the
    /// owner can persist it (and broadcast the change to the tray agent).
    /// Reading the shared file at startup assigns `rememberedRows` directly
    /// and does not go through here.
    var onRememberedRowsChanged: (@MainActor (Set<String>?) -> Void)?

    // MARK: - Incoming items

    /// Clears everything for a new scan: the item checks and the hand-checked
    /// rows. The remembered selection stays — it is what the next scan
    /// pre-checks from.
    func reset() {
        ids = []
        handCheckedRows = []
    }

    /// Applies the pre-check policy to a batch of newly discovered items.
    /// Returns whether anything moved.
    ///
    /// The general module follows Lemon's model: safe and review rows arrive
    /// pre-checked — or exactly the remembered rows once the user has saved a
    /// selection. The developer feature follows the user's auto-select
    /// setting instead, including "none". Items of unknown size (an empty
    /// cache directory) are never pre-checked: there is nothing to reclaim,
    /// so a check on them would be noise.
    @discardableResult
    func applyDefaultPolicy(to batch: [JunkItem], autoSelect: AutoSelectLevel) -> Bool {
        var changed = false
        for item in batch where !item.isUnknownSize {
            let eligible: Bool
            if item.category.scope == .general {
                if let saved = rememberedRows {
                    eligible = saved.contains(rowID(of: item))
                } else {
                    eligible = item.risk <= .review
                }
            } else if let cap = autoSelect.riskCap {
                eligible = item.risk <= cap
            } else {
                eligible = false
            }
            if eligible, ids.insert(item.id).inserted { changed = true }
        }
        return changed
    }

    /// Restarts the general page's hand-checked rows for a new scan: the
    /// remembered selection when the user saved one (so a remembered row
    /// shows checked even if the new scan finds nothing for it), otherwise
    /// nothing — the built-in default pre-check covers the rest. Returns
    /// whether anything moved.
    @discardableResult
    func restartHandCheckedRows() -> Bool {
        let next = rememberedRows ?? []
        guard next != handCheckedRows else { return false }
        handCheckedRows = next
        return true
    }

    // MARK: - Toggles

    /// Checks or unchecks one item. Returns whether anything moved.
    @discardableResult
    func setItem(_ id: String, selected: Bool) -> Bool {
        if selected { return ids.insert(id).inserted }
        return ids.remove(id) != nil
    }

    /// Checks or unchecks exactly the given item ids. Returns whether
    /// anything moved.
    @discardableResult
    func setItems(_ itemIDs: Set<String>, selected: Bool) -> Bool {
        var changed = false
        for id in itemIDs where setItem(id, selected: selected) { changed = true }
        return changed
    }

    /// Replaces the whole selection: the uninstall flow's "exactly this app
    /// and its files" gesture, which deliberately drops everything else.
    func replace(with itemIDs: Set<String>) {
        ids = itemIDs
    }

    /// Checks or unchecks a general-page row at once: every item it rolls up,
    /// plus the row's hand-checked record — without that record a row the
    /// scan found nothing for would be inert and ignore every click.
    /// Returns whether anything moved.
    @discardableResult
    func setRow(_ row: GeneralRuleRow, selected: Bool, items: [JunkItem]) -> Bool {
        var changed = setItems(itemIDs(of: [row], in: items), selected: selected)
        changed = setHandChecked(row.id, selected: selected) || changed
        return changed
    }

    /// Checks or unchecks a whole general-page group at once — the group
    /// header is the toggle, for when the user wants all of "System Junk"
    /// without clicking each row. Rows that found nothing have no items to
    /// move, so the group's hand-checked rows move with the toggle. Returns
    /// whether anything moved.
    @discardableResult
    func setGroup(_ group: GeneralCleanGroup, selected: Bool, items: [JunkItem]) -> Bool {
        let rows = GeneralCleanLayout.rows(of: group)
        var changed = setItems(itemIDs(of: rows, in: items), selected: selected)
        for row in rows {
            changed = setHandChecked(row.id, selected: selected) || changed
        }
        return changed
    }

    /// Checks or unchecks one sub-row of a grouped row — a single language,
    /// or a single app's junk — leaving the rest of the row as it was.
    /// Returns whether anything moved.
    @discardableResult
    func setSubRow(of row: GeneralRuleRow, key: String, selected: Bool, items: [JunkItem]) -> Bool {
        setItems(subRowItemIDs(of: row, key: key, in: items), selected: selected)
    }

    /// Checks every safe item, optionally restricted to a set of scopes; nil
    /// means every scope, which is what the tray's one-click clean uses (it
    /// has no mode of its own and sweeps everything safe). Returns whether
    /// anything moved.
    @discardableResult
    func selectAllSafe(_ items: [JunkItem], scopes: Set<CleanupScope>?) -> Bool {
        let safe = Set(
            items
                .filter { item in item.risk == .safe && (scopes?.contains(item.category.scope) ?? true) }
                .map(\.id)
        )
        return setItems(safe, selected: true)
    }

    /// Records a general-page row as checked (or unchecked) outside the item
    /// selection. Returns whether the record moved.
    @discardableResult
    private func setHandChecked(_ rowID: String, selected: Bool) -> Bool {
        if selected { return handCheckedRows.insert(rowID).inserted }
        return handCheckedRows.remove(rowID) != nil
    }

    // MARK: - Remember / restore

    /// Whether a row selection is remembered. While one is, the general page
    /// offers "restore defaults" instead of "remember this selection" —
    /// otherwise a remembered selection would be a one-way door with no way
    /// back to the built-in default.
    var hasRememberedSelection: Bool { rememberedRows != nil }

    /// Remembers the rows the current selection checks, so every later scan
    /// pre-checks exactly these.
    func rememberCurrentRows(items: [JunkItem]) {
        setRememberedRows(selectedRows(items: items), persist: true)
    }

    /// Drops the remembered selection and re-applies the built-in default
    /// (safe + review rows pre-checked) to the items at hand, so the shortcut
    /// works without forcing a rescan. Returns whether anything moved.
    @discardableResult
    func restoreDefaultSelection(items: [JunkItem]) -> Bool {
        setRememberedRows(nil, persist: true)
        var changed = false
        for item in items where item.category.scope == .general {
            // Same eligibility rule as a fresh scan's default pre-check
            // (see `applyDefaultPolicy`).
            let shouldSelect = !item.isUnknownSize && item.risk <= .review
            if setItem(item.id, selected: shouldSelect) { changed = true }
        }
        if !handCheckedRows.isEmpty {
            handCheckedRows = []
            changed = true
        }
        return changed
    }

    /// Applies a new remembered selection, notifying the owner when a user
    /// action (rather than a startup read) made the change.
    private func setRememberedRows(_ rows: Set<String>?, persist: Bool) {
        guard rows != rememberedRows else { return }
        rememberedRows = rows
        if persist { onRememberedRowsChanged?(rows) }
    }

    // MARK: - Derived state

    /// The rows the current selection checks on the general page: rows with
    /// selected items, plus rows checked by hand — the only way a row with no
    /// findings can be checked at all.
    func selectedRows(items: [JunkItem]) -> Set<String> {
        var rows = handCheckedRows
        for item in items where item.category.scope == .general && ids.contains(item.id) {
            rows.insert(rowID(of: item))
        }
        return rows
    }

    /// Whether the general page's current selection differs from what the
    /// next scan would pre-check — i.e. whether there is a new setting worth
    /// remembering.
    func selectionDiffersFromDefault(items: [JunkItem]) -> Bool {
        selectedRows(items: items) != defaultRows(items: items)
    }

    /// The rows the next scan would pre-check: the saved selection when set —
    /// every row in it, whether or not it currently has items, since a
    /// remembered row shows checked either way — otherwise the built-in
    /// default (safe + review) restricted to rows that currently have
    /// selectable items.
    func defaultRows(items: [JunkItem]) -> Set<String> {
        if let saved = rememberedRows { return saved }
        return Set(GeneralCleanLayout.rows.filter { $0.risk <= .review }.map(\.id))
            .intersection(rowsWithSelectableItems(items: items))
    }

    // MARK: - Leaving items

    /// Applies a clean's outcome.
    ///
    /// A clean acts on the selection; it does not reset it. The deleted
    /// items' ids are dropped (they match nothing any more), but the
    /// row-level check survives: a row whose items were all cleaned keeps its
    /// check as a hand-checked row, so the page still shows the curation the
    /// user made instead of reading as "nothing selected", and an item whose
    /// clean failed stays checked so it can be retried. Only a new scan
    /// restarts the selection (`restartHandCheckedRows`).
    ///
    /// Call this *before* removing the items from the caller's list: which
    /// rows lost their items is computed from the full list.
    func applyCleanResult(_ cleanedIDs: Set<String>, items: [JunkItem]) {
        var emptiedRows: Set<String> = []
        var survivingRows: Set<String> = []
        for item in items where item.category.scope == .general {
            let row = rowID(of: item)
            guard !row.isEmpty else { continue }
            if cleanedIDs.contains(item.id) {
                emptiedRows.insert(row)
            } else {
                survivingRows.insert(row)
            }
        }
        ids.subtract(cleanedIDs)
        handCheckedRows.formUnion(emptiedRows.subtracting(survivingRows))
    }

    /// Drops items that left the list outside a clean — one entry moved to
    /// the Trash from its context menu.
    func discard(_ itemIDs: Set<String>) {
        ids.subtract(itemIDs)
    }

    // MARK: - Row and sub-row grouping

    /// The sub-rows a grouped row splits into: the group key (a language code
    /// or an app's display name), the item ids it covers, and their total
    /// size. Sorted largest first, the order the page shows them in. Empty
    /// for a flat row, which is one toggle over all of its entries.
    ///
    /// Items with no grouping key are left out rather than dumped into a "?"
    /// bucket — the row header still covers them.
    func subRowGroups(of row: GeneralRuleRow, items: [JunkItem]) -> [SubRowGroup] {
        guard row.subRowMode != .flat, !items.isEmpty else { return [] }
        var byKey: [String: [JunkItem]] = [:]
        for item in items where row.ruleIDs.contains(item.ruleID) {
            guard let key = subRowKey(for: item, mode: row.subRowMode) else { continue }
            byKey[key, default: []].append(item)
        }
        return byKey.map { key, group in
            SubRowGroup(
                key: key,
                itemIDs: Set(group.map(\.id)),
                size: group.reduce(0) { $0 + $1.size }
            )
        }
        .sorted { $0.size == $1.size ? $0.key < $1.key : $0.size > $1.size }
    }

    /// One sub-row of a grouped row: its key, the items it covers, and their
    /// total size. The display title is the view's business — a language
    /// code becomes the language's own name, an app key is already a name.
    struct SubRowGroup {
        let key: String
        let itemIDs: Set<String>
        let size: Int64
    }

    /// The sub-row an item belongs to, nil when it carries no key for the
    /// row's mode.
    func subRowKey(for item: JunkItem, mode: GeneralSubRowMode) -> String? {
        switch mode {
        case .flat:
            return nil
        case .byLanguage:
            // Language packs are titled "<code>.lproj"; the code is the group.
            let code = (item.title as NSString).deletingPathExtension
            return code.isEmpty ? nil : code
        case .byApp:
            return item.appName ?? (item.title.isEmpty ? nil : item.title)
        }
    }

    // MARK: - Private helpers

    /// The general-page row an item belongs to. Items from an unknown rule id
    /// roll into no row and are never remembered — the layout test keeps that
    /// from happening.
    private func rowID(of item: JunkItem) -> String {
        GeneralCleanLayout.rowID(forRuleID: item.ruleID) ?? ""
    }

    private func itemIDs(of rows: [GeneralRuleRow], in items: [JunkItem]) -> Set<String> {
        let ruleIDs = Set(rows.flatMap(\.ruleIDs))
        return Set(items.filter { ruleIDs.contains($0.ruleID) }.map(\.id))
    }

    private func subRowItemIDs(of row: GeneralRuleRow, key: String, in items: [JunkItem]) -> Set<String> {
        Set(
            items
                .filter { row.ruleIDs.contains($0.ruleID) && subRowKey(for: $0, mode: row.subRowMode) == key }
                .map(\.id)
        )
    }

    private func rowsWithSelectableItems(items: [JunkItem]) -> Set<String> {
        var rows: Set<String> = []
        for item in items where item.category.scope == .general && !item.isUnknownSize {
            rows.insert(rowID(of: item))
        }
        return rows
    }
}
