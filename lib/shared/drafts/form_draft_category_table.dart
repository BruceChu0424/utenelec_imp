import '../platform_tables/platform_table_binding.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_context_menu.dart';
import '../../core/ui/app_notification.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../components/layout/uten_filter_toolbar.dart';
import '../../components/feedback/uten_segment_badge_label.dart';
import '../../core/theme/uten_tokens.dart';
import '../../features/basic_data/widgets/master_data_table_view.dart';
import '../../features/basic_data/models/master_facet.dart';
import 'form_draft_category.dart';
import 'form_draft_store.dart';
import 'form_draft_catalog.dart';
import 'draft_workspace_sources.dart' show formDraftCategoryLabel;

export 'form_draft_category.dart';

class FormDraftCategoryRow<T> {
  const FormDraftCategoryRow({this.record, this.draft});
  final T? record;
  final FormDraft? draft;
  bool get isLocal => record == null;
}

Future<void> deleteFormDrafts(
  BuildContext context,
  WidgetRef ref,
  Iterable<FormDraft> values,
) async {
  final drafts = values.toList();
  if (drafts.isEmpty) return;
  if (drafts.any((draft) => draft.hasUnknownSubmission)) {
    context.appWarning(formDraftUnknownSubmissionMessage);
    return;
  }
  final store = ref.read(formDraftsProvider.notifier);
  final owner = store.ownerKey;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(drafts.length == 1 ? '删除草稿？' : '删除所选 ${drafts.length} 份草稿？'),
      content: const Text('删除后将无法继续填写这些内容。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  if (store.ownerKey != owner) {
    context.appError('登录身份已变化，请重新打开草稿列表');
    return;
  }
  try {
    bool current(FormDraft draft) {
      final latest = ref
          .read(formDraftsProvider)
          .where((value) => value.id == draft.id)
          .firstOrNull;
      return latest != null &&
          latest.revision == draft.revision &&
          !latest.hasUnknownSubmission;
    }

    if (!drafts.every(current)) throw const FormDraftConflict();
    for (final draft in drafts) {
      if (!context.mounted || store.ownerKey != owner) {
        throw StateError('登录身份已变化');
      }
      if (!current(draft)) throw const FormDraftConflict();
      await store.delete(draft.id, expectedRevision: draft.revision);
    }
  } catch (error) {
    if (context.mounted) context.appError('草稿删除失败：$error');
  }
}

/// Render local and server drafts in the SAME category/table, preserving the
/// original typed server callbacks. A local row never becomes a fake server DTO.
class FormDraftCategoryTable<T> extends ConsumerStatefulWidget {
  const FormDraftCategoryTable({
    super.key,
    required this.scope,
    required this.table,
    this.formalId,
    this.localValue,
    this.search = '',
    this.localPredicate,
    this.includeConfirmedWithoutRecord = false,
  });
  final FormDraftCategoryScope scope;
  final MasterDataTableView<T> table;
  final String? Function(T)? formalId;
  final String? Function(FormDraft, String)? localValue;
  final String search;
  final bool Function(FormDraft)? localPredicate;
  final bool includeConfirmedWithoutRecord;
  @override
  ConsumerState<FormDraftCategoryTable<T>> createState() =>
      _FormDraftCategoryTableState<T>();
}

