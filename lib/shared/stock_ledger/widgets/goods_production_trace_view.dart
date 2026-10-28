import '../../paging/scoped_paged_read.dart';
import '../../paging/scoped_paged_read_view_mixin.dart';
import 'package:flutter/material.dart';
import '../../../components/layout/uten_refresh_scope.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/router/permission_by_path.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../features/basic_data/widgets/master_data_table_view.dart';
import '../../../features/basic_data/models/master_facet.dart';
import '../../auth/permissions.dart';
import '../../models/paged_result.dart';
import '../../search/table_column_query.dart';
import '../../formatters/quantity_display.dart';
import '../../providers/sensitive_read_boundary_provider.dart';
import '../production_trace_models.dart';
import '../material_trace_models.dart';
import '../material_trace_repository.dart';
import '../stock_ledger_models.dart';
import '../stock_ledger_repository.dart';

/// A demand/period allocation is one row. Reports remain separate evidence;
/// their product quantities are never summed across multiple material rows.
class GoodsProductionTraceView extends ConsumerStatefulWidget {
  const GoodsProductionTraceView({
    super.key,
    required this.goodsId,
    this.reloadTick = 0,
    this.onTraceSubject,
    this.direction,
    this.showDirectionSelector = true,
  }) : subject = null,
       dateFrom = null,
       dateTo = null;

  const GoodsProductionTraceView.query({
    super.key,
    required this.subject,
    this.dateFrom,
    this.dateTo,
    this.reloadTick = 0,
    this.onTraceSubject,
    this.direction,
    this.showDirectionSelector = true,
  }) : goodsId = null;

  final String? goodsId;
  final MaterialTraceSubject? subject;
  final String? dateFrom, dateTo;
  final ValueChanged<MaterialTraceSubject>? onTraceSubject;
  final int reloadTick;

  /// A host page can place the same direction controls beside its result mode.
  /// The embedded goods-ledger view continues to own its direction by default.
  final String? direction;
  final bool showDirectionSelector;

  @override
  ConsumerState<GoodsProductionTraceView> createState() => _TraceState();
}

