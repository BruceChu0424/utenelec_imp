part of 'master_data_table_view.dart';

// AI 页面上下文登记(ADR-150)。只在用户向 AI 助手发问/确认卡片时被调用:
// 可见列、前 30 行显示文本、按最终单元格底色聚合的状态图例(颜色名 + 值 + 含义 + 行数)、
// 勾选数、整行标红(rowColor 解析为红)的行; 通用动作 筛选 / 勾选行 / 打开行 与表头和
// 行上的点击走同一段代码。
// 不参与 build, 不影响滚动与重建。

/// Rows scanned for the legend; a retained window never exceeds this anyway.
const int _aiLegendScanLimit = 3000;

extension _MasterDataTableAi<T> on _MasterDataTableViewState<T> {
  AiTableSource get _aiTableSource => AiTableSource(
    capture: _aiCapture,
    actions: _aiActions,
    owner: () => this,
    records: () => [for (final item in _displayItems) item as Object],
    recordKey: (record) => widget.idOf?.call(record as T) ?? record,
  );

  /// A column whose values never leave the app (marked or by label).
  bool _aiSecret(MasterColumnDef<T> column) =>
      column.aiSensitive || aiIsSensitiveLabel(column.label);

  /// Same final colour as [_buildDataCell] (unselected).
  Color? _aiCellColor(MasterColumnDef<T> column, T item) =>
      column.cellColor?.call(context, item);

  AiTableSnapshot? _aiCapture(AiCaptureContext ctx) {
    if (!mounted || widget.listItemBuilder != null) return null;
    final visible = _visibleIndices;
    final shown = visible.take(AiSnapshotLimits.columns).toList();
    final rows = _displayItems;
    final columns = [
      for (final i in shown)
        AiTableColumn(
          label: aiSnapshotLabel(_columns[i].label) ?? '',
          info: aiSnapshotValue(_columns[i].info, AiSnapshotLimits.info),
          sensitive: _columns[i].aiSensitive,
        ),
    ];
    bool selected(T item) {
      if (widget.selectable) {
        final id = widget.idOf?.call(item);
        return id != null && widget.selectedIds.contains(id);
      }
      return widget.isSelected?.call(item) ?? identical(item, _selectedItem);
    }

    // A row painted red as a whole (rowColor) is a "flagged" row.
    bool flaggedRow(T item) =>
        utenNamedColor(widget.rowColor?.call(item))?.tone ==
        UtenStatusBadgeType.danger;
    // Row text for flagged rows: first two non-empty columns, never a
    // withheld one (a user may move a cost column to the front).
    String rowLabel(T item) {
      final parts = <String>[];
      for (final i in visible) {
        if (_aiSecret(_columns[i])) continue;
        final text = aiSnapshotValue(_columns[i].value(item)) ?? '';
        if (text.isEmpty || text == '—') continue;
        parts.add(text);
        if (parts.length == 2) break;
      }
      return aiSnapshotValue(parts.join(' ')) ?? '';
    }

    final sample = <AiTableRow>[];
    for (var r = 0; r < rows.length && r < AiSnapshotLimits.rows; r++) {
      final item = rows[r];
      sample.add(
        AiTableRow(
          no: r + 1,
          cells: [
            for (final i in shown)
              aiSnapshotValue(_columns[i].value(item)) ?? '',
          ],
          selected: selected(item),
          flagged: widget.rowColor != null && flaggedRow(item),
        ),
      );
    }
    final flagged = <AiFlaggedCell>[
      if (widget.rowColor != null)
        for (var r = 0; r < rows.length && r < _aiLegendScanLimit; r++)
          if (flaggedRow(rows[r]))
            AiFlaggedCell(
              rowNo: r + 1,
              rowLabel: rowLabel(rows[r]),
              state: AiCellState.flagged,
            ),
    ];
    // Legend over every visible column, including those beyond the first 12.
    final counts = <(String, String, String, String), int>{};
    final meanings = <(String, String, String, String), String>{};
    for (final i in visible) {
      final column = _columns[i];
      final label = aiSnapshotLabel(column.label);
      if (label == null ||
          _aiSecret(column) ||
          (column.cellColor == null &&
              !utenIsStatusColumn(column.key, column.label))) {
        continue;
      }
      for (final item in rows.take(_aiLegendScanLimit)) {
        final named = utenNamedColor(_aiCellColor(column, item));
        final value = aiSnapshotValue(column.value(item));
        if (named == null || value == null || value.isEmpty || value == '—') {
          continue;
        }
        final key = (label, value, named.name, named.tone.name);
        counts[key] = (counts[key] ?? 0) + 1;
        if (!meanings.containsKey(key)) {
          final meaning = aiSnapshotValue(
            column.legendOf?.call(item),
            AiSnapshotLimits.meaning,
          );
          if (meaning != null && meaning.isNotEmpty) meanings[key] = meaning;
        }
      }
    }
    final legend = [
      for (final entry in counts.entries)
        AiLegendEntry(
          column: entry.key.$1,
          value: entry.key.$2,
          color: entry.key.$3,
          tone: entry.key.$4,
          meaning: meanings[entry.key],
          count: entry.value,
        ),
    ]..sort((a, b) => b.count.compareTo(a.count));
    return AiTableSnapshot(
      totalRows: _serverPaged ? null : rows.length,
      visibleRows: rows.length,
      selectedRows: widget.selectable ? widget.selectedIds.length : null,
      columns: columns,
      rows: sample,
      legend: legend.take(AiSnapshotLimits.legend).toList(),
      flaggedCells: flagged.take(AiSnapshotLimits.flagged).toList(),
      truncated: rows.length > AiSnapshotLimits.rows || _serverPaged,
    );
  }

