import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../widgets/basic_data_l10n.dart';
import '../widgets/master_data_table_view.dart';

/// One imported field. Empty import values must already have been resolved by
/// the import policy; this presentation object never decides what to persist.
@immutable
class ImportReviewCell {
  const ImportReviewCell({
    required this.key,
    required this.label,
    this.before,
    this.after,
  });

  final String key;
  final String label;
  final String? before;
  final String? after;

  bool get changed => (before ?? '') != (after ?? '');
}

/// A stable file-row identity, independent of a particular import endpoint.
/// Rows that only fill missing values are shown with [selectable] false.
@immutable
class ImportReviewRow {
  const ImportReviewRow({
    required this.rowKey,
    required this.sourceRow,
    required this.identityLabel,
    required this.matchReason,
    required this.cells,
    this.selectable = true,
  });

  final String rowKey;
  final int sourceRow;
  final String identityLabel;
  final String matchReason;
  final List<ImportReviewCell> cells;
  final bool selectable;
}

/// Returns conflict-row keys the user explicitly chose to replace. An empty
/// set means ignore conflicts (or confirm an import with automatic fills only).
/// Null means cancel the entire import; callers must not write anything.
Future<Set<String>?> showImportReviewPage(
  BuildContext context, {
  required String title,
  required List<ImportReviewRow> rows,
  String? description,
  String? ignoreDescription,
}) => Navigator.of(context).push<Set<String>>(
  MaterialPageRoute<Set<String>>(
    builder: (_) => ImportReviewPage(
      title: title,
      rows: rows,
      description: description,
      ignoreDescription: ignoreDescription,
    ),
  ),
);

/// Full-page review uses the same table, selection contract and floating
/// actions as the master-data pages. It performs no network or file writes.
class ImportReviewPage extends StatefulWidget {
  const ImportReviewPage({
    super.key,
    required this.title,
    required this.rows,
    this.description,
    this.ignoreDescription,
  });

  final String title;
  final List<ImportReviewRow> rows;
  final String? description;
  final String? ignoreDescription;

  @override
  State<ImportReviewPage> createState() => _ImportReviewPageState();
}

class _ImportReviewPageState extends State<ImportReviewPage> {
  Set<String> _selected = <String>{};
  final _ignored = <String>{};

  bool get _hasConflicts => widget.rows.any((row) => row.selectable);

  Set<String> get _eligibleKeys => {
    for (final row in widget.rows)
      if (row.selectable && !_ignored.contains(row.rowKey)) row.rowKey,
  };

  void _setSelection(Set<String> next) {
    setState(() => _selected = next.intersection(_eligibleKeys));
  }

  void _toggleIgnore(ImportReviewRow row) {
    setState(() {
      if (!_ignored.remove(row.rowKey)) {
        _ignored.add(row.rowKey);
        _selected.remove(row.rowKey);
      }
    });
  }

  void _finish(Set<String> selected) {
    Navigator.of(context).pop<Set<String>>(
      Set<String>.unmodifiable(selected.intersection(_eligibleKeys)),
    );
  }

  ImportReviewCell? _cellFor(ImportReviewRow row, String key) {
    for (final cell in row.cells) {
      if (cell.key == key) return cell;
    }
    return null;
  }

  String _displayValue(String? value, AppLocalizations l10n) =>
      value == null || value.isEmpty ? l10n.importReviewEmptyValue : value;

  Widget _buildValue(
    BuildContext context,
    ImportReviewCell? cell,
    AppLocalizations l10n,
  ) {
    if (cell == null) {
      return Tooltip(
        message: l10n.importReviewUnchanged,
        child: Text('—', semanticsLabel: l10n.importReviewUnchanged),
      );
    }
    if (!cell.changed) {
      return Text(_displayValue(cell.after ?? cell.before, l10n));
    }
    final before = _displayValue(cell.before, l10n);
    final after = _displayValue(cell.after, l10n);
    return _ImportReviewValue(
      before: before,
      after: after,
      oldValueLabel: l10n.importReviewOldValue,
      newValueLabel: l10n.importReviewNewValue,
    );
  }