class _TraceState extends ConsumerState<GoodsProductionTraceView>
    with
        UtenRefreshParticipant<GoodsProductionTraceView>,
        ScopedPagedReadViewMixin<GoodsProductionTraceView> {
  final _readViewportRows =
      MasterDataTableRowsController<GoodsProductionTraceRow>();
  int get _visibleReadPage => _data == null
      ? (_data?.page ?? 1)
      : (_readViewportRows.visiblePage ?? (_data?.page ?? 1));

  @override
  void scopedPagedReadOwnerChanged() {
    ++_request;
    ++_readEpoch;
    _closeDetails();
    if (mounted) {
      setState(() {
        _data = null;
        _headers = const TableColumnQuery();
        _result = null;
        _loading = false;
      });
    }
    if (mounted) {
      setState(() {
        _error = scopedPagedReadRejection?.message;
      });
    }
  }

  String _direction = 'usage';
  TableColumnQuery _headers = const TableColumnQuery();
  PagedResult<GoodsProductionTraceRow>? _data;
  MaterialTraceResult? _result;
  bool _loading = true;
  String? _error;
  int _request = 0;
  int _readEpoch = 0;
  ModalRoute<void>? _detailsRoute;
  bool _openingDetails = false;

  @override
  void initState() {
    super.initState();
    _direction = widget.direction ?? 'usage';
    ref.listenManual(sensitiveReadBoundaryProvider, (old, next) {
      if (old == next) return;
      ++_request;
      ++_readEpoch;
      _closeDetails();
      setState(() {
        _data = null;
        _headers = const TableColumnQuery();
        _result = null;
        _error = null;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load(1);
      });
    });
    trackRefresh(_load(1));
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
        oldWidget.direction != widget.direction ||
        oldWidget.subject?.identity != widget.subject?.identity ||
        oldWidget.dateFrom != widget.dateFrom ||
        oldWidget.dateTo != widget.dateTo ||
        oldWidget.reloadTick != widget.reloadTick) {
      _closeDetails();
      if (oldWidget.goodsId != widget.goodsId ||
          oldWidget.direction != widget.direction ||
          oldWidget.subject?.identity != widget.subject?.identity ||
          oldWidget.dateFrom != widget.dateFrom ||
          oldWidget.dateTo != widget.dateTo) {
        _headers = const TableColumnQuery();
      }
      if (oldWidget.direction != widget.direction) {
        _direction = widget.direction ?? 'usage';
      }
      _data = null;
      _result = null;
      trackRefresh(_load(1));
    }
  }

  Future<void> _load(int page, {bool useCache = false}) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    final subject = widget.subject,
        goodsId = widget.goodsId,
        direction = _direction;
    final from = widget.dateFrom, to = widget.dateTo;
    final headers = _headers;
    final traceRepository = ref.read(materialTraceRepositoryProvider);
    final ledgerRepository = ref.read(goodsStockLedgerRepositoryProvider);
    Object pagingQuery() => [
      ref.read(materialTraceRepositoryProvider),
      ref.read(goodsStockLedgerRepositoryProvider),
      widget.goodsId,
      widget.subject?.identity,
      _direction,
      widget.dateFrom,
      widget.dateTo,
      widget.reloadTick,
      _headers,
    ];
    try {
      final cached = await readScopedPage<GoodsProductionTraceRow>(
        page,
        query: pagingQuery(),
        currentQuery: pagingQuery,
        useCache: useCache,
        fetchPage: (target) async {
          if (subject == null) {
            return ledgerRepository.productionTrace(
              goodsId!,
              direction: direction,
              page: target,
              columns: headers.searches,
              sort: headers.sort,
              ascending: headers.ascending,
            );
          }
          final result = await traceRepository.trace(
            subject: subject,
            direction: direction,
            dateFrom: from,
            dateTo: to,
            page: target,
            columns: headers.searches,
            sort: headers.sort,
            ascending: headers.ascending,
          );
          if (result.subject?.identity != subject.identity) {
            throw ApiException('INVALID_TRACE_RESPONSE', '追溯结果与当前对象不一致，请重新查询');
          }
          return PagedReadSnapshot<
            GoodsProductionTraceRow,
            MaterialTraceResult
          >(page: result.page, snapshot: result);
        },
      );
      final data = cached;
      final result =
          cached
              is PagedReadSnapshot<GoodsProductionTraceRow, MaterialTraceResult>
          ? cached.snapshot
          : null;
      if (!mounted || request != _request) return;
      setState(() {
        _data = data;
        _result = result;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      final revoked =
          error is ApiException &&
          ({401, 403, 404}.contains(error.httpStatus) ||
              {
                'UNAUTHORIZED',
                'FORBIDDEN',
                'NOT_FOUND',
                'INVALID_TRACE_RESPONSE',
              }.contains(error.code));
      if (revoked) _closeDetails();
      setState(() {
        if (revoked) {
          _data = null;
          _result = null;
        }
        _error = error is ApiException ? error.message : '用料追溯读取失败，请重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleEpoch = _readEpoch;
    final visibleBoundary = ref.read(sensitiveReadBoundaryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showDirectionSelector &&
            (widget.subject == null ||
                widget.subject!.isGoods ||
                widget.subject!.type == 'PRODUCTION_OUTPUT_LOT'))
          UtenFilterToolbar<String>(
            segments: const [
              UtenFilterSegment(value: 'usage', label: '用到哪些产品'),
              UtenFilterSegment(value: 'materials', label: '用了哪些物料'),
            ],
            selected: {_direction},
            onSelectionChanged: (direction) {
              if (direction == _direction) return;
              setState(() {
                _headers = const TableColumnQuery();
                _direction = direction;
                _data = null;
                _result = null;
              });
              _load(1);
            },
          ),
        if (_result case final result?) ...[
          if (result.sources.isNotEmpty) _sourceEvidence(result),
          if (result.coverageNotes.isNotEmpty)
            ExpansionTile(
              key: const Key('material-trace-coverage'),
              title: const Text('记录依据与范围'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.25,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final note in result.coverageNotes)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(note),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
        ],
        const SizedBox(height: 8),
        Expanded(
          child: MasterDataTableView<GoodsProductionTraceRow>(
            rowsController: _readViewportRows,
            expensiveRowMounts: false,
            tableKey: 'goods.production_trace.$_direction',
            key: ValueKey(('goods-production-trace', _direction, _readEpoch)),
            primary: true,
            columns: _columns(),
            items: _data?.items ?? const [],
            rowKeyOf: (row) => row.id,
            facets: const {
              'basis': [
                MasterFacetBucket(value: 'ORDER', label: '按单用料', count: 0),
                MasterFacetBucket(value: 'PERIODIC', label: '期间分摊', count: 0),
              ],
            },
            nullCounts: const {},
            filters: {
              ..._headers.searches,
              'basis': _headers.searches['search.basis'],
            },
            serverColumnSearchKeys: const {
              'goods',
              'code',
              'color',
              'workshop',
              'plan',
              'productionBatches',
              'issued',
              'returned',
              'consumed',
              'allocated',
              'reports',
              'workers',
              'sources',
            },
            headerFilterScopeDescription:
                '筛选当前追溯对象的全部关联行；数量仍按原任务或期间口径，来源凭证保持对象原范围。',
            onFilterChanged: (key, value) {
              if (key == 'basis') key = 'search.basis';
              if (!key.startsWith('search.')) return;
              _closeDetails();
              setState(() {
                _headers = _headers.search(key, value);
                _data = null;
              });
              trackRefresh(_load(1));
            },
            sortColumn: _headers.sort,
            sortAscending: _headers.ascending,
            onSortChange: (key, ascending) {
              _closeDetails();
              setState(() {
                _headers = _headers.sorted(key, ascending);
                _data = null;
              });
              trackRefresh(_load(1));
            },
            onRowTap: (row) {
              if (visibleEpoch == _readEpoch &&
                  visibleBoundary == ref.read(sensitiveReadBoundaryProvider)) {
                _details(row);
              }
            },
            isLoading: _loading && _data == null,
            loadingMore: _loading && _data != null,
            error: _error,
            onRetry: () => _load(_visibleReadPage),
            emptyMessage: _headers.searches.isNotEmpty
                ? '当前表头条件下没有匹配的关联行'
                : _result?.sources.isNotEmpty == true
                ? '已找到来源凭证，暂无当前范围内可显示的后续用料记录'
                : '暂无权限范围内的实际用料记录',
            currentPage: _data?.page ?? 1,
            totalPages: _data?.totalPages ?? 1,
            paginationScope: (
              widget.goodsId,
              widget.subject?.identity,
              widget.dateFrom,
              widget.dateTo,
              _direction,
              _readEpoch,
              _headers,
            ),
            onPageChange: (page) => _load(page, useCache: true),
          ),
        ),
      ],
    );
  }

  Widget _sourceEvidence(MaterialTraceResult result) => ExpansionTile(
    key: ValueKey(('material-trace-sources', widget.subject?.identity)),
    initiallyExpanded: result.page.items.isEmpty,
    title: Text(
      '来源凭证 · ${result.sources.length}${result.sourcesTruncated ? '+' : ''}',
    ),
    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    children: [
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.35,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final source in result.sources)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _sourceDocument(source),
                    if (_identity(source.goods).isNotEmpty)
                      Text(_identity(source.goods)),
                    if (source.relatedProduct != null)
                      Text('关联委外产品：${_identity(source.relatedProduct!)}'),
                    if (source.relatedOrderId != null)
                      _sourceDocument(
                        MaterialTraceSource.fromJson({
                          'type': 'SUBCONTRACT_ORDER',
                          'id': source.relatedOrderId,
                          'code': source.relatedOrderCode,
                        }),
                      ),
                    Text(
                      [
                        if (source.date != null) '单据日期 ${source.date!}',
                        if (source.warehouseName != null) source.warehouseName!,
                        if (source.supplierName != null) source.supplierName!,
                        if (source.status != null)
                          materialTraceStatusLabel(source.status!),
                      ].join(' · '),
                    ),
                    if (source.qty != null)
                      Text(
                        '${source.basis == 'FROZEN_BOM_ESTIMATE' ? '累计核销量（估算）' : '记录数量'}：${_qty(source.qty, source.unitName ?? source.goods.unitName)}',
                      ),
                    if (source.basis != null)
                      Text(materialTraceBasisLabel(source.basis!)),
                    if (source.note != null) Text(source.note!),
                  ],
                ),
              ),
            if (result.sourcesTruncated)
              const Text('来源较多，此处仅显示部分凭证，请进入原单查看完整明细。'),
          ],
        ),
      ),
    ],
  );

  Widget _sourceDocument(MaterialTraceSource source) {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final label =
        '${materialTraceSubjectTypeLabel(source.type ?? '')} · ${source.code ?? '未编号'}';
    final id = source.id;
    final path = id == null
        ? null
        : switch (source.type) {
            'PURCHASE_ORDER' => RoutePath.purchaseDocDetail('orders', id),
            'PURCHASE_RECEIPT' => RoutePath.purchaseDocDetail('receipts', id),
            'SUBCONTRACT_ORDER' => RoutePath.subcontractDocDetail('orders', id),
            'SUBCONTRACT_RECEIPT' => RoutePath.subcontractDocDetail(
              'receipts',
              id,
            ),
            'SUBCONTRACT_MATERIAL_ISSUE' ||
            'SUBCONTRACT_MATERIAL_CONSUMPTION' =>
              RoutePath.subcontractDocDetail('material-issues', id),
            'PRODUCTION_PLAN' => RoutePath.productionPlanDetail(id),
            'PRODUCTION_REPORT' => RoutePath.productionDailyReportDetail(id),
            'STOCK_DOC' when source.docType != null => RoutePath.stockDocDetail(
              source.docType!,
              id,
            ),
            _ => null,
          };
    if (path != null && _mayOpen(path)) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () {
            if (boundary == ref.read(sensitiveReadBoundaryProvider) &&
                _mayOpen(path)) {
              context.push(path);
            }
          },
          child: Text(label),
        ),
      );
    }
    return Text(label, style: Theme.of(context).textTheme.titleSmall);
  }

  List<MasterColumnDef<GoodsProductionTraceRow>> _columns() {
    TraceGoodsIdentity related(GoodsProductionTraceRow row) =>
        _direction == 'usage' ? row.product : row.material;
    return [
      MasterColumnDef(
        key: 'goods',
        label: _direction == 'usage' ? '生产产品' : '使用物料',
        width: 220,
        value: (row) => related(row).goodsName ?? '—',
        cellBuilder: (context, row) => _identityCell(
          context,
          related(row).goodsName ?? '—',
          [
            related(row).goodsCode,
            related(row).colorName,
          ].nonNulls.where((value) => value.isNotEmpty).join(' · '),
        ),
      ),
      MasterColumnDef(
        key: 'code',
        defaultVisible: false,
        label: '编号',
        width: 120,
        sortable: true,
        value: (row) => related(row).goodsCode ?? '—',
      ),
      MasterColumnDef(
        key: 'productionBatches',
        label: '生产批次 / 计划',
        width: 190,
        info: '按本行可见的产出批次或计划文字定位，保留批次与报工之间的原始对应关系。',
        value: (row) => _joined(
          row.reports
              .expand((report) => report.batches)
              .map((batch) => batch.displayName),
        ),
        cellBuilder: (context, row) {
          final batches = row.reports
              .expand((r) => r.batches)
              .map((b) => b.displayName)
              .where((name) => name.isNotEmpty)
              .toSet();
          final plan = row.planNo ?? row.segmentCode ?? '';
          return _identityCell(
            context,
            batches.isEmpty ? (plan.isEmpty ? '—' : plan) : batches.join('、'),
            batches.isEmpty ? '' : plan,
          );
        },
      ),
      MasterColumnDef(
        key: 'basis',
        label: '记录类型',
        width: 150,
        value: (row) => row.isPeriodic ? '期间分摊' : '按单用料',
      ),
      MasterColumnDef(
        key: 'color',
        defaultVisible: false,
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
        defaultVisible: false,
        label: '生产计划',
        width: 170,
        sortable: true,
        value: (row) => row.planNo ?? row.segmentCode ?? '—',
      ),
      MasterColumnDef(
        key: 'issued',
        label: '已领数量',
        width: 120,
        type: 'number',
        columnSearchEnabled: true,
        sortable: true,
        exactValueOf: (row) => row.issuedQty,
        info: '按本行物料基本单位的原始领料数量检索；可先定位物料，不跨单位汇总。',
        value: (row) => _qty(row.issuedQty, row.material.unitName),
      ),
      MasterColumnDef(
        key: 'returned',
        label: '已退数量',
        width: 120,
        type: 'number',
        columnSearchEnabled: true,
        sortable: true,
        exactValueOf: (row) => row.returnedQty,
        info: '按本行物料基本单位的原始退料数量检索；退料与核销耗用分别保留。',
        value: (row) => _qty(row.returnedQty, row.material.unitName),
      ),
      MasterColumnDef(
        key: 'consumed',
        label: '核销耗用',
        width: 130,
        type: 'number',
        columnSearchEnabled: true,
        sortable: true,
        exactValueOf: (row) => row.consumedQty,
        info: '检索已确认的核销耗用；没有可确认事实时为空，不当作零，也不按产出批次推算。',
        value: (row) => _qty(row.consumedQty, row.material.unitName),
      ),
      MasterColumnDef(
        key: 'allocated',
        label: '期间分摊量',
        width: 130,
        type: 'number',
        columnSearchEnabled: true,
        sortable: true,
        exactValueOf: (row) => row.allocatedQty,
        info: '期间盘点的分摊数量，与按单领退及核销是不同事实；不作为逐批实际耗用。',
        value: (row) => _qty(row.allocatedQty, row.material.unitName),
      ),
      MasterColumnDef(
        key: 'reports',
        label: '报工日期',
        width: 170,
        info: '一行可含多次报工，可按可见日期文字检索；对象日期范围仍决定原追溯口径。',
        value: (row) => _joined(row.reports.map((r) => r.billDate).nonNulls),
      ),
      MasterColumnDef(
        key: 'workers',
        defaultVisible: false,
        label: '报工参与人',
        width: 180,
        info: '按可见日报的参与人姓名检索，参与人属于整张日报，不代表逐人分摊的用量。',
        value: (row) => _joined(row.reports.expand((r) => r.workers)),
      ),
      MasterColumnDef(
        key: 'sources',
        defaultVisible: false,
        label: '入库来源单据',
        width: 190,
        info: '仅检索本行有权查看的明确入库来源；不按缺少关联的凭证推测原料批次。',
        value: (row) => row.receiptSources.isEmpty
            ? '暂无可显示来源'
            : row.receiptSources.map((r) => r.billNo ?? '—').toSet().join('、'),
      ),
    ];
  }

  Widget _identityCell(BuildContext context, String title, String subtitle) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.bodyMedium),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _details(GoodsProductionTraceRow row) async {
    if (_openingDetails) return;
    _openingDetails = true;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final ledgerPath = row.material.goodsId == null
        ? null
        : RouteName.stockItemDetail(row.material.goodsId!, tab: 'ledger');
    try {
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
                    subtitle: Text(
                      row.product.goodsName ?? row.planNo ?? '生产记录',
                    ),
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
                        _fact(
                          '已退',
                          _qty(row.returnedQty, row.material.unitName),
                        ),
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
                                : RoutePath.stockDocDetail(
                                    doc.docType!,
                                    doc.id!,
                                  ),
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
                          for (final batch in report.batches) ...[
                            _fact('生产批次', batch.displayName),
                            _fact(
                              '本批产量',
                              _qty(batch.productQty, batch.unitName),
                            ),
                            if (batch.id != null &&
                                widget.onTraceSubject != null)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                  onPressed: () {
                                    if (boundary !=
                                        ref.read(
                                          sensitiveReadBoundaryProvider,
                                        )) {
                                      return;
                                    }
                                    Navigator.of(panelContext).pop();
                                    widget.onTraceSubject!(
                                      MaterialTraceSubject(
                                        type: 'PRODUCTION_OUTPUT_LOT',
                                        id: batch.id!,
                                        code: batch.code ?? '',
                                        label: batch.displayName,
                                      ),
                                    );
                                  },
                                  child: const Text('继续追溯此批次'),
                                ),
                              ),
                          ],
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
                        if (ledgerPath != null && _mayOpen(ledgerPath))
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: () {
                                if (!mounted ||
                                    boundary !=
                                        ref.read(
                                          sensitiveReadBoundaryProvider,
                                        ) ||
                                    !_mayOpen(ledgerPath)) {
                                  return;
                                }
                                Navigator.of(panelContext).pop();
                                context.push(ledgerPath);
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
    } finally {
      _detailsRoute = null;
      _openingDetails = false;
    }
  }

  Widget _goodsLink(
    BuildContext panelContext,
    String label,
    TraceGoodsIdentity identity,
  ) {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final id = identity.goodsId;
    if (id == null || id == widget.goodsId) {
      return _fact(label, _identity(identity));
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: () {
          if (!mounted || boundary != ref.read(sensitiveReadBoundaryProvider)) {
            return;
          }
          Navigator.of(panelContext).pop();
          final follow = widget.onTraceSubject;
          if (follow != null) {
            follow(
              MaterialTraceSubject(
                type: 'GOODS',
                id: id,
                code: identity.goodsCode ?? '',
                label: identity.goodsName ?? '货品',
                goodsId: id,
                goodsCode: identity.goodsCode,
                goodsName: identity.goodsName,
              ),
            );
          } else {
            context.push(RouteName.stockItemDetail(id, tab: 'trace'));
          }
        },
        child: Text('$label：${_identity(identity)}'),
      ),
    );
  }

  Widget _document(BuildContext panelContext, String label, String? path) {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    return path == null || !_mayOpen(path)
        ? Text(label)
        : Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                if (!mounted ||
                    boundary != ref.read(sensitiveReadBoundaryProvider) ||
                    !_mayOpen(path)) {
                  return;
                }
                Navigator.of(panelContext).pop();
                context.push(path);
              },
              child: Text(label),
            ),
          );
  }

  bool _mayOpen(String path) {
    final permissions = ref.read(currentPermissionsProvider);
    if (ref.read(isSuperAdminProvider)) return true;
    final any = requiredAnyPermFor(path);
    final all = requiredAllPermsFor(path);
    return any != null &&
        any.any(permissions.contains) &&
        all.every(permissions.contains);
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
