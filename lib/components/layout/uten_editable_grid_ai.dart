part of 'uten_editable_grid.dart';

// AI 页面上下文登记(ADR-150)。只在用户向 AI 助手发问/确认卡片时被调用:
// 可见列(表头说明)、前 30 行显示文本(textOf -> frozenTextOf -> filterValueOf)、
// 按最终单元格底色聚合的状态图例、勾选数、整行标红、列定义给出的待核对原因
// (reviewReasonOf), 以及挂载中的单元格自己报告的黄框原因/错误/必填空
// (UtenTableCellHints + RequiredCellFrame)。行号 = 屏幕上的第几行(表头筛选后
// 可见行里从 1 起, 与 MasterDataTableView 同口径); 页面动作的行参数按同一编号
// 绑定到提问时那一行的记录(AiActionParam.rowRef + rowTable = 本表 controller)。
// 不参与 build, 不影响滚动与重建。

extension _UtenEditableGridAi<T extends EditableGridRow>
    on _UtenEditableGridState<T> {
  AiTableSource get _aiTableSource => AiTableSource(
    capture: _aiCapture,
    owner: () => widget.controller,
    records: () => [for (final row in _visibleRows()) row],
  );

  /// A column whose values never leave the app (marked or by label).
  bool _aiSecret(EditableGridColumn<T> column) =>
      column.aiSensitive || aiIsSensitiveLabel(column.label);

  String _aiText(EditableGridColumn<T> column, T row) =>
      column.textOf?.call(row) ??
      column.frozenTextOf?.call(row) ??
      column.filterValueOf?.call(row) ??
      '';

  /// Same final colour as the data cell (unselected).
  Color? _aiCellColor(EditableGridColumn<T> column, T row) =>
      column.cellColor?.call(context, row) ??
      (utenIsStatusColumn(column.key, column.label)
          ? udenStatusBadgeCellColor(
              context,
              utenStatusLabelType(_aiText(column, row)),
            )
          : null);

  AiTableSnapshot? _aiCapture(AiCaptureContext ctx) {
    if (!mounted) return null;
    final all = widget.controller.rows;
    final rows = _visibleRows();
    final visible = _visibleColumnIndices;
    final shown = visible.take(AiSnapshotLimits.columns).toList();
    // Screen position among the rows the header filters leave visible.
    final numbers = <Object, int>{
      for (var i = 0; i < rows.length; i++) rows[i]: i + 1,
    };
    // Row text for flagged cells: first two non-empty columns, never a
    // withheld one (a user may move a sensitive column to the front).
    String rowLabel(T row) {
      final parts = <String>[];
      for (final i in visible) {
        if (_aiSecret(_columns[i])) continue;
        final text = aiSnapshotValue(_aiText(_columns[i], row)) ?? '';
        if (text.isEmpty) continue;
        parts.add(text);
        if (parts.length == 2) break;
      }
      return aiSnapshotValue(parts.join(' ')) ?? '';
    }

    final sample = <AiTableRow>[
      for (final row in rows.take(AiSnapshotLimits.rows))
        AiTableRow(
          no: numbers[row] ?? 1,
          cells: [
            for (final i in shown)
              aiSnapshotValue(_aiText(_columns[i], row)) ?? '',
          ],
          selected: widget.controller.isSelected(row),
          flagged: row.flagged,
        ),
    ];
    final counts = <(String, String, String, String), int>{};
    final meanings = <(String, String, String, String), String>{};
    final flagged = <AiFlaggedCell>[];
    final seen = <(int, String?, AiCellState)>{};
    void flag(
      T row,
      String? column,
      AiCellState state,
      String? value,
      String? reason,
    ) {
      final no = numbers[row];
      if (no == null || !seen.add((no, column, state))) return;
      flagged.add(
        AiFlaggedCell(
          rowNo: no,
          rowLabel: rowLabel(row),
          column: column,
          value: value == null ? null : aiSnapshotValue(value),
          state: state,
          reason: aiSnapshotValue(reason, AiSnapshotLimits.info),
        ),
      );
    }

    for (final row in rows) {
      if (row.flagged) flag(row, null, AiCellState.flagged, null, null);
    }
    for (final i in visible) {
      final column = _columns[i];
      final label = aiSnapshotLabel(column.label);
      if (label == null) continue;
      final secret = _aiSecret(column);
      for (final row in rows) {
        final reason = column.reviewReasonOf?.call(row);
        if (reason != null && reason.isNotEmpty) {
          flag(
            row,
            label,
            AiCellState.review,
            secret ? null : _aiText(column, row),
            reason,
          );
        }
        if (secret ||
            (column.cellColor == null &&
                !utenIsStatusColumn(column.key, column.label))) {
          continue;
        }
        final named = utenNamedColor(_aiCellColor(column, row));
        final value = aiSnapshotValue(_aiText(column, row));
        if (named == null || value == null || value.isEmpty) continue;
        final key = (label, value, named.name, named.tone.name);
        counts[key] = (counts[key] ?? 0) + 1;
        if (!meanings.containsKey(key)) {
          final meaning = aiSnapshotValue(
            column.legendOf?.call(row),
            AiSnapshotLimits.meaning,
          );
          if (meaning != null && meaning.isNotEmpty) meanings[key] = meaning;
        }
      }
    }
    // Facts reported by mounted cells (yellow review frames, in-cell errors,
    // red required-empty frames) in the visible columns.
    final byLabel = <String, EditableGridColumn<T>>{
      for (final i in visible) _columns[i].label: _columns[i],
    };
    final visibleRows = rows.toSet();
    for (final (row, column, fact) in _aiCells.facts()) {
      final def = byLabel[column];
      if (row is! T || def == null || !visibleRows.contains(row)) continue;
      final label = aiSnapshotLabel(column);
      final secret =
          def.aiSensitive || (label != null && aiIsSensitiveLabel(label));
      flag(
        row,
        label,
        fact.state,
        secret ? null : _aiText(def, row),
        fact.reason,
      );
    }
    flagged.sort((a, b) => a.rowNo.compareTo(b.rowNo));
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
      totalRows: all.length,
      visibleRows: rows.length,
      selectedRows: widget._showSelect ? widget.controller.selectedCount : null,
      columns: [
        for (final i in shown)
          AiTableColumn(
            label: aiSnapshotLabel(_columns[i].label) ?? '',
            info: aiSnapshotValue(
              _columns[i].headerInfo,
              AiSnapshotLimits.info,
            ),
            sensitive: _columns[i].aiSensitive,
          ),
      ],
      rows: sample,
      legend: legend.take(AiSnapshotLimits.legend).toList(),
      flaggedCells: flagged.take(AiSnapshotLimits.flagged).toList(),
      truncated: rows.length > AiSnapshotLimits.rows,
    );
  }
}
