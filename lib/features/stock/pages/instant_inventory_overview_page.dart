import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/china_datetime.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../../shared/models/paged_result.dart';
import '../models/instant_inventory_scope.dart';
import '../models/instant_inventory_summary.dart';
import '../models/stock_query.dart';
import '../repositories/stock_query_repository.dart';
import '../widgets/instant_inventory_overview_content.dart';

/// 可刷新、可直接打开的独立总览；行动清单与总览始终使用同一筛选范围。
class InstantInventoryOverviewPage extends ConsumerStatefulWidget {
  const InstantInventoryOverviewPage({
    super.key,
    this.scope = const InstantInventoryScope(),
    this.scopeLabel,
  });

  final InstantInventoryScope scope;
  final String? scopeLabel;

  @override
  ConsumerState<InstantInventoryOverviewPage> createState() =>
      _InstantInventoryOverviewPageState();
}

class _InstantInventoryOverviewPageState
    extends ConsumerState<InstantInventoryOverviewPage> {
  final _summaryRequests = LatestRequestGuard();
  final _riskRequests = LatestRequestGuard();
  final _riskDetailsAnchor = GlobalKey();
  double _contentWidth = 0;
  InstantInventorySummary? _summary;
  DateTime? _updatedAt;
  bool _loading = true;
  bool _backgroundRefresh = false;
  String? _error;
  String? _selectedRisk;
  PagedResult<InstantInventoryRow>? _riskPage;
  bool _riskLoading = false;
  String? _riskError;
  int _requestedRiskPage = 1;

  // 顺序是可解释的处理优先级，数量的计量单位不同，不用数量大小排紧急程度。
  static const _riskCounts = {
    'NEGATIVE_BALANCE': 'negative_balance_rows',
    'AWAITING_STOCK_IN': 'nonpositive_pending_stock_in_rows',
    'AWAITING_INSPECTION': 'nonpositive_pending_inspection_rows',
    'UNKNOWN_WEIGHT': 'stocked_weight_unknown_rows',
    'MISSING_UNIT': 'missing_unit_rows',
  };
  static const _riskTitles = {
    'NEGATIVE_BALANCE': '负库存核查清单',
    'AWAITING_STOCK_IN': '优先确认入库清单',
    'AWAITING_INSPECTION': '待检跟进清单',
    'UNKNOWN_WEIGHT': '库存重量待完善清单',
    'MISSING_UNIT': '计量待核清单',
  };
  static const _riskBasis = {
    'NEGATIVE_BALANCE': '至少一个仓库余额为负。下方数量是所选范围的汇总，可能为正，请进入货品查看各仓余额和流水。',
    'AWAITING_STOCK_IN': '汇总库存不大于零，同时有合格待入库货物。先核实入库任务和实物；这些货物尚未计入库存。',
    'AWAITING_INSPECTION': '汇总库存不大于零，同时有待检货物。结合实际需求跟进检验，检验放行前不能作为可用供应。',
    'UNKNOWN_WEIGHT': '非零库存中仍有重量未知。先核对对应仓库的称重与盘点记录，未称部分未计入重量总数。',
    'MISSING_UNIT':
        '计量依据尚未核实，账面数仅供核对，不能作为可用供应。请按原始证据核验计量依据；主档补单位或普通盘点差量不会自动解除历史计量待核。',
  };

  @override
  void initState() {
    super.initState();
    listenReadOwner(ref, () {
      _summaryRequests.begin();
      _riskRequests.begin();
      setState(() {
        _summary = null;
        _updatedAt = null;
        _riskPage = null;
        _selectedRisk = null;
        _error = null;
        _riskError = null;
        _loading = false;
        _backgroundRefresh = false;
        _riskLoading = false;
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  @override
  void didUpdateWidget(covariant InstantInventoryOverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!mapEquals(oldWidget.scope.toQuery(), widget.scope.toQuery())) {
      _selectedRisk = null;
      _updatedAt = null;
      _summary = null;
      _riskPage = null;
      _refresh();
    }
  }

  Future<PagedResult<InstantInventoryRow>> _fetch({
    int page = 1,
    int size = 1,
    String? attention,
  }) {
    final scope = widget.scope;
    return ref
        .read(stockQueryRepositoryProvider)
        .instantInventory(
          page: page,
          size: size,
          categoryId: scope.categoryId,
          warehouseId: scope.warehouseId,
          includeDefective: scope.includeDefective,
          includeLineSide: scope.includeLineSide,
          keyword: scope.keyword,
          includeRelated: scope.includeRelated,
          owningWarehouse: scope.owningWarehouse,
          owningWarehouseNull: scope.owningWarehouseNull,
          colorId: scope.colorId,
          series: scope.series,
          unitId: scope.unitId,
          attention: attention,
          sort: attention == 'NEGATIVE_BALANCE'
              ? 'negativeBalanceCount'
              : 'name',
          order: attention == 'NEGATIVE_BALANCE' ? 'desc' : 'asc',
        );
  }

  Future<void> _refresh({bool background = false}) async {
    final generation = _summaryRequests.begin();
    _riskRequests.begin();
    setState(() {
      _loading = true;
      _backgroundRefresh = background && _summary != null;
      _error = null;
      _riskLoading = false;
      if (!_backgroundRefresh) _riskPage = null;
      _riskError = null;
    });
    try {
      final page = await _fetch();
      if (!mounted || !_summaryRequests.isCurrent(generation)) return;
      final summary = InstantInventorySummary(
        totals: page.totals,
        totalRows: page.total,
      );
      final available = [
        for (final entry in _riskCounts.entries)
          if (summary.hasAnalysis && (summary.count(entry.value) ?? 0) > 0)
            entry.key,
      ];
      final previousRisk = _selectedRisk;
      final previousPage = _requestedRiskPage;
      setState(() {
        _summary = summary;
        _updatedAt = DateTime.now();
        if (!available.contains(_selectedRisk)) {
          _selectedRisk = available.firstOrNull;
          _riskPage = null;
        }
        _loading = false;
      });
      if (_selectedRisk != null) {
        await _loadRisk(
          _selectedRisk!,
          background && previousRisk == _selectedRisk ? previousPage : 1,
          background: background && previousRisk == _selectedRisk,
        );
      }
      if (mounted && _summaryRequests.isCurrent(generation)) {
        setState(() => _backgroundRefresh = false);
      }
    } catch (error) {
      if (!mounted || !_summaryRequests.isCurrent(generation)) return;
      setState(() {
        if (_accessDenied(error)) {
          _summary = null;
          _riskPage = null;
          _updatedAt = null;
        }
        _error = _errorText(error);
        _loading = false;
      });
    }
  }

  bool _accessDenied(Object error) =>
      error is ApiException &&
      (error.httpStatus == 401 ||
          error.httpStatus == 403 ||
          error.code == 'UNAUTHORIZED' ||
          error.code == 'FORBIDDEN');

  Future<void> _loadRisk(
    String risk,
    int page, {
    bool background = false,
  }) async {
    if (_loading || !_riskCounts.containsKey(risk)) return;
    final generation = _riskRequests.begin();
    setState(() {
      _selectedRisk = risk;
      _requestedRiskPage = page;
      _riskLoading = true;
      _riskError = null;
      if (!background) _riskPage = null;
    });
    try {
      final result = await _fetch(page: page, size: 8, attention: risk);
      if (!mounted || !_riskRequests.isCurrent(generation)) return;
      if (result.totalPages > 0 && page > result.totalPages) {
        return _loadRisk(risk, result.totalPages, background: background);
      }
      setState(() {
        _riskPage = result;
        _riskLoading = false;
      });
    } catch (error) {
      if (!mounted || !_riskRequests.isCurrent(generation)) return;
      setState(() {
        if (_accessDenied(error)) {
          _riskPage = null;
          _summary = null;
          _updatedAt = null;
          _error = _errorText(error);
        }
        _riskError = error is ApiException && error.httpStatus == 404
            ? '当前系统版本暂不支持风险明细，请联系管理员更新系统后重试。'
            : _errorText(error);
        _riskLoading = false;
      });
    }
  }

  String _errorText(Object error) =>
      error is ApiException ? error.message : '加载失败，请重试';

  void _selectRisk(String risk) {
    _loadRisk(risk, 1);
    final compact =
        _contentWidth < 1000 || MediaQuery.textScalerOf(context).scale(14) > 20;
    if (!compact) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedRisk != risk) return;
      final target = _riskDetailsAnchor.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        alignment: 0.05,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(RouteName.stockInstantInventoryOverview, () async {
      await _refresh(background: true);
      final failure = _error ?? _riskError;
      if (failure != null) throw StateError(failure);
    });
    final summary = _summary;
    return Scaffold(
      appBar: UtenAppBar(
        title: '库存总览与分析',
        subtitle: _updatedAt == null
            ? null
            : '最近更新 ${ChinaDateTime.formatTime(ChinaDateTime.fromInstant(_updatedAt!), seconds: true)} · 当前筛选范围',
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: RouteName.stockInstantInventory),
        ),
        actions: [
          UtenRefreshButton(
            key: const Key('inventory-overview-refresh'),
            tooltip: '刷新统计',
            busy: _loading,
            onRefresh: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          child: Stack(
            children: [
              Positioned.fill(
                child: _loading && !_backgroundRefresh
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null && (!_backgroundRefresh || summary == null)
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!),
                            const SizedBox(height: UtenSpacing.s12),
                            FilledButton(
                              onPressed: _refresh,
                              child: const Text('重新加载'),
                            ),
                          ],
                        ),
                      )
                    : summary == null
                    ? const SizedBox.shrink()
                    : summary.totalRows == 0
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.scopeLabel ?? widget.scope.fallbackLabel,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: UtenSpacing.s16),
                            const Text('当前筛选范围暂无货品'),
                            const SizedBox(height: UtenSpacing.s12),
                            TextButton(
                              onPressed: () => backTo(
                                context,
                                defaultPath: RouteName.stockInstantInventory,
                              ),
                              child: const Text('返回即时库存调整筛选'),
                            ),
                          ],
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          _contentWidth = constraints.maxWidth;
                          return InstantInventoryOverviewContent(
                            summary: summary,
                            scopeLabel:
                                widget.scopeLabel ?? widget.scope.fallbackLabel,
                            selectedRisk: _selectedRisk,
                            onRiskSelected: summary.hasAnalysis
                                ? _selectRisk
                                : null,
                            riskDetails: KeyedSubtree(
                              key: _riskDetailsAnchor,
                              child: _riskDetails(summary),
                            ),
                            onAdvancedAnalysis:
                                ref
                                    .watch(currentPermissionsProvider)
                                    .contains(Perm.stockReportView)
                                ? () =>
                                      context.push(RouteName.warehouseInsights)
                                : null,
                          );
                        },
                      ),
              ),
              if (_backgroundRefresh && _loading)
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (_backgroundRefresh && _error != null && summary != null)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: Material(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text('更新失败，显示上次数据'),
                        TextButton(
                          onPressed: () => _refresh(background: true),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _riskDetails(InstantInventorySummary summary) {
    final risk = _selectedRisk;
    final theme = Theme.of(context);
    final number = NumberFormat('#,##0.####', 'zh_CN');
    String qty(double? value, String? unit) => value == null
        ? '未提供'
        : '${number.format(value)} ${unit?.trim().isNotEmpty == true ? unit : '计量待核'}';
    final page = _riskPage;
    return UtenCard(
      key: const Key('inventory-risk-details'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            risk == null ? '涉及货品' : _riskTitles[risk]!,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: UtenSpacing.s8),
          if (risk == null)
            Text(
              summary.hasAnalysis
                  ? '当前规则未发现需要列出的货品。零库存不直接判定为缺货。'
                  : '当前系统版本暂不支持风险分析。',
            )
          else ...[
            Text(
              _riskBasis[risk]!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s16),
            if (_riskLoading && page == null)
              const Padding(
                padding: EdgeInsets.all(UtenSpacing.s24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_riskError != null) ...[
              Text(
                _riskError!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
              TextButton(
                onPressed: () => _loadRisk(risk, _requestedRiskPage),
                child: const Text('重试加载清单'),
              ),
            ],
            if (page != null) ...[
              if (_riskError != null) const Text('更新失败，以下为上次加载的清单'),
              if (_riskLoading) const LinearProgressIndicator(minHeight: 2),
              Text(
                '当前筛选涉及 ${page.total} 项 · 按货品 × 颜色列示',
                style: theme.textTheme.labelLarge,
              ),
              if (page.items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: UtenSpacing.s16),
                  child: Text('暂无符合条件的货品，数据可能已更新。可刷新总览重新核对。'),
                ),
              for (final row in page.items) ...[
                const Divider(height: UtenSpacing.s24),
                Text(
                  row.name ?? row.goodsCode ?? '未命名货品',
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  [
                    if (row.goodsCode?.isNotEmpty == true) row.goodsCode!,
                    if (row.colorName?.isNotEmpty == true) row.colorName!,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Wrap(
                  spacing: UtenSpacing.s16,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    Text(
                      row.measurementPending
                          ? '账面库存 ${qty(row.qty, null)}'
                          : '库存 ${qty(row.qty, row.unitName)}',
                    ),
                    if (row.measurementPending) Text(row.measurementNotice),
                    if (risk == 'AWAITING_STOCK_IN')
                      Text(
                        '合格待入库 ${qty(row.pendingStockInQty, row.measurementPending ? null : row.unitName)}',
                      ),
                    if (risk == 'AWAITING_INSPECTION')
                      Text(
                        '待检 ${qty(row.pendingQty, row.measurementPending ? null : row.unitName)}',
                      ),
                    if (risk == 'UNKNOWN_WEIGHT')
                      WeightText(
                        kg: row.weight,
                        estimated: row.weightEstimated,
                      ),
                    TextButton.icon(
                      key: ValueKey(
                        'inventory-risk-open-${row.goodsId}-${row.colorId}',
                      ),
                      onPressed: row.goodsId == null
                          ? null
                          : () => context.push(
                              RouteName.stockItemDetail(row.goodsId!),
                            ),
                      icon: const Icon(Icons.arrow_forward, size: 16),
                      label: const Text('查看各仓与流水'),
                    ),
                  ],
                ),
              ],
              if (page.totalPages > 1) ...[
                const Divider(height: UtenSpacing.s24),
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: UtenSpacing.s8,
                  children: [
                    TextButton(
                      onPressed: page.page > 1
                          ? () => _loadRisk(risk, page.page - 1)
                          : null,
                      child: const Text('上一页'),
                    ),
                    Text('${page.page} / ${page.totalPages}'),
                    TextButton(
                      onPressed: page.page < page.totalPages
                          ? () => _loadRisk(risk, page.page + 1)
                          : null,
                      child: const Text('下一页'),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }
}