class _FormDraftCategoryTableState<T>
    extends ConsumerState<FormDraftCategoryTable<T>> {
  final _localSelected = <String>{};
  static const _prefix = 'form-draft:';
  @override
  void didUpdateWidget(covariant FormDraftCategoryTable<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scope != oldWidget.scope ||
        widget.search != oldWidget.search ||
        widget.table.paginationScope != oldWidget.table.paginationScope) {
      _localSelected.clear();
    }
  }

  String? _id(T item) =>
      widget.formalId?.call(item) ??
      widget.table.rowKeyOf?.call(item) ??
      widget.table.idOf?.call(item);
  String? _value(FormDraft draft, String key) {
    final override = widget.localValue?.call(draft, key);
    if (override != null) return override;
    final canonical = formDraftFieldKey(key);
    final ids = formDraftColumnRawValues(draft, key);
    final buckets = widget.table.facets[key] ?? widget.table.facets[canonical];
    if (buckets != null && ids.isNotEmpty) {
      final labels = [
        for (final bucket in buckets)
          if (ids.contains(bucket.value)) bucket.display,
      ];
      if (labels.isNotEmpty) return labels.join('、');
    }
    if (canonical.endsWith('Id') && ids.isNotEmpty) {
      final header = formDraftHeader(draft);
      final label = header[canonical.replaceFirst(RegExp(r'Id$'), 'Name')];
      return label is String && label.isNotEmpty ? label : '已选择';
    }
    return formDraftColumnValue(draft, key);
  }

  void _open(FormDraft draft) => context.push(draft.resumeLocation);

  bool _matches(FormDraft draft) {
    if (widget.localPredicate?.call(draft) == false) return false;
    final text = widget.search.trim().toLowerCase();
    if (text.isNotEmpty &&
        ![
          draft.title,
          ...widget.table.columns.map((c) => _value(draft, c.key) ?? ''),
        ].join(' ').toLowerCase().contains(text)) {
      return false;
    }
    for (final filter in widget.table.filters.entries) {
      final expected = filter.value;
      if (expected == null ||
          expected.isEmpty ||
          widget.table.externalFilterKeys.contains(filter.key)) {
        continue;
      }
      if (filter.key == 'status' || filter.key == 'stage') {
        continue; // category owns draft state
      }
      final rawValues = formDraftColumnRawValues(draft, filter.key);
      if (rawValues.isEmpty) {
        final text = formDraftColumnValue(draft, filter.key);
        if (text != null && text.isNotEmpty) rawValues.add(text);
      }
      if (expected == kMasterFilterNullValue) {
        if (rawValues.isNotEmpty) return false;
      } else if (!rawValues.contains(expected)) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final table = widget.table;
    final paginated = table.onPageChange != null;
    final formalItems = table.error == null ? table.items : <T>[];
    final drafts = ref.watch(formDraftCategoryProvider(widget.scope));
    // Keep the wrapper's runtime type stable while a paginated table appends.
    // Local drafts are outside server pagination and remain actionable above
    // the complete loaded sequence, including after reaching page two.
    if (drafts.isEmpty && table.onPageChange == null) return table;
    final recovering = <String, FormDraft>{
      for (final draft in drafts)
        for (final id in formDraftConfirmedIds(draft)) id: draft,
    };
    final local = (paginated || table.currentPage == 1 ? drafts : <FormDraft>[])
        .where(
          (draft) =>
              (formDraftConfirmedIds(draft).isEmpty ||
                  ((widget.includeConfirmedWithoutRecord ||
                          table.error != null) &&
                      !formalItems.any(
                        (item) =>
                            formDraftConfirmedIds(draft).contains(_id(item)),
                      ))) &&
              _matches(draft),
        )
        .toList();
    final localIds = {for (final draft in local) '$_prefix${draft.id}'};
    _localSelected.removeWhere((id) => !localIds.contains(id));
    final rows = <FormDraftCategoryRow<T>>[
      if (!paginated)
        for (final draft in local) FormDraftCategoryRow(draft: draft),
      for (final item in formalItems)
        FormDraftCategoryRow(record: item, draft: recovering[_id(item)]),
    ];
    if (table.onPageChange == null &&
        local.isEmpty &&
        !table.items.any((item) => recovering.containsKey(_id(item)))) {
      return table;
    }
    final protectedFormalIds = {
      for (final entry in recovering.entries)
        if (entry.value.hasUnknownSubmission) entry.key,
    };
    final selected = {
      ...table.selectedIds.where((id) => !protectedFormalIds.contains(id)),
      ..._localSelected,
    };
    final binding =
        table.platformBinding ??
        PlatformTableCatalogScope.resolve(
          context,
          PlatformTableDescriptor<T>(
            kind: 'master',
            tableKey: table.tableKey,
            columnKeys: table.columns.map((column) => column.key).toList(),
            rows: table.items,
          ),
        );

    return MasterDataTableView<FormDraftCategoryRow<T>>(
      rowVisible: table.rowVisible == null
          ? null
          : (row) => row.isLocal || table.rowVisible!(row.record as T),
      paginationScope: (widget.scope, widget.search, table.paginationScope),
      paginationRevision: table.paginationRevision,
      rowsController: table.rowsController?.adapt<FormDraftCategoryRow<T>>(
        (rows) =>
            rows.where((row) => !row.isLocal).map((row) => row.record as T),
      ),
      unpagedItems: [
        if (paginated)
          for (final draft in local) FormDraftCategoryRow<T>(draft: draft),
        for (final item in table.unpagedItems)
          FormDraftCategoryRow<T>(record: item, draft: recovering[_id(item)]),
      ],
      tableKey: table.tableKey,
      platformBinding: binding == null
          ? null
          : PlatformTableBinding<FormDraftCategoryRow<T>>(
              tableKey: binding.tableKey,
              scope: binding.scope,
              recordIdOf: (row) =>
                  row.isLocal ? null : binding.recordIdOf(row.record as T),
              canEditValues: binding.canEditValues,
              canEditRow: (row) =>
                  !row.isLocal &&
                  row.draft?.hasUnknownSubmission != true &&
                  (binding.canEditRow?.call(row.record as T) ?? true),
              snapshotOf: binding.snapshotOf == null
                  ? null
                  : (row) => row.isLocal
                        ? null
                        : binding.snapshotOf!(row.record as T),
              draftOf: binding.draftOf == null
                  ? null
                  : (row) =>
                        row.isLocal ? null : binding.draftOf!(row.record as T),
              factValuesOf: binding.factValuesOf == null
                  ? null
                  : (row) => row.isLocal
                        ? const {}
                        : binding.factValuesOf!(row.record as T),
              factListenablesOf: binding.factListenablesOf == null
                  ? null
                  : (row) => row.isLocal
                        ? const []
                        : binding.factListenablesOf!(row.record as T),
              columnAliases: binding.columnAliases,
              defaultVisibleColumnKeys: binding.defaultVisibleColumnKeys,
              defaultColumnOrder: binding.defaultColumnOrder,
              revealPopulatedColumnKeys: binding.revealPopulatedColumnKeys,
            ),
      scrollingHeader: table.scrollingHeader,
      platformCellDecorator: table.platformCellDecorator == null
          ? null
          : (context, row, key, value, child) => row.record == null
                ? child
                : table.platformCellDecorator!(
                    context,
                    row.record as T,
                    key,
                    value,
                    child,
                  ),
      errorKey: table.errorKey,
      compactCards: table.compactCards,
      cardBelowWidth: table.cardBelowWidth,
      key: table.key,
      columns: [
        for (final column in table.columns)
          MasterColumnDef(
            key: column.key,
            label: column.label,
            width: column.width,
            type: column.type,
            sortable: column.sortable,
            filterFromRows: column.filterFromRows,
            info: column.info,
            defaultVisible: column.defaultVisible,
            exportDefinition: column.exportDefinition,
            cardRole: column.cardRole,
            cardRendersBuilder: column.cardRendersBuilder,
            exactValueOf: column.exactValueOf == null
                ? null
                : (row) => row.isLocal
                      ? null
                      : column.exactValueOf!(row.record as T),
            exactListenableOf: column.exactListenableOf == null
                ? null
                : (row) => row.isLocal
                      ? null
                      : column.exactListenableOf!(row.record as T),
            cellBuilderHandlesSemantics: column.cellBuilderHandlesSemantics,
            fillsCellHeight: column.fillsCellHeight,
            value: (row) => row.isLocal
                ? _value(row.draft!, column.key)
                : column.value(row.record as T),
            cellBuilder: (ctx, row) => row.isLocal
                ? Text(
                    _value(row.draft!, column.key) ?? '—',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  )
                : column.cellBuilder?.call(ctx, row.record as T) ??
                      Text(column.value(row.record as T) ?? '—'),
            cellColor: column.cellColor == null
                ? null
                : (ctx, row) => row.isLocal
                      ? null
                      : column.cellColor!(ctx, row.record as T),
          ),
      ],
      items: rows,
      facets: table.facets,
      nullCounts: table.nullCounts,
      filters: table.filters,
      externalFilterKeys: table.externalFilterKeys,
      onFilterChanged: table.onFilterChanged,
      onRowTap: (row) {
        if (row.draft != null) {
          _open(row.draft!);
        } else {
          table.onRowTap?.call(row.record as T);
        }
      },
      canOpenRow: (row) =>
          row.draft != null ||
          (table.canOpenRow?.call(row.record as T) ?? true),
      onSelectionChanged: table.onSelectionChanged == null
          ? null
          : (row) {
              if (!row.isLocal) table.onSelectionChanged!(row.record as T);
            },
      onSelectionCleared: table.onSelectionCleared,
      isSelected: table.isSelected == null
          ? null
          : (row) => !row.isLocal && table.isSelected!(row.record as T),
      rowMenuBuilder: (row) => row.isLocal
          ? [
              UtenMenuItem(
                label: '继续填写',
                icon: Icons.edit_outlined,
                onTap: () => _open(row.draft!),
              ),
              UtenMenuItem(
                label: row.draft!.hasUnknownSubmission ? '先核对提交' : '删除草稿',
                icon: Icons.delete_outline,
                destructive: true,
                enabled: !row.draft!.hasUnknownSubmission,
                onTap: () => deleteFormDrafts(context, ref, [row.draft!]),
              ),
            ]
          : [
              if (row.draft != null)
                UtenMenuItem(
                  label: '继续完成填写',
                  icon: Icons.edit_outlined,
                  onTap: () => _open(row.draft!),
                ),
              for (final entry
                  in table.rowMenuBuilder?.call(row.record as T) ??
                      <UtenContextMenuEntry>[])
                if (row.draft?.hasUnknownSubmission == true &&
                    entry is UtenMenuItem &&
                    entry.destructive)
                  UtenMenuItem(
                    label: '先核对提交',
                    icon: entry.icon,
                    destructive: true,
                    enabled: false,
                    onTap: () =>
                        context.appWarning(formDraftUnknownSubmissionMessage),
                  )
                else
                  entry,
            ],
      canShowRowMenu: (row) =>
          row.draft != null ||
          (table.canShowRowMenu?.call(row.record as T) ??
              table.rowMenuBuilder != null),
      selectable: table.selectable,
      idOf: (row) => row.isLocal
          ? '$_prefix${row.draft!.id}'
          : table.idOf?.call(row.record as T),
      rowKeyOf: (row) =>
          row.isLocal ? '$_prefix${row.draft!.id}' : _id(row.record as T),
      rowWidgetKeyOf: (row) => row.isLocal
          ? ValueKey('form-draft-row-${row.draft!.id}')
          : table.rowWidgetKeyOf?.call(row.record as T),
      selectedIds: selected,
      onSelectedIdsChanged:
          table.onSelectedIdsChanged == null &&
              table.batchActionsBuilder != null
          ? null
          : (next) {
              setState(() {
                _localSelected
                  ..clear()
                  ..addAll(next.where((id) => id.startsWith(_prefix)));
              });
              table.onSelectedIdsChanged?.call(
                next
                    .where(
                      (id) =>
                          !id.startsWith(_prefix) &&
                          !protectedFormalIds.contains(id),
                    )
                    .toSet(),
              );
            },
      onRowSelectionChanged: table.onRowSelectionChanged == null
          ? null
          : (row, checked) {
              if (row.isLocal) {
                setState(() {
                  final id = '$_prefix${row.draft!.id}';
                  if (checked) {
                    _localSelected.add(id);
                  } else {
                    _localSelected.remove(id);
                  }
                });
              } else {
                if (row.draft?.hasUnknownSubmission == true && checked) return;
                table.onRowSelectionChanged!(row.record as T, checked);
              }
            },
      onClearSelection: () {
        setState(_localSelected.clear);
        table.onClearSelection?.call();
      },
      selectionSummaryCount: table.selectionSummaryCount == null
          ? null
          : table.selectionSummaryCount! + _localSelected.length,
      showSelectionSummary: table.showSelectionSummary,
      preserveSelectionOnContextMenu: table.preserveSelectionOnContextMenu,
      selectionStateOf: (row) =>
          !row.isLocal && row.draft?.hasUnknownSubmission == true
          ? null
          : row.isLocal
          ? _localSelected.contains('$_prefix${row.draft!.id}')
          : table.selectionStateOf?.call(row.record as T) ??
                selected.contains(_id(row.record as T)),
      unselectableLeadingBuilder: table.unselectableLeadingBuilder == null
          ? null
          : (ctx, row) => row.isLocal
                ? const SizedBox.shrink()
                : table.unselectableLeadingBuilder!(ctx, row.record as T),
      leadingOverlayBuilder: table.leadingOverlayBuilder == null
          ? null
          : (ctx, row) => row.isLocal
                ? null
                : table.leadingOverlayBuilder!(ctx, row.record as T),
      batchActionsBuilder: (ctx, ids) => [
        ...?table.batchActionsBuilder?.call(
          ctx,
          ids
              .where(
                (id) =>
                    !id.startsWith(_prefix) && !protectedFormalIds.contains(id),
              )
              .toSet(),
        ),
        // 纯草稿页（宿主表没有自家批量动作）删除按钮常驻：悬浮组（已选胶囊+
        // 按钮）恒在右下角、未选时按钮禁用但可见——2026-09-27 用户口径「已选
        // N 项放右下角悬浮」。业务列表保持原条件：选中草稿行才追加。
        if (table.batchActionsBuilder == null || _localSelected.isNotEmpty)
          UtenButton(
            type: UtenButtonType.danger,
            onPressed:
                _localSelected.isEmpty ||
                    local.any(
                      (draft) =>
                          _localSelected.contains('$_prefix${draft.id}') &&
                          draft.hasUnknownSubmission,
                    )
                ? null
                : () => deleteFormDrafts(
                    context,
                    ref,
                    local.where(
                      (d) => _localSelected.contains('$_prefix${d.id}'),
                    ),
                  ),
            onDisabledTap: () =>
                context.appWarning(formDraftUnknownSubmissionMessage),
            child: Text('删除填写草稿 (${_localSelected.length})'),
          ),
      ],
      rowColor: table.rowColor == null
          ? null
          : (row) => row.isLocal ? null : table.rowColor!(row.record as T),
      rowForegroundColor: table.rowForegroundColor == null
          ? null
          : (row) =>
                row.isLocal ? null : table.rowForegroundColor!(row.record as T),
      rowDecorationBuilder: table.rowDecorationBuilder == null
          ? null
          : (ctx, row, child) => row.isLocal
                ? child
                : table.rowDecorationBuilder!(ctx, row.record as T, child),
      leadingGroups: table.leadingGroups
          ?.map(
            (group) => MasterDataGroup<FormDraftCategoryRow<T>>(
              id: group.id,
              title: group.title,
              subtitle: group.subtitle,
              tint: group.tint,
              icon: group.icon,
              items: group.items
                  .map(
                    (item) => FormDraftCategoryRow<T>(
                      record: item,
                      draft: recovering[_id(item)],
                    ),
                  )
                  .toList(),
              total: group.total,
              detailLabel: group.detailLabel,
              loading: group.loading,
              error: group.error,
              onExpand: group.onExpand,
              onRetry: group.onRetry,
            ),
          )
          .toList(),
      bottomContentPadding: table.bottomContentPadding,
      sortColumn: table.sortColumn,
      sortAscending: table.sortAscending,
      onSortChange: table.onSortChange,
      isLoading: table.isLoading && rows.isEmpty && local.isEmpty,
      loadingMore: table.loadingMore,
      onLoadMore: table.onLoadMore,
      error: paginated || local.isEmpty ? table.error : null,
      onRetry: table.onRetry,
      emptyMessage: table.emptyMessage,
      currentPage: table.currentPage,
      totalPages: table.totalPages,
      onPageChange: table.onPageChange,
      summaryBar: table.error != null && local.isNotEmpty
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(child: Text('业务草稿暂时加载失败，已保存的填写草稿仍可继续。')),
                    TextButton(
                      onPressed: table.onRetry,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ],
            )
          : local.isNotEmpty && table.summaryBar != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '已生成单据合计（不含未提交草稿）',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                table.summaryBar!,
              ],
            )
          : table.summaryBar,
      summaryBarInline: table.summaryBarInline,
      toolbarActions: table.toolbarActions,
      toolbarLeadingActions: table.toolbarLeadingActions,
      embedded: table.embedded,
      singleTapRows: table.singleTapRows,
      primary: table.primary,
      virtualized: table.virtualized,
      showFullscreenToggle: table.showFullscreenToggle,
      showColumnChooser: table.showColumnChooser,
      enableTextSelection: table.enableTextSelection,
      stickyHeaderPinned: table.stickyHeaderPinned,
      onFullscreenChanged: table.onFullscreenChanged,
    );
  }
}

