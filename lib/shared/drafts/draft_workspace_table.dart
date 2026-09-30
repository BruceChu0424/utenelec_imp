import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_context_menu.dart';
import '../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../components/layout/uten_filter_toolbar.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/data_write_revision.dart';
import '../../core/theme/uten_tokens.dart';
import '../../features/basic_data/widgets/master_data_table_view.dart';
import '../../features/basic_data/models/master_facet.dart';
import '../../features/warehouse/models/stock_doc.dart';
import '../../features/finance/providers/finance_name_provider.dart';
import '../../features/sales/providers/master_name_provider.dart';
import '../auth/permissions.dart';
import '../mixins/draft_bulk_delete_mixin.dart';
import '../providers/authenticated_scope_provider.dart';
import '../providers/draft_counts_provider.dart';
import '../providers/master_name_provider.dart';
import 'draft_workspace_sources.dart';
import 'draft_workspace_create_actions.dart';
import 'form_draft_category.dart';
import 'form_draft_store.dart';

export 'draft_workspace_sources.dart';

/// All draft categories share one table. Hosts supply their existing main
/// navigation/search; category filtering belongs to the first table header.
class DraftWorkspaceTable extends ConsumerStatefulWidget {
  const DraftWorkspaceTable({
    super.key,
    required this.kinds,
    required this.localScope,
    this.search = '',
    this.externalHeader,
    this.tableKey,
    this.showSearch = true,
    this.refreshRevision = 0,
    this.toolbarActions = const [],
    this.canSelectRow,
    this.handlesDeleteRow,
    this.extraBatchActions,
    this.selectionLocked = false,
  });
  final List<DraftDocKind> kinds;
  final FormDraftCategoryScope localScope;
  final String search;
  final Widget? externalHeader;
  final String? tableKey;
  final bool showSearch;
  final int refreshRevision;
  final bool selectionLocked;
  final List<Widget> toolbarActions;
  final bool Function(DraftWorkspaceRow row)? canSelectRow;
  final bool Function(DraftWorkspaceRow row)? handlesDeleteRow;
  final List<Widget> Function(
    BuildContext context,
    List<DraftWorkspaceRow> selected,
    Future<void> Function() reload,
    VoidCallback clearSelection,
  )?
  extraBatchActions;

  @override
  ConsumerState<DraftWorkspaceTable> createState() =>
      _DraftWorkspaceTableState();
}

/// A checkpoint overlays only its own document kind. A missing/erroring formal
/// source never hides locally recoverable content.
List<DraftWorkspaceRow> mergeDraftWorkspaceRows(
  Iterable<DraftWorkspaceRow> formal,
  Iterable<FormDraft> local, {
  String? Function(FormDraft draft)? resolveLocalParty,
}) {
  final drafts = local.toList();
  final matched = <String>{};
  final rows = <DraftWorkspaceRow>[];
  for (final row in formal) {
    FormDraft? checkpoint;
    for (final draft in drafts) {
      final sameKind =
          formDraftBusinessKind(draft) == row.kind?.name ||
          (formDraftBusinessKind(draft) == DraftDocKind.stockDocument.name &&
              row.stockType != null) ||
          (formDraftBusinessKind(draft) == DraftDocKind.stockCheck.name &&
              row.stockType == StockDocType.check) ||
          (formDraftBusinessKind(draft) == DraftDocKind.stockTransfer.name &&
              row.stockType == StockDocType.transfer);
      if (sameKind && formDraftConfirmedIds(draft).contains(row.id)) {
        checkpoint = draft;
        matched.add(draft.id);
        break;
      }
    }
    rows.add(checkpoint == null ? row : row.withRecovery(checkpoint));
  }
  return [
    for (final draft in drafts)
      if (!matched.contains(draft.id))
        DraftWorkspaceRow(
          kind: null,
          id: draft.id,
          category: formDraftCategoryLabel(draft),
          location: draft.resumeLocation,
          billNo: formDraftColumnValue(draft, 'title') ?? draft.title,
          billDate: formDraftColumnValue(draft, 'billDate'),
          party: _localParty(draft) ?? resolveLocalParty?.call(draft),
          // Incomplete editor amounts are not authoritative financial totals.
          deletable: true,
          local: draft,
        ),
    ...rows,
  ];
}

