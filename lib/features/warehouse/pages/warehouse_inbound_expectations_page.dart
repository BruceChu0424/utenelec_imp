import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/auth/permissions.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/widgets/metric_filter_cards.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../repositories/procurement_inbound_repository.dart';
import '../repositories/procurement_inspection_repository.dart';

class WarehouseInboundExpectationsPage extends ConsumerStatefulWidget {
  const WarehouseInboundExpectationsPage({super.key});

  @override
  ConsumerState<WarehouseInboundExpectationsPage> createState() =>
      _WarehouseInboundExpectationsPageState();
}

class _WarehouseInboundExpectationsPageState
    extends ConsumerState<WarehouseInboundExpectationsPage> {
  PagedResult<InboundExpectation>? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;

  /// 类型筛选卡：null = 全部待到货；否则只看采购/委外。
  ProcurementInboundOrderType? _orderType;

  /// 按类型计数（后端全量口径）；null = 尚未返回，卡片显示 '—'。
  Map<String, int>? _typeCounts;

  /// 待检处置卡角标：仍有 PENDING/PARTIAL 明细的收货单张数；null = 尚未返回。
  int? _inspectionPendingCount;

  /// 待检处置卡仅对有查看权限者可见（服务端接口独立鉴权兜底）。
  bool get _canViewInspection =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(Perm.procurementInspectionView);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  /// 卡片单选互斥：点选即切换；再点已选卡回「全部」。
  void _selectType(ProcurementInboundOrderType? type) {
    final next = _orderType == type ? null : type;
    if (next == _orderType) return;
    setState(() => _orderType = next);
    _load(1);
  }

  int? _typeCount(ProcurementInboundOrderType? type) {
    final counts = _typeCounts;
    if (counts == null) return null;
    return switch (type) {
      null => counts.values.fold<int>(0, (a, b) => a + b),
      ProcurementInboundOrderType.purchase => counts['PURCHASE'] ?? 0,
      ProcurementInboundOrderType.subcontract => counts['SUBCONTRACT'] ?? 0,
      _ => 0,
    };
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(procurementInboundRepositoryProvider);
      final result = await repo.expectations(page: page, orderType: _orderType);
      // 类型计数失败不阻断列表（卡片降级为 '—'）。
      repo
          .expectationTypeCounts()
          .then((counts) {
            if (mounted) setState(() => _typeCounts = counts);
          })
          .catchError((_) {});
      // 待检处置卡角标同理：失败仅显示 '—'。
      if (_canViewInspection) {
        ref
            .read(procurementInspectionRepositoryProvider)
            .pendingCount()
            .then((count) {
              if (mounted) {
                setState(() => _inspectionPendingCount = count);
              }
            })
            .catchError((_) {});
      }
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(warehouseInboundExpectationCountProvider);
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '预计到货加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  void _createReceipt(InboundExpectation expectation) {
    final prefill = expectation.toReceiptPrefill();
    final route = expectation.orderType.receiptCreateRoute;
    if (prefill == null || route == null) {
      context.appWarning('该预计到货任务暂不能登记，请刷新后重试');
      return;
    }
    context.push(route, extra: prefill);
  }

  /// 待检处置卡：跳转 IQC 工作台；返回后刷新列表与角标（处置会减少待检单）。
  Future<void> _openInspections() async {
    await context.push(RouteName.warehouseInspections);
    if (mounted) _load(_result?.page ?? 1);
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: UtenAppBar(
        title: '预计到货任务中心',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && result != null,
              onPressed: _loading ? null : () => _load(result?.page ?? 1),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && result == null
            ? const UtenSkeletonList()
            : _error != null && result == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: () => _load(1),
              )
            : _buildList(result),
      ),
    );
  }

  Widget _buildList(PagedResult<InboundExpectation>? value) {
    final result =
        value ??
        const PagedResult<InboundExpectation>(
          items: [],
          page: 1,
          size: 20,
          total: 0,
          totalPages: 1,
        );
    return UtenContentContainer.narrow(
      child: RefreshIndicator(
        onRefresh: () => _load(result.page),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          children: [
            // 顶部类型筛选卡与任务工作台统一（MetricFilterCards）：全部/采购/委外，
            // 卡片即筛选、单选互斥、再点已选卡回「全部」；计数走后端全量口径。
            Semantics(
              header: true,
              label: '共有 ${result.total} 张待到货订货单',
              child: MetricFilterCards(
                key: const Key('inbound-expectation-type-cards'),
                items: [
                  MetricFilterCardItem(
                    key: 'all',
                    label: '全部待到货',
                    value: _typeCount(null),
                    icon: Icons.local_shipping_outlined,
                    description: '只显示财务已批准、可准备收货的订货单。',
                    selected: _orderType == null,
                    onTap: () => _selectType(null),
                  ),
                  MetricFilterCardItem(
                    key: 'purchase',
                    label: '采购到货',
                    value: _typeCount(ProcurementInboundOrderType.purchase),
                    tone: 'info',
                    icon: Icons.shopping_cart_outlined,
                    selected:
                        _orderType == ProcurementInboundOrderType.purchase,
                    onTap: () =>
                        _selectType(ProcurementInboundOrderType.purchase),
                  ),
                  MetricFilterCardItem(
                    key: 'subcontract',
                    label: '委外到货',
                    value: _typeCount(ProcurementInboundOrderType.subcontract),
                    tone: 'warning',
                    icon: Icons.precision_manufacturing_outlined,
                    selected:
                        _orderType == ProcurementInboundOrderType.subcontract,
                    onTap: () =>
                        _selectType(ProcurementInboundOrderType.subcontract),
                  ),
                  // 待检处置不是筛选维度：点击跳 IQC 工作台，角标 = 待检收货单张数。
                  if (_canViewInspection)
                    MetricFilterCardItem(
                      key: 'inspection',
                      label: '待检处置',
                      value: _inspectionPendingCount,
                      tone: 'error',
                      icon: Icons.fact_check_outlined,
                      onTap: _openInspections,
                    ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '刷新失败：$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: UtenSpacing.s16),
            if (result.items.isEmpty)
              SizedBox(
                height: 380,
                child: UtenEmpty(
                  icon: Icons.inventory_2_outlined,
                  message: _orderType == null ? '目前没有预计到货' : '该类型目前没有预计到货',
                  description: '财务批准采购或委外订货单后，会自动出现在这里。',
                ),
              )
            else
              for (var i = 0; i < result.items.length; i++) ...[
                _ExpectationCard(
                  key: Key('inbound-expectation-${result.items[i].id}'),
                  expectation: result.items[i],
                  onCreateReceipt: () => _createReceipt(result.items[i]),
                ),
                if (i != result.items.length - 1)
                  const SizedBox(height: UtenSpacing.s12),
              ],
            if (result.totalPages > 1) ...[
              const SizedBox(height: UtenSpacing.s20),
              _Pager(
                page: result.page,
                totalPages: result.totalPages,
                loading: _loading,
                onPage: _load,
              ),
            ],
            const SizedBox(height: UtenSpacing.s24),
          ],
        ),
      ),
    );
  }
}

class _ExpectationCard extends StatelessWidget {
  const _ExpectationCard({
    super.key,
    required this.expectation,
    required this.onCreateReceipt,
  });

  final InboundExpectation expectation;
  final VoidCallback onCreateReceipt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UtenStatusBadge(
                  label: '${expectation.orderType.label}到货',
                  type:
                      expectation.orderType ==
                          ProcurementInboundOrderType.purchase
                      ? UtenStatusBadgeType.info
                      : UtenStatusBadgeType.accent,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    expectation.billNo,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            _InfoLine(
              icon: Icons.storefront_outlined,
              label: '供应商',
              value: expectation.supplierName ?? '—',
            ),
            _InfoLine(
              icon: Icons.warehouse_outlined,
              label: '入库仓库',
              // 订货单不再携带仓库：入库仓库在「登记实际到货」时选择。
              value: expectation.warehouseName ?? '登记到货时选择',
            ),
            _InfoLine(
              icon: Icons.event_outlined,
              label: '预计到货',
              value: expectation.expectedDate ?? '未填写',
            ),
            _InfoLine(
              icon: Icons.inventory_outlined,
              label: '数量',
              value:
                  '订货 ${procurementQty(expectation.orderedQty)}，已收 ${procurementQty(expectation.acceptedQty)}，待收 ${procurementQty(expectation.remainingQty)}',
            ),
            const Divider(height: UtenSpacing.s24),
            Text(
              '${expectation.items.where((item) => item.canReceive).length} 条待收明细',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            // 待收明细：物料编码/系列/库位号/颜色帮助仓库备货对位（价格对仓库不可见）。
            for (final item in expectation.items.where((i) => i.canReceive))
              Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
                child: Text(
                  [
                    item.goodsCode,
                    item.goodsName,
                    if (item.goodsSeries?.isNotEmpty == true)
                      '系列 ${item.goodsSeries}',
                    if (item.goodsStockPlace?.isNotEmpty == true)
                      '库位 ${item.goodsStockPlace}',
                    if (item.colorName?.isNotEmpty == true)
                      '颜色 ${item.colorName}',
                    '待收 ${procurementQty(item.remainingQty)}'
                        '${item.unitName == null ? '' : ' ${item.unitName}'}',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: UtenSpacing.s8),
            SizedBox(
              width: double.infinity,
              child: UtenButton(
                key: Key('create-receipt-${expectation.id}'),
                size: UtenButtonSize.large,
                icon: Icons.inventory_2_outlined,
                onPressed: expectation.canCreateReceipt
                    ? onCreateReceipt
                    : null,
                child: Text(expectation.canCreateReceipt ? '登记实际到货' : '暂不能登记'),
              ),
            ),
            if (!expectation.canCreateReceipt) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '任务数据或服务端授权不完整，请刷新；前端不会代替服务端放行。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: UtenSpacing.s8),
          SizedBox(width: 80, child: Text('$label：')),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

class _Pager extends StatelessWidget {
  const _Pager({
    required this.page,
    required this.totalPages,
    required this.loading,
    required this.onPage,
  });
  final int page;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onPage;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        UtenButton(
          size: UtenButtonSize.large,
          type: UtenButtonType.tonal,
          icon: Icons.chevron_left_rounded,
          onPressed: !loading && page > 1 ? () => onPage(page - 1) : null,
          child: const Text('上一页'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
          child: Text('第 $page / $totalPages 页'),
        ),
        UtenButton(
          size: UtenButtonSize.large,
          type: UtenButtonType.tonal,
          icon: Icons.chevron_right_rounded,
          onPressed: !loading && page < totalPages
              ? () => onPage(page + 1)
              : null,
          child: const Text('下一页'),
        ),
      ],
    );
  }
}
