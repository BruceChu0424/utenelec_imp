import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../repositories/goods_quote_history_repository.dart';
import 'master_data_table_view.dart';

/// Finance-only commercial history, based on immutable quote revisions.
class GoodsQuoteHistoryTab extends ConsumerStatefulWidget {
  const GoodsQuoteHistoryTab({super.key, required this.goodsId});
  final String goodsId;

  @override
  ConsumerState<GoodsQuoteHistoryTab> createState() =>
      _GoodsQuoteHistoryTabState();
}

class _GoodsQuoteHistoryTabState extends ConsumerState<GoodsQuoteHistoryTab> {
  PagedResult<GoodsQuoteHistoryRow>? _result;
  GoodsQuoteHistoryRow? _selected;
  String? _error;
  bool _loading = false;
  int _generation = 0;

  bool get _canRead =>
      ref.read(isSuperAdminProvider) ||
      (ref.read(currentPermissionsProvider).contains(Perm.goodsView) &&
          ref
              .read(currentPermissionsProvider)
              .contains(Perm.salesQuoteFinanceView));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(covariant GoodsQuoteHistoryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.goodsId != widget.goodsId) {
      _result = null;
      _selected = null;
      _load(1);
    }
  }

  Future<void> _load(int page) async {
    if (!mounted || !_canRead) return;
    final generation = ++_generation;
    final identity = ref.read(sessionProvider);
    setState(() {
      _loading = true;
      _error = null;
      _selected = null;
    });
    try {
      final result = await ref
          .read(goodsQuoteHistoryRepositoryProvider)
          .list(widget.goodsId, page: page);
      if (!mounted ||
          generation != _generation ||
          !identical(identity, ref.read(sessionProvider)) ||
          !_canRead) {
        return;
      }
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          !identical(identity, ref.read(sessionProvider))) {
        return;
      }
      setState(() {
        _error = error is ApiException ? error.message : '加载报价记录失败，请重试';
        _loading = false;
      });
    }
  }

  void _open(GoodsQuoteHistoryRow row) {
    final permissions = ref.read(currentPermissionsProvider);
    final admin = ref.read(isSuperAdminProvider);
    if (!_canRead) return;
    // A quote does not necessarily have an order yet. Keep the original quote accessible.
    if (row.orderId.isNotEmpty &&
        !row.orderDeleted &&
        (admin || permissions.contains(Perm.salesOrderFinanceView))) {
      context.push(
        '/finance/sales-order-confirmations/${Uri.encodeComponent(row.orderId)}',
      );
    } else if (row.orderId.isNotEmpty &&
        !row.orderDeleted &&
        permissions.contains(Perm.salesOrderView)) {
      context.push('/sales/orders/${Uri.encodeComponent(row.orderId)}');
    } else {
      _showSnapshot(row);
    }
  }

  void _showSnapshot(GoodsQuoteHistoryRow row) {
    final identity = ref.read(sessionProvider);
    final server = ref.read(apiBaseUrlProvider);
    showDialog<void>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final permissions = ref.watch(currentPermissionsProvider);
          final authorized =
              ref.watch(isSuperAdminProvider) ||
              (permissions.contains(Perm.goodsView) &&
                  permissions.contains(Perm.salesQuoteFinanceView));
          final sameOwner =
              identical(identity, ref.watch(sessionProvider)) &&
              server == ref.watch(apiBaseUrlProvider);
          if (!authorized || !sameOwner) {
            return AlertDialog(
              title: const Text('当前身份或权限已变化'),
              content: const Text('请关闭后重新打开报价记录。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            );
          }
          return AlertDialog(
            title: Text('${row.text('billNo')} · 第 ${row.text('revision')} 版'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('本次报价历史快照'),
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
                    const SizedBox(height: UtenSpacing.s12),
                    const Text('此处保留当时记录，不受当前报价草稿或货品资料修改影响。'),
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
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    ref.listen(apiBaseUrlProvider, (previous, next) {
      if (previous == next) return;
      ++_generation;
      setState(() {
        _result = null;
        _selected = null;
        _loading = false;
        _error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
    });
    ref.listen(sessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      ++_generation;
      setState(() {
        _result = null;
        _selected = null;
        _loading = false;
        _error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
    });
    if (!_canRead) return const Center(child: Text('需要货品查看与报价财务核价查看权限'));
    final result = _result;
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('保留每次提交和财务核价时的本位币价格。双击查看关联订货单；没有可访问订单时查看本次报价快照。'),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: UtenSpacing.s12),
          Expanded(
            child: MasterDataTableView<GoodsQuoteHistoryRow>(
              tableKey: 'goods.quote-history',
              compactCards: true,
              columns: [
                MasterColumnDef(
                  key: 'billNo',
                  label: '报价单号',
                  width: 155,
                  value: (r) => r.text('billNo'),
                  cardRole: MasterColumnCardRole.title,
                ),
                MasterColumnDef(
                  key: 'occurredAt',
                  label: '时间',
                  width: 160,
                  value: (r) => utenFmtIsoTime(r.text('occurredAt')),
                ),
                MasterColumnDef(
                  key: 'clientName',
                  label: '客户',
                  width: 180,
                  value: (r) => r.text('clientName'),
                  cardRole: MasterColumnCardRole.subtitle,
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
                  value: (r) => r.text('revision'),
                ),
                MasterColumnDef(
                  key: 'action',
                  label: '环节',
                  width: 115,
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
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              onRowTap: _open,
              onSelectionChanged: (row) => setState(() => _selected = row),
              onSelectionCleared: () => setState(() => _selected = null),
              isLoading: _loading,
              emptyMessage: _error ?? '暂无已提交的报价记录',
              currentPage: result?.page ?? 1,
              totalPages: result?.totalPages ?? 0,
              paginationScope: widget.goodsId,
              onPageChange: _load,
              toolbarActions: [
                UtenButton(
                  onPressed: _selected == null ? null : () => _open(_selected!),
                  child: const Text('查看单据'),
                ),
                UtenButton(
                  onPressed: _loading ? null : () => _load(result?.page ?? 1),
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