String? _localParty(FormDraft draft) {
  final header = formDraftHeader(draft);
  for (final key in [
    'supplierName',
    'clientName',
    'customerName',
    'workshopName',
    'departmentName',
    'accountName',
  ]) {
    final value = header[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}

class _DraftWorkspaceTableState extends ConsumerState<DraftWorkspaceTable>
    with DraftBulkDeleteMixin<DraftWorkspaceTable> {
  String _search = '';
  final _filters = <String, String?>{};
  Map<String, DraftWorkspaceRow> _visible = {};

  String? _resolveLocalParty(FormDraft draft) {
    final kind = formDraftBusinessKind(draft) ?? '';
    final finance = kind.startsWith('finance');
    final clientFirst = kind.startsWith('sales') || kind == 'financeReceipt';
    for (final field in [
      if (clientFirst) 'client',
      'supplier',
      if (!clientFirst) 'client',
      'department',
      'account',
      'warehouse',
    ]) {
      final ids = formDraftColumnRawValues(draft, field);
      if (ids.isEmpty) continue;
      final entries = switch (field) {
        'supplier' =>
          finance
              ? ref.read(financeNameServiceProvider).supplierEntries
              : ref.read(masterNameServiceProvider).supplierEntries,
        'client' =>
          finance
              ? ref.read(financeNameServiceProvider).clientEntries
              : ref.read(salesMasterNameServiceProvider).clientEntries,
        'department' => ref.read(masterNameServiceProvider).departmentEntries,
        'account' => ref.read(financeNameServiceProvider).accountEntries,
        _ => ref.read(masterNameServiceProvider).warehouseEntries,
      };
      return ids
          .map(
            (id) =>
                entries[id]?.trim().isNotEmpty == true ? entries[id]! : '已选择',
          )
          .toSet()
          .join('、');
    }
    return null;
  }

  List<DraftDocKind> get _kinds => widget.kinds
      .toSet()
      .where(
        (kind) =>
            !(widget.kinds.contains(DraftDocKind.stockDocument) &&
                (kind == DraftDocKind.stockTransfer ||
                    kind == DraftDocKind.stockCheck)),
      )
      .toList();

  @override
  void didUpdateWidget(covariant DraftWorkspaceTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshRevision != widget.refreshRevision) _refresh();
    if (!listEquals(oldWidget.kinds, widget.kinds) ||
        oldWidget.localScope != widget.localScope ||
        oldWidget.search != widget.search) {
      clearDraftSelection();
    }
  }

  Future<void> _refresh({bool reportFailure = false}) async {
    final kinds = _kinds;
    for (final kind in kinds) {
      ref.invalidate(draftWorkspaceRowsProvider(kind));
    }
    try {
      await Future.wait([
        for (final kind in kinds)
          ref.read(draftWorkspaceRowsProvider(kind).future),
      ]);
    } catch (_) {
      if (reportFailure) rethrow;
    }
  }

  bool _canDelete(DraftWorkspaceRow row) {
    final scope = ref.read(authenticatedScopeProvider);
    if (scope == null ||
        scope.readOnly ||
        !row.deletable ||
        widget.handlesDeleteRow?.call(row) == true) {
      return false;
    }
    if (row.kind == null) return true;
    return ref
        .read(currentPermissionsProvider)
        .contains(draftWorkspaceDeletePermission(row.kind!));
  }

  bool _canSelect(DraftWorkspaceRow row) {
    final scope = ref.read(authenticatedScopeProvider);
    return scope != null &&
        !scope.readOnly &&
        (_canDelete(row) || widget.canSelectRow?.call(row) == true);
  }

  Future<void> _delete(String key, DraftWorkspaceRow? row) async {
    if (row == null || !_canDelete(row)) {
      throw ApiException('CONFLICT', '草稿或删除权限已变化，请刷新后重试');
    }
    final store = ref.read(formDraftsProvider.notifier);
    final ownerKey = store.ownerKey;
    bool current() =>
        mounted &&
        selectedDraftIds.contains(key) &&
        store.ownerKey == ownerKey &&
        _canDelete(row);
    if (row.kind != null) {
      await deleteDraftWorkspaceRow(ref, row, stillCurrent: current);
    }
    if (row.local != null) {
      // A confirmed server delete can refresh away its formal row. Local
      // cleanup remains protected by its namespace and expected revision.
      if (!mounted || store.ownerKey != ownerKey) {
        throw ApiException('CONFLICT', '草稿所属身份已变化');
      }
      try {
        await store.delete(
          row.local!.id,
          expectedRevision: row.local!.revision,
        );
      } on FormDraftConflict {
        throw ApiException('CONFLICT', '填写内容已在其它页面更新，请刷新核对');
      }
    }
  }

  Future<void> _open(DraftWorkspaceRow row) async {
    if (widget.selectionLocked || draftDeleteBusy) return;
    await context.push(row.location);
    if (mounted) {
      try {
        await _refresh();
      } catch (_) {
        /* Source errors remain in the table. */
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Each successful delete advances this revision. Defer the resulting
    // refresh until the selected batch has finished so its next row remains
    // available for the same permission/status recheck.
    ref.listen(dataWriteRevisionProvider, (_, _) {
      if (!draftDeleteBusy) _refresh();
    });
    ref.watch(currentPermissionsProvider);
    ref.watch(authenticatedScopeProvider);
    final formal = <DraftWorkspaceRow>[];
    final failures = <String>[];
    var loading = false;
    for (final kind in _kinds) {
      final value = ref.watch(draftWorkspaceRowsProvider(kind));
      loading |= value.isLoading;
      // Loading a new identity must not retain a previous identity's rows.
      if (value.hasValue && !value.isLoading && !value.hasError) {
        formal.addAll(value.requireValue);
      }
      if (value.hasError) failures.add(draftWorkspaceKindLabel(kind));
    }
    final local = ref.watch(formDraftCategoryProvider(widget.localScope));
    final search = '${widget.search} $_search'.trim().toLowerCase();
    final searchable =
        mergeDraftWorkspaceRows(
              formal,
              local,
              resolveLocalParty: _resolveLocalParty,
            )
            .where(
              (row) =>
                  search.isEmpty ||
                  [
                        row.category,
                        row.billNo,
                        row.billDate,
                        row.party,
                        row.amount,
                        row.local == null
                            ? null
                            : formDraftColumnValue(row.local!, 'remark'),
                      ]
                      .whereType<String>()
                      .join(' ')
                      .toLowerCase()
                      .contains(search),
            )
            .toList();
    final productionOnly =
        _kinds.isNotEmpty &&
        _kinds.every(
          (kind) =>
              kind == DraftDocKind.productionPlan ||
              kind == DraftDocKind.productionDailyReport,
        );
    final columns = <MasterColumnDef<DraftWorkspaceRow>>[
      MasterColumnDef(
        key: 'category',
        label: '类别',
        width: 170,
        value: (row) => row.category,
      ),
      MasterColumnDef(
        key: 'billNo',
        label: '单据 / 草稿',
        width: 250,
        value: (row) => row.billNo ?? '未提交草稿',
      ),
      MasterColumnDef(
        key: 'billDate',
        label: '单据日期',
        width: 130,
        type: 'date',
        sortable: true,
        value: (row) => row.billDate,
      ),
      MasterColumnDef(
        key: 'party',
        label: productionOnly ? '车间 / 部门' : '往来单位 / 部门',
        width: 220,
        value: (row) => row.party,
      ),
      if (!productionOnly)
        MasterColumnDef(
          key: 'amount',
          label: '金额',
          width: 140,
          type: 'money',
          sortable: true,
          value: (row) => row.amount,
        ),
      MasterColumnDef(
        key: 'savedAt',
        label: '保存时间',
        width: 180,
        type: 'date',
        sortable: true,
        value: (row) => row.local == null
            ? null
            : formDraftColumnValue(row.local!, 'savedAt'),
      ),
    ];
    final facets = <String, List<MasterFacetBucket>>{};
    final nullCounts = <String, int>{};
    for (final column in columns) {
      final counts = <String, int>{};
      for (final row in searchable) {
        final value = column.value(row);
        if (value == null || value.isEmpty) {
          nullCounts.update(
            column.key,
            (count) => count + 1,
            ifAbsent: () => 1,
          );
        } else {
          counts.update(value, (count) => count + 1, ifAbsent: () => 1);
        }
      }
      facets[column.key] = [
        for (final entry in counts.entries)
          MasterFacetBucket(value: entry.key, count: entry.value),
      ];
    }
    final rows = searchable
        .where(
          (row) => columns.every((column) {
            final expected = _filters[column.key];
            if (expected == null || expected.isEmpty) return true;
            final value = column.value(row);
            return expected == kMasterFilterNullValue
                ? value == null || value.isEmpty
                : value == expected;
          }),
        )
        .toList();
    _visible = {for (final row in rows) row.key: row};
    final selected = selectedDraftIds
        .where((id) => _visible[id] != null && _canSelect(_visible[id]!))
        .toSet();
    // Bind the confirmation to the visible selection at click time. Another
    // mounted table may refresh a shared source while this batch is writing;
    // the mixin's identity/selection generation plus each latest detail and
    // local CAS revision still fence every write.
    final selectedRows = {for (final id in selected) id: _visible[id]!};
    final table = MasterDataTableView<DraftWorkspaceRow>(
      tableKey:
          '${widget.tableKey ?? 'shared.drafts.workspace.${_kinds.map((kind) => kind.name).join('.')}'}'
          '.v2',
      paginationScope: (
        widget.localScope,
        widget.search,
        _search,
        widget.kinds.join(','),
      ),
      primary: true,
      toolbarActions: [
        DraftWorkspaceCreateButton(kinds: _kinds),
        ...widget.toolbarActions,
      ],
      columns: columns,
      items: rows,
      facets: facets,
      nullCounts: nullCounts,
      filters: _filters,
      onFilterChanged: (key, value) {
        if (widget.selectionLocked || draftDeleteBusy) return;
        clearDraftSelection();
        setState(() => _filters[key] = value);
      },
      isLoading: loading && rows.isEmpty,
      emptyMessage: failures.isEmpty ? '暂无草稿' : '草稿暂未加载，请重试',
      rowKeyOf: (row) => row.key,
      rowWidgetKeyOf: (row) => ValueKey('draft-workspace-row-${row.key}'),
      onRowTap: _open,
      selectable: true,
      idOf: (row) => _canSelect(row) ? row.key : null,
      selectedIds: selected,
      onSelectedIdsChanged: widget.selectionLocked || draftDeleteBusy
          ? null
          : (ids) {
              if (widget.selectionLocked || draftDeleteBusy) return;
              selectDraftIds(ids);
            },
      onClearSelection: widget.selectionLocked || draftDeleteBusy
          ? null
          : () {
              if (widget.selectionLocked || draftDeleteBusy) return;
              clearDraftSelection();
            },
      rowMenuBuilder: (row) => [
        UtenMenuItem(
          label: row.local == null ? '查看草稿' : '继续填写',
          icon: Icons.edit_outlined,
          onTap: () => _open(row),
        ),
      ],
      batchActionsBuilder: (_, _) => [
        ...?widget.extraBatchActions?.call(
          context,
          [for (final id in selected) _visible[id]!],
          _refresh,
          clearDraftSelection,
        ),
        buildDraftDeleteButton(
          documentLabel: '',
          delete: (key) => _delete(key, selectedRows[key]),
          reload: () => _refresh(reportFailure: true),
          selectedIds: selected
              .where((id) => _canDelete(_visible[id]!))
              .toSet(),
        ),
      ],
    );
    final header = <Widget>[
      if (widget.externalHeader != null) widget.externalHeader!,
      if (widget.showSearch)
        UtenFilterToolbar<String>(
          searchHint: '搜索类别、单据、往来单位或部门',
          onSearchChanged: (value) {
            if (widget.selectionLocked || draftDeleteBusy) return;
            clearDraftSelection();
            setState(() => _search = value);
          },
        ),
      if (loading && rows.isNotEmpty)
        const LinearProgressIndicator(minHeight: 2),
      if (failures.isNotEmpty)
        Row(
          children: [
            Expanded(
              child: Text(
                '${failures.join('、')}加载失败，已保留可用草稿。',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            UtenButton(
              onPressed: () async {
                try {
                  await _refresh();
                } catch (_) {}
              },
              child: const Text('重试'),
            ),
          ],
        ),
    ];
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: header.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < header.length; i++) ...[
                  if (i > 0) const SizedBox(height: UtenSpacing.s12),
                  header[i],
                ],
              ],
            ),
      body: table,
    );
  }
}