/// Whole category body for request/master-data drafts without a business list.
class FormDraftCategoryList extends ConsumerStatefulWidget {
  const FormDraftCategoryList({
    super.key,
    required this.scope,
    this.search = '',
    this.externalHeader,
    this.linkedScroll = true,
  });
  final FormDraftCategoryScope scope;
  final String search;

  /// 宿主前缀行（任务中心大类行等）：挂进折叠头随上滑一起收走（与
  /// WarehouseStockDocSegment 等分段视图同一口径：前缀后补 s12 间距）。
  final Widget? externalHeader;

  /// false = 宿主已自带联动容器（如资产与待摊工作台的面板区），本列表不再
  /// 自建折叠容器，分组行钉住、表体直接拾取外层注入的 PrimaryScrollController。
  final bool linkedScroll;
  @override
  ConsumerState<FormDraftCategoryList> createState() =>
      _FormDraftCategoryListState();
}

class _FormDraftCategoryListState extends ConsumerState<FormDraftCategoryList> {
  String _search = '';
  final _filters = <String, String?>{};

  String _category(FormDraft draft) {
    for (final entry in FormDraftCatalog.all.entries) {
      if (entry.value.groups(draft)) {
        return entry.key == 'goodsCost'
            ? Localizations.of<AppLocalizations>(
                    context,
                    AppLocalizations,
                  )?.costWorkspaceTitle ??
                  entry.value.title
            : formDraftCategoryLabel(draft);
      }
    }
    return formDraftCategoryLabel(draft);
  }

