import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../features/basic_data/widgets/master_data_table_view.dart';
import '../../auth/permissions.dart';
import '../../models/paged_result.dart';
import '../../formatters/quantity_display.dart';
import '../../providers/sensitive_read_boundary_provider.dart';
import '../production_trace_models.dart';
import '../stock_ledger_models.dart';
import '../stock_ledger_repository.dart';

/// A demand/period allocation is one row. Reports remain separate evidence;
/// their product quantities are never summed across multiple material rows.
class GoodsProductionTraceView extends ConsumerStatefulWidget {
  const GoodsProductionTraceView({
    super.key,
    required this.goodsId,
    this.reloadTick = 0,
  });
  final String goodsId;
  final int reloadTick;

  @override
  ConsumerState<GoodsProductionTraceView> createState() => _TraceState();
}

class _TraceState extends ConsumerState<GoodsProductionTraceView> {
  String _direction = 'usage';
  PagedResult<GoodsProductionTraceRow>? _data;
  bool _loading = true;
  String? _error;
  int _request = 0;
  int _readEpoch = 0;
  ModalRoute<void>? _detailsRoute;

  @override
  void initState() {
    super.initState();
    ref.listenManual(sensitiveReadBoundaryProvider, (old, next) {
      if (old == next) return;
      ++_request;
      ++_readEpoch;
      _closeDetails();
      setState(() {
        _data = null;
        _error = null;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(1);
      });
    });
    _load(1);
  }

