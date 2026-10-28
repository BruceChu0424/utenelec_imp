import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../repositories/goods_quote_history_repository.dart';
import 'master_data_table_view.dart';
import '../../../shared/search/table_column_query.dart';
import '../models/master_facet.dart';

/// Finance-only commercial history, based on immutable quote revisions.
class GoodsQuoteHistoryTab extends ConsumerStatefulWidget {
  const GoodsQuoteHistoryTab({super.key, required this.goodsId});
  final String goodsId;

  @override
  ConsumerState<GoodsQuoteHistoryTab> createState() =>
      _GoodsQuoteHistoryTabState();
}

class _GoodsQuoteHistoryTabState extends ConsumerState<GoodsQuoteHistoryTab>
    with
        NativeReadViewScopeMixin<GoodsQuoteHistoryTab>,
        ScopedPagedReadViewMixin<GoodsQuoteHistoryTab> {
  final _readViewportRows =
      MasterDataTableRowsController<GoodsQuoteHistoryRow>();
  int get _visibleReadPage => _result == null
      ? (_result?.page ?? 1)
      : (_readViewportRows.visiblePage ?? (_result?.page ?? 1));

  @override
  void scopedPagedReadOwnerChanged() {
    _clearHistory();
    if (mounted) {
      setState(() {
        _error = scopedPagedReadRejection?.message;
      });
    }
  }

  PagedResult<GoodsQuoteHistoryRow>? _result;
  GoodsQuoteHistoryRow? _selected;
  String? _error;
  bool _loading = false;
  TableColumnQuery _columnsQuery = const TableColumnQuery();
  String? _actionFilter;

  bool get _canRead =>
      ref.read(isSuperAdminProvider) ||
      (ref.read(currentPermissionsProvider).contains(Perm.goodsView) &&
          ref
              .read(currentPermissionsProvider)
              .contains(Perm.salesQuoteFinanceView));

  @override
  void initState() {
    super.initState();
    initializeNativeReadScope();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(covariant GoodsQuoteHistoryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.goodsId != widget.goodsId) {
      _columnsQuery = const TableColumnQuery();
      _actionFilter = null;
      _result = null;
      _selected = null;
      _load(1);
    }
  }

  @override
  void nativeReadOwnerChanged() => _clearHistory();

  @override
  void nativeReadPermissionChanged() => _clearHistory();

  @override
  Future<void> nativeReadReload() => _load(1);

  void _clearHistory() {
    if (!mounted) return;
    setState(() {
      _columnsQuery = const TableColumnQuery();
      _actionFilter = null;
      _result = null;
      _selected = null;
      _error = null;
      _loading = false;
    });
  }

  Future<void> _load(int page, {bool useCache = false}) async {
    if (!mounted || !_canRead) return;
    final readQuery = (widget.goodsId, _columnsQuery, _actionFilter);
    final acceptsRead = captureNativeRead(
      readQuery,
      () => (widget.goodsId, _columnsQuery, _actionFilter),
    );
    if (!acceptsRead()) return;
    setState(() {
      _loading = true;
      _error = null;
      _selected = null;
    });
    final repository = ref.read(goodsQuoteHistoryRepositoryProvider);
    final goodsId = widget.goodsId;
    final columns = _columnsQuery;
    final action = _actionFilter;
    Object pagingQuery() => [
      ref.read(goodsQuoteHistoryRepositoryProvider),
      widget.goodsId,
      _columnsQuery,
      _actionFilter,
    ];
    try {
      final result = await readScopedPage<GoodsQuoteHistoryRow>(
        page,
        query: pagingQuery(),
        currentQuery: pagingQuery,
        useCache: useCache,
        fetchPage: (target) => repository.list(
          goodsId,
          page: target,
          columns: {...columns.searches, 'search.action': ?action},
          sort: columns.sort,
          ascending: columns.ascending,
        ),
      );
      if (!acceptsRead() || !_canRead) return;
      acceptNativeRead();
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (error) {
      if (!acceptsRead() || !_canRead) return;
      setState(() {
        _result = null;
        _error = error is ApiException ? error.message : '加载报价记录失败，请重试';
        _loading = false;
      });
    }
  }

  Future<void> _open(GoodsQuoteHistoryRow row) async {
    if (!nativeReadAccessConfirmed) return;
    final ownsRead = captureNativeOwnership();
    final goodsId = widget.goodsId;
    final page = _visibleReadPage;
    final permissions = ref.read(currentPermissionsProvider);
    final admin = ref.read(isSuperAdminProvider);
    if (!_canRead) return;
    // A quote does not necessarily have an order yet. Keep the original quote accessible.
    if (row.orderId.isNotEmpty &&
        !row.orderDeleted &&
        (admin || permissions.contains(Perm.salesOrderFinanceView))) {
      await context.push(
        '/finance/sales-order-confirmations/${Uri.encodeComponent(row.orderId)}',
      );
    } else if (row.orderId.isNotEmpty &&
        !row.orderDeleted &&
        permissions.contains(Perm.salesOrderView)) {
      await context.push('/sales/orders/${Uri.encodeComponent(row.orderId)}');
    } else {
      _showSnapshot(row);
      return;
    }
    if (ownsRead() && goodsId == widget.goodsId && _canRead) await _load(page);
  }

  void _showSnapshot(GoodsQuoteHistoryRow row) {
    showDialog<void>(
      context: context,
      builder: (context) => trackNativeReadDialog(
        context,
        UtenAlertDialog(
          scrollable: false,
          title: Text('${row.text('billNo')} · 第 ${row.text('revision')} 版'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Flexible(child: Text('本次报价历史快照')),
                      UtenFieldHintIcon(
                        info: '此处保留当时记录，不受当前报价草稿或货品资料修改影响。',
                        dense: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  for (final field in const [
                    ('clientName', '客户'),
                    ('sellerName', '销售人员'),
                    ('qty', '数量'),
                    ('price', '单价（本位币）'),
                    ('discount', '折扣'),
                    ('amount', '金额（本位币）'),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: UtenSpacing.s4,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 120, child: Text(field.$2)),
                          Expanded(
                            child: Text(
                              row.text(field.$1).isEmpty
                                  ? '—'
                                  : row.text(field.$1),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Text('记录时间：${utenFmtIsoTime(row.text('occurredAt'))}'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
        readOnly: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    ref.listen(currentPermissionsProvider, (previous, next) {
      if (previous == next) return;
      invalidateNativeReadAccess();
      _clearHistory();
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
    });
    if (!_canRead) return const Center(child: Text('需要货品查看与报价财务核价查看权限'));
    if (!nativeReadAccessConfirmed) {
      if (_error != null) {
        return UtenEmpty(
          isError: true,
          message: _error!,
          actionLabel: '重试',
          onAction: () => _load(1),
        );
      }
      if (_loading) return const Center(child: CircularProgressIndicator());
      return nativeReadAccessNotice();
    }
    final result = _result;
    return Padding(
      // 水平贴 0：与货品详情页签栏、其他页签共用左缘（2026-10-24 口径）。
      padding: const EdgeInsets.fromLTRB(
        0,
        UtenSpacing.s16,
        0,
        UtenSpacing.s16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: UtenSpacing.s12),
          ],
          Expanded(
            child: MasterDataTableView<GoodsQuoteHistoryRow>(
              rowsController: _readViewportRows,
              expensiveRowMounts: false,
              tableKey: 'goods.quote-history',
              columns: [
                MasterColumnDef(
                  key: 'billNo',
                  label: '报价单号',
                  width: 155,
                  sortable: true,
                  value: (r) => r.text('billNo'),
                ),
                MasterColumnDef(
                  key: 'occurredAt',
                  label: '时间',
                  width: 160,
                  type: 'date',
                  columnSearchEnabled: true,
                  sortable: true,
                  value: (r) => utenFmtIsoTime(r.text('occurredAt')),
                ),
                MasterColumnDef(
                  key: 'clientName',
                  label: '客户',
                  width: 180,
                  value: (r) => r.text('clientName'),
                ),
                MasterColumnDef(
                  key: 'sellerName',
                  label: '销售人员',
                  width: 110,
                  value: (r) => r.text('sellerName'),
                ),
                MasterColumnDef(
                  key: 'revision',
                  label: '版本',
                  width: 75,
                  type: 'number',
                  columnSearchEnabled: true,
                  sortable: true,
                  value: (r) => r.text('revision'),
                ),
                MasterColumnDef(
                  key: 'action',
                  label: '环节',
                  width: 115,
                  facetSearchEnabled: true,
                  value: (r) => switch (r.text('action')) {
                    'SUBMIT' => '销售提交',
                    'FINANCE_EDIT' => '财务修改',
                    'CONFIRM' => '财务确认',
                    _ => r.text('action'),
                  },
                ),
                for (final column in const [
                  ('qty', '数量'),
                  ('price', '单价'),
                  ('discount', '折扣'),
                  ('amount', '金额'),
                ])
                  MasterColumnDef(
                    key: column.$1,
                    label: column.$2,
                    width: 115,
                    type: 'number',
                    columnSearchEnabled: true,
                    sortable: true,
                    info: '按该次快照的原始数值检索，不跨币种、单位或不同版本汇总。',
                    value: (r) =>
                        r.text(column.$1).isEmpty ? '—' : r.text(column.$1),
                  ),
                MasterColumnDef(
                  key: 'orderNo',
                  label: '当前关联订货单',
                  width: 160,
                  value: (r) => r.text('orderNo').isEmpty
                      ? '未关联订货单'
                      : '${r.text('orderNo')}${r.orderDeleted ? '（已删除）' : ''}',
                ),
              ],
              items: result?.items ?? const [],
              serverColumnSearch: true,
              facets: const {
                'action': [
                  MasterFacetBucket(value: 'SUBMIT', label: '销售提交', count: 0),
                  MasterFacetBucket(
                    value: 'FINANCE_EDIT',
                    label: '财务修改',
                    count: 0,
                  ),
                  MasterFacetBucket(value: 'CONFIRM', label: '财务确认', count: 0),
                ],
              },
              nullCounts: const {},
              filters: {'action': _actionFilter, ..._columnsQuery.searches},
              onFilterChanged: (key, value) {
                setState(() {
                  if (key == 'action') {
                    _actionFilter = value;
                  } else if (key.startsWith('search.')) {
                    _columnsQuery = _columnsQuery.search(key, value);
                  }
                });
                _load(1);
              },
              sortColumn: _columnsQuery.sort,
              sortAscending: _columnsQuery.ascending,
              onSortChange: (key, ascending) {
                setState(
                  () => _columnsQuery = _columnsQuery.sorted(key, ascending),
                );
                _load(1);
              },
              onRowTap: _open,
              onSelectionChanged: (row) => setState(() => _selected = row),
              onSelectionCleared: () => setState(() => _selected = null),
              isLoading: _loading,
              emptyMessage: _error ?? '暂无已提交的报价记录',
              currentPage: result?.page ?? 1,
              totalPages: result?.totalPages ?? 0,
              paginationScope: (widget.goodsId, _columnsQuery, _actionFilter),
              onPageChange: (page) => _load(page, useCache: true),
              toolbarActions: [
                UtenButton(
                  onPressed: _selected == null ? null : () => _open(_selected!),
                  child: const Text('查看单据'),
                ),
                UtenButton(
                  onPressed: _loading ? null : () => _load(_visibleReadPage),
                  child: const Text('刷新'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