  List<MasterColumnDef<ImportReviewRow>> _columns(AppLocalizations l10n) {
    final fields = <String, String>{};
    for (final row in widget.rows) {
      for (final cell in row.cells) {
        fields.putIfAbsent(cell.key, () => cell.label);
      }
    }
    return [
      MasterColumnDef(
        key: 'sourceRow',
        label: l10n.importReviewSourceRow,
        width: 88,
        type: 'number',
        columnSearchEnabled: false,
        value: (row) => '${row.sourceRow}',
      ),
      MasterColumnDef(
        key: 'identity',
        label: l10n.importReviewIdentity,
        width: 220,
        value: (row) => row.identityLabel,
      ),
      MasterColumnDef(
        key: 'reviewAction',
        label: l10n.importReviewAction,
        width: 164,
        columnSearchEnabled: false,
        value: (row) => !row.selectable
            ? l10n.importReviewAutomaticFill
            : _ignored.contains(row.rowKey)
            ? l10n.importReviewIgnored
            : _selected.contains(row.rowKey)
            ? l10n.importReviewSelected
            : l10n.importReviewPending,
        cellBuilderHandlesSemantics: true,
        cellBuilder: (context, row) {
          if (!row.selectable) return Text(l10n.importReviewAutomaticFill);
          final ignored = _ignored.contains(row.rowKey);
          return UtenButton(
            key: ValueKey('import-review-ignore-${row.rowKey}'),
            type: UtenButtonType.secondary,
            size: UtenButtonSize.small,
            icon: ignored ? Icons.undo : Icons.skip_next_outlined,
            onPressed: () => _toggleIgnore(row),
            child: Text(
              ignored
                  ? l10n.importReviewRestoreRow
                  : l10n.importReviewIgnoreRow,
            ),
          );
        },
      ),
      for (final field in fields.entries)
        MasterColumnDef(
          key: 'field:${field.key}',
          label: field.value,
          width: 280,
          value: (row) {
            final cell = _cellFor(row, field.key);
            if (cell == null) return '';
            if (!cell.changed) return cell.after ?? cell.before;
            return '${_displayValue(cell.before, l10n)}   '
                '${_displayValue(cell.after, l10n)}';
          },
          cellBuilderHandlesSemantics: true,
          cellBuilder: (context, row) =>
              _buildValue(context, _cellFor(row, field.key), l10n),
        ),
      MasterColumnDef(
        key: 'matchReason',
        label: l10n.importReviewMatchReason,
        width: 200,
        value: (row) => row.matchReason,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = basicDataL10n(context);
    final theme = Theme.of(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: UtenAppBar(
            title: widget.title,
            leading: UtenBackButton(
              onPressed: () => Navigator.of(context).pop(),
            ),
            showPagePermissionAction: false,
          ),
          body: SafeArea(
            child: UtenContentContainer.wide(
              selectable: false,
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Bound explanatory copy so 200% text still leaves the full-page
                  // table usable. Its contents remain scrollable and selectable.
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * 0.24,
                    ),
                    child: SingleChildScrollView(
                      child: SelectionArea(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (widget.description?.isNotEmpty == true) ...[
                              Text(
                                widget.description!,
                                style: theme.textTheme.bodyMedium,
                              ),
                              const SizedBox(height: UtenSpacing.s8),
                            ],
                            Text(
                              _hasConflicts
                                  ? l10n.importReviewLegend
                                  : l10n.importReviewFillLegend,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (_hasConflicts) ...[
                              const SizedBox(height: UtenSpacing.s8),
                              Text(
                                widget.ignoreDescription ??
                                    l10n.importReviewIgnoreExplanation,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  Expanded(
                    child: MasterDataTableView<ImportReviewRow>(
                      key: const ValueKey('import-review-table'),
                      columns: _columns(l10n),
                      items: widget.rows,
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      showPaginationControls: false,
                      showFullscreenToggle: false,
                      emptyMessage: l10n.importReviewNoRows,
                      selectable: true,
                      showSelectionColumn: _hasConflicts,
                      selectedIds: _selected,
                      idOf: (row) =>
                          row.selectable && !_ignored.contains(row.rowKey)
                          ? row.rowKey
                          : null,
                      rowKeyOf: (row) => row.rowKey,
                      rowWidgetKeyOf: (row) =>
                          ValueKey('import-review-row-${row.rowKey}'),
                      onSelectedIdsChanged: _setSelection,
                      unselectableLeadingBuilder: (_, row) => Tooltip(
                        message: row.selectable
                            ? l10n.importReviewIgnored
                            : l10n.importReviewAutomaticFill,
                        child: Icon(
                          row.selectable
                              ? Icons.skip_next
                              : Icons.playlist_add_check,
                          semanticLabel: row.selectable
                              ? l10n.importReviewIgnored
                              : l10n.importReviewAutomaticFill,
                        ),
                      ),
                      toolbarLeadingActions: _hasConflicts
                          ? [
                              UtenButton(
                                key: const ValueKey('import-review-select-all'),
                                type: UtenButtonType.secondary,
                                icon: Icons.done_all,
                                onPressed: _eligibleKeys.isEmpty
                                    ? null
                                    : () => _setSelection(_eligibleKeys),
                                child: Text(l10n.importReviewSelectAll),
                              ),
                            ]
                          : null,
                      bottomContentPadding:
                          UtenFloatingActionGroup.scrollClearance,
                      // The shared table owns UtenFloatingActionGroup, including
                      // its bounded-height handling and final-row clearance.
                      batchActionsBuilder: (context, selected) => [
                        if (_hasConflicts)
                          UtenButton(
                            key: const ValueKey('import-review-ignore-all'),
                            size: UtenButtonSize.large,
                            type: UtenButtonType.secondary,
                            icon: Icons.skip_next_outlined,
                            onPressed: () => _finish({}),
                            child: Text(l10n.importReviewIgnoreAll),
                          ),
                        UtenButton(
                          key: const ValueKey('import-review-confirm'),
                          size: UtenButtonSize.large,
                          icon: Icons.fact_check_outlined,
                          onPressed: _hasConflicts && selected.isEmpty
                              ? null
                              : () => _finish(selected),
                          child: Text(
                            _hasConflicts
                                ? l10n.importReviewReplaceSelected(
                                    selected.length,
                                  )
                                : l10n.importReviewConfirmFill,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Each complete value stays independently readable and selectable. A very
/// long value scrolls inside its half-cell instead of pushing the row identity
/// and checkbox below the viewport through the table's vertical alignment.
class _ImportReviewValue extends StatefulWidget {
  const _ImportReviewValue({
    required this.before,
    required this.after,
    required this.oldValueLabel,
    required this.newValueLabel,
  });

  final String before;
  final String after;
  final String oldValueLabel;
  final String newValueLabel;

  @override
  State<_ImportReviewValue> createState() => _ImportReviewValueState();
}

class _ImportReviewValueState extends State<_ImportReviewValue> {
  final _beforeScroll = ScrollController();
  final _afterScroll = ScrollController();

  @override
  void dispose() {
    _beforeScroll.dispose();
    _afterScroll.dispose();
    super.dispose();
  }

  Widget _value({
    required String text,
    required String label,
    required ScrollController controller,
    required TextStyle? style,
  }) => Expanded(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.2,
      ),
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: controller,
          primary: false,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: UtenSpacing.s8),
            child: Text(text, style: style, semanticsLabel: '$label: $text'),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final oldColor = dark ? UtenColors.errorOnDark : UtenColors.errorText;
    final newColor = dark ? UtenColors.successOnDark : UtenColors.successText;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _value(
          text: widget.before,
          label: widget.oldValueLabel,
          controller: _beforeScroll,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: oldColor,
            decoration: TextDecoration.lineThrough,
            decorationColor: oldColor,
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        _value(
          text: widget.after,
          label: widget.newValueLabel,
          controller: _afterScroll,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: newColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