  List<AiPageAction> _aiActions(
    AiCaptureContext ctx,
    AiTableActionScope scope,
  ) {
    if (!mounted || widget.listItemBuilder != null) return const [];
    final l10n = ctx.l10n;
    final suffix = scope.suffix;
    String titled(String title) => scope.index > 1
        ? '$title${l10n.aiActionTableSuffix(scope.index)}'
        : title;
    final filterable = <String, MasterColumnDef<T>>{};
    for (final i in _visibleIndices) {
      final column = _columns[i];
      final label = aiSnapshotLabel(column.label);
      if (label != null && _ownsHeaderFilter(column)) {
        filterable.putIfAbsent(label, () => column);
      }
    }
    final rowCount = _displayItems.length;
    return [
      if (filterable.isNotEmpty)
        AiPageAction(
          name: 'filterTable$suffix',
          title: titled(l10n.aiActionFilterTable),
          kind: AiActionKind.view,
          params: [
            AiActionParam(
              'column',
              type: AiParamType.string,
              title: l10n.aiActionParamColumn,
              maxLength: AiSnapshotLimits.label,
              options: filterable.keys.take(60).toList(),
            ),
            AiActionParam(
              'value',
              type: AiParamType.string,
              title: l10n.aiActionParamFilterValue,
              required: false,
              maxLength: AiSnapshotLimits.value,
            ),
          ],
          handler: (call) async {
            final args = call.args;
            final label = args['column']! as String;
            final column = filterable[label];
            if (!mounted || column == null) {
              throw AiActionFailure(l10n.aiActionColumnMissing(label));
            }
            final wanted = (args['value'] as String? ?? '').trim();
            final local = _rowFacetsFor(column);
            final buckets =
                local?.buckets ?? widget.facets[column.key] ?? const [];
            String? value;
            if (wanted.isNotEmpty) {
              final match = buckets
                  .where(
                    (bucket) =>
                        bucket.display.trim().toLowerCase() ==
                            wanted.toLowerCase() ||
                        bucket.value == wanted,
                  )
                  .firstOrNull;
              if (match == null) {
                throw AiActionFailure(l10n.aiActionFilterValueMissing(wanted));
              }
              value = match.value;
            }
            if (local != null) {
              _aiRebuild(() {
                _rowFilters[column.key] = value;
                _persistQuery();
              });
            } else {
              _persistQuery(filterKey: column.key, filterValue: value);
              widget.onFilterChanged(column.key, value);
            }
            return null;
          },
        ),
      if (widget.selectable &&
          widget.onSelectedIdsChanged != null &&
          widget.onRowSelectionChanged == null &&
          rowCount > 0)
        AiPageAction(
          name: 'selectRows$suffix',
          title: titled(l10n.aiActionSelectRows),
          kind: AiActionKind.view,
          rowTable: this,
          params: [
            AiActionParam(
              'rows',
              type: AiParamType.string,
              title: l10n.aiActionParamRows,
              maxLength: 80,
              rowRef: true,
            ),
          ],
          // The records were bound when the question was sent (empty = clear).
          handler: (call) async {
            if (!mounted) throw AiActionFailure(l10n.aiActionRowsInvalid);
            final next = <String>{};
            for (final record in call.rows('rows')) {
              final id = widget.idOf?.call(record as T);
              if (id == null || id.isEmpty) {
                final no = _displayItems.indexOf(record as T) + 1;
                throw AiActionFailure(l10n.aiActionRowNotSelectable(no));
              }
              next.add(id);
            }
            widget.onSelectedIdsChanged!(next);
            _fsTick.value++;
            return null;
          },
        ),
      if (widget.onRowTap != null && rowCount > 0)
        AiPageAction(
          name: 'openRow$suffix',
          title: titled(l10n.aiActionOpenRow),
          kind: AiActionKind.view,
          rowTable: this,
          params: [
            AiActionParam(
              'row',
              type: AiParamType.integer,
              title: l10n.aiActionParamRow,
              minimum: 1,
              maximum: rowCount,
              rowRef: true,
            ),
          ],
          handler: (call) async {
            final row = call.args['row']! as int;
            final record = call.row('row');
            if (!mounted || record is! T) {
              throw AiActionFailure(l10n.aiActionRowMissing(row));
            }
            if (widget.canOpenRow?.call(record) == false) {
              throw AiActionFailure(l10n.aiActionRowNotOpenable(row));
            }
            widget.onRowTap!(record);
            return null;
          },
        ),
    ];
  }
}