  @override
  Widget build(BuildContext context) {
    final search = '${widget.search} $_search'.trim();
    final drafts = ref.watch(formDraftCategoryProvider(widget.scope));
    String? value(FormDraft draft, String key) =>
        key == 'category' ? _category(draft) : formDraftColumnValue(draft, key);
    const filterKeys = {'category', 'title', 'billDate', 'remark', 'savedAt'};
    final facets = <String, List<MasterFacetBucket>>{};
    final nullCounts = <String, int>{};
    for (final key in filterKeys) {
      final counts = <String, int>{};
      for (final draft in drafts) {
        final text = value(draft, key);
        if (text == null || text.isEmpty) {
          nullCounts.update(key, (count) => count + 1, ifAbsent: () => 1);
        } else {
          counts.update(text, (count) => count + 1, ifAbsent: () => 1);
        }
      }
      facets[key] = [
        for (final entry in counts.entries)
          MasterFacetBucket(value: entry.key, count: entry.value),
      ];
    }
    final table = FormDraftCategoryTable<Object>(
      scope: widget.scope,
      search: search,
      localPredicate: (draft) => _filters.entries.every((filter) {
        final expected = filter.value;
        if (expected == null || expected.isEmpty) return true;
        final text = value(draft, filter.key);
        return expected == kMasterFilterNullValue
            ? text == null || text.isEmpty
            : text == expected;
      }),
      localValue: (draft, key) => key == 'category' ? _category(draft) : null,
      includeConfirmedWithoutRecord: true,
      table: MasterDataTableView<Object>(
        // New columns have their own layout revision; old saved layouts must
        // not hide the category column or reduce an empty table to its + menu.
        tableKey: 'shared.drafts.category.v2',
        paginationScope: Object.hashAll(
          _filters.entries.map((e) => (e.key, e.value)),
        ),
        primary: true,
        columns: [
          MasterColumnDef(
            key: 'category',
            label: '类别',
            width: 180,
            value: (_) => null,
          ),
          MasterColumnDef(
            key: 'title',
            label: '草稿',
            width: 300,
            value: (_) => null,
          ),
          MasterColumnDef(
            key: 'billDate',
            label: '单据日期',
            width: 140,
            value: (_) => null,
          ),
          MasterColumnDef(
            key: 'remark',
            label: '备注',
            width: 280,
            value: (_) => null,
          ),
          MasterColumnDef(
            key: 'savedAt',
            label: '保存时间',
            width: 180,
            value: (_) => null,
          ),
        ],
        items: const [],
        idOf: (_) => null,
        facets: facets,
        nullCounts: nullCounts,
        filters: _filters,
        externalFilterKeys: filterKeys,
        onFilterChanged: (key, value) => setState(() => _filters[key] = value),
        emptyMessage: '暂无草稿',
        selectable: true,
      ),
    );
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.externalHeader != null) ...[
          widget.externalHeader!,
          const SizedBox(height: UtenSpacing.s12),
        ],
        UtenFilterToolbar<String>(
          searchHint: '搜索类别、草稿或备注',
          onSearchChanged: (value) => setState(() => _search = value),
        ),
      ],
    );
    if (!widget.linkedScroll) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: UtenSpacing.s12),
          Expanded(child: table),
        ],
      );
    }
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: header,
      body: table,
    );
  }
}