  void _closeDetails() {
    final route = _detailsRoute;
    _detailsRoute = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = route?.navigator;
      if (route == null || navigator == null || !route.isActive) return;
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    ++_request;
    _closeDetails();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant GoodsProductionTraceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.goodsId != widget.goodsId ||
        oldWidget.reloadTick != widget.reloadTick) {
      _closeDetails();
      _data = null;
      _load(1);
    }
  }

  Future<void> _load(int page) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref
          .read(goodsStockLedgerRepositoryProvider)
          .productionTrace(widget.goodsId, direction: _direction, page: page);
      if (!mounted || request != _request) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error is ApiException ? error.message : '用料追溯读取失败，请重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      UtenFilterToolbar<String>(
        segments: const [
          UtenFilterSegment(value: 'usage', label: '用到哪些产品'),
          UtenFilterSegment(value: 'materials', label: '用了哪些物料'),
        ],
        selected: {_direction},
        onSelectionChanged: (direction) {
          if (direction == _direction) return;
          setState(() {
            _direction = direction;
            _data = null;
          });
          _load(1);
        },
      ),
      const SizedBox(height: 8),
      Expanded(
        child: MasterDataTableView<GoodsProductionTraceRow>(
          tableKey: 'goods.production_trace.$_direction',
          key: ValueKey(('goods-production-trace', _direction, _readEpoch)),
          primary: true,
          columns: _columns(),
          items: _data?.items ?? const [],
          rowKeyOf: (row) => row.id,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          onRowTap: _details,
          isLoading: _loading && _data == null,
          loadingMore: _loading && _data != null,
          error: _error,
          onRetry: () => _load(1),
          emptyMessage: '暂无权限范围内的实际用料记录',
          currentPage: _data?.page ?? 1,
          totalPages: _data?.totalPages ?? 1,
          paginationScope: (widget.goodsId, _direction, _readEpoch),
          onPageChange: _load,
        ),
      ),
    ],
  );

  List<MasterColumnDef<GoodsProductionTraceRow>> _columns() {
    TraceGoodsIdentity related(GoodsProductionTraceRow row) =>
        _direction == 'usage' ? row.product : row.material;
    return [
      MasterColumnDef(
        key: 'basis',
        label: '记录类型',
        width: 150,
        value: (row) => row.isPeriodic ? '期间分摊' : '按单用料',
      ),
      MasterColumnDef(
        key: 'goods',
        label: _direction == 'usage' ? '生产产品' : '使用物料',
        width: 220,
        value: (row) => related(row).goodsName ?? '—',
      ),
      MasterColumnDef(
        key: 'code',
        label: '编号',
        width: 120,
        value: (row) => related(row).goodsCode ?? '—',
      ),
      MasterColumnDef(
        key: 'color',
        label: '颜色',
        width: 90,
        value: (row) => related(row).colorName ?? '—',
      ),
      MasterColumnDef(
        key: 'workshop',
        label: '车间',
        width: 120,
        value: (row) => row.workshopName ?? '—',
      ),
      MasterColumnDef(
        key: 'plan',
        label: '生产计划',
        width: 170,
        value: (row) => row.planNo ?? row.segmentCode ?? '—',
      ),
      MasterColumnDef(
        key: 'issued',
        label: '已领数量',
        width: 120,
        value: (row) => _qty(row.issuedQty, row.material.unitName),
      ),
      MasterColumnDef(
        key: 'returned',
        label: '已退数量',
        width: 120,
        value: (row) => _qty(row.returnedQty, row.material.unitName),
      ),
      MasterColumnDef(
        key: 'consumed',
        label: '核销耗用',
        width: 130,
        value: (row) => _qty(row.consumedQty, row.material.unitName),
      ),
      MasterColumnDef(
        key: 'allocated',
        label: '期间分摊量',
        width: 130,
        value: (row) => _qty(row.allocatedQty, row.material.unitName),
      ),
      MasterColumnDef(
        key: 'reports',
        label: '生产日期',
        width: 170,
        value: (row) => _joined(row.reports.map((r) => r.billDate).nonNulls),
      ),
      MasterColumnDef(
        key: 'workers',
        label: '报工参与人',
        width: 180,
        value: (row) => _joined(row.reports.expand((r) => r.workers)),
      ),
      MasterColumnDef(
        key: 'sources',
        label: '入库来源单据',
        width: 190,
        value: (row) => row.receiptSources.isEmpty
            ? '暂无可显示来源'
            : row.receiptSources.map((r) => r.billNo ?? '—').toSet().join('、'),
      ),
    ];
  }

  Future<void> _details(GoodsProductionTraceRow row) async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    await showUtenAdaptivePanel<void>(
      context: context,
      drawerWidth: 640,
      builder: (panelContext) {
        _detailsRoute = ModalRoute.of<void>(panelContext);
        return Consumer(
          builder: (context, panelRef, _) {
            if (panelRef.watch(sensitiveReadBoundaryProvider) != boundary) {
              return const SizedBox.shrink();
            }
            return Column(
              children: [
                ListTile(
                  title: const Text('用料追溯'),
                  subtitle: Text(row.product.goodsName ?? row.planNo ?? '生产记录'),
                  trailing: IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(panelContext).pop(),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _goodsLink(panelContext, '产品', row.product),
                      _goodsLink(panelContext, '物料', row.material),
                      _fact('车间', row.workshopName),
                      _fact('数量依据', row.quantityBasis),
                      if (row.isPeriodic)
                        const Text('期间分摊量依据盘点结算分配，未记录逐件实测用量。'),
                      _fact('已领', _qty(row.issuedQty, row.material.unitName)),
                      _fact('已退', _qty(row.returnedQty, row.material.unitName)),
                      _fact(
                        '核销耗用',
                        _qty(row.consumedQty, row.material.unitName),
                      ),
                      _fact('损耗', _qty(row.lossQty, row.material.unitName)),
                      if (row.isPeriodic)
                        _fact(
                          '期间分摊',
                          _qty(row.allocatedQty, row.material.unitName),
                        ),
                      const Divider(),
                      Text(
                        '领退料单据',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      for (final doc in row.drawDocuments)
                        _document(
                          panelContext,
                          '${doc.billNo ?? '单据'}  ${doc.billDate ?? ''}',
                          doc.id == null || doc.docType == null
                              ? null
                              : RoutePath.stockDocDetail(doc.docType!, doc.id!),
                        ),
                      const Divider(),
                      Text(
                        '已审生产报工',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (row.reports.isEmpty) const Text('暂无可查看的已审报工记录'),
                      for (final report in row.reports) ...[
                        _document(
                          panelContext,
                          '${report.billNo ?? '报工'}  ${report.billDate ?? ''}',
                          report.id == null
                              ? null
                              : RoutePath.productionDailyReportDetail(
                                  report.id!,
                                ),
                        ),
                        _fact(
                          '本任务产量',
                          _qty(report.productQty, report.unitName),
                        ),
                        _fact(
                          '全单参与人',
                          report.workers.isEmpty
                              ? '—'
                              : report.workers.join('、'),
                        ),
                      ],
                      const Divider(),
                      Text(
                        '入库来源分配',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (row.receiptSources.isEmpty)
                        const Text('暂无可查看的入库来源分配；可能尚未绑定，或不在当前单据查看权限范围。'),
                      for (final receipt in row.receiptSources) ...[
                        _document(
                          panelContext,
                          '${receipt.billNo ?? '入库单'} · 单据日期 ${receipt.billDate ?? '—'}',
                          stockSourceDocPath(
                            sourceDocType: receipt.sourceDocType,
                            sourceDocId: receipt.id,
                            sourceDocCode: receipt.sourceDocCode,
                          ),
                        ),
                        _fact('供应商', receipt.supplierName ?? '—'),
                        _fact(
                          '入库分配量',
                          _qty(receipt.qty, row.material.unitName),
                        ),
                        if (receipt.sourceBasis != null)
                          _fact('来源依据', receipt.sourceBasis),
                      ],
                      if (row.material.goodsId != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () {
                              Navigator.of(panelContext).pop();
                              context.push(
                                RouteName.stockItemDetail(
                                  row.material.goodsId!,
                                  tab: 'ledger',
                                ),
                              );
                            },
                            child: const Text('查看物料出入库流水'),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    _detailsRoute = null;
  }

  Widget _goodsLink(
    BuildContext panelContext,
    String label,
    TraceGoodsIdentity identity,
  ) {
    final id = identity.goodsId;
    if (id == null || id == widget.goodsId) {
      return _fact(label, _identity(identity));
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: () {
          Navigator.of(panelContext).pop();
          context.push(RouteName.stockItemDetail(id, tab: 'trace'));
        },
        child: Text('$label：${_identity(identity)}'),
      ),
    );
  }

  Widget _document(BuildContext panelContext, String label, String? path) {
    final permissions = ref.read(currentPermissionsProvider);
    final canOpen =
        ref.read(isSuperAdminProvider) ||
        (path?.startsWith('/production/daily-reports/') == true
            ? permissions.contains(Perm.productionDailyReportView)
            : path?.startsWith('/warehouse/') == true
            ? permissions.contains(Perm.stockDocView)
            : path?.startsWith('/purchase/') == true
            ? permissions.contains(Perm.purchaseReceiptView)
            : permissions.contains(Perm.subcontractReceiptView));
    return path == null || !canOpen
        ? Text(label)
        : Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                Navigator.of(panelContext).pop();
                context.push(path);
              },
              child: Text(label),
            ),
          );
  }
}

String _identity(TraceGoodsIdentity identity) => [
  identity.goodsName,
  identity.goodsCode,
  identity.colorName,
].nonNulls.join(' · ');
String _qty(String? value, String? unit) {
  final text = formatExactQtyWithUnit(value, unit);
  return text.isEmpty ? '—' : text;
}

Widget _fact(String label, String? value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 4),
  child: Text('$label：${value?.isNotEmpty == true ? value : '—'}'),
);

String _joined(Iterable<String> values) {
  final text = values.toSet().join('、');
  return text.isEmpty ? '—' : text;
}