/// Hubs without a pre-existing draft segment put drafts in a normal category.
/// The draft table is the category body, never a banner above all other lists.
class FormDraftCategoryHost extends ConsumerStatefulWidget {
  const FormDraftCategoryHost({
    super.key,
    required this.scope,
    required this.child,
    this.contentLabel = '任务中心',
    this.draftLabel = '草稿',
  });
  final FormDraftCategoryScope scope;
  final Widget child;
  final String contentLabel;
  final String draftLabel;
  @override
  ConsumerState<FormDraftCategoryHost> createState() =>
      _FormDraftCategoryHostState();
}

class _FormDraftCategoryHostState extends ConsumerState<FormDraftCategoryHost> {
  bool _drafts = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      UtenFilterToolbar<bool>(
        segments: [
          UtenFilterSegment(value: false, label: widget.contentLabel),
          UtenFilterSegment(
            value: true,
            label: widget.draftLabel,
            count: ref.watch(
              formDraftCategoryVisibleCountProvider(widget.scope),
            ),
            countForm: UtenSegmentCountForm.actionable,
          ),
        ],
        selected: {_drafts},
        onSelectionChanged: (value) => setState(() => _drafts = value),
      ),
      Expanded(
        child: _drafts
            ? FormDraftCategoryList(scope: widget.scope)
            : widget.child,
      ),
    ],
  );
}
