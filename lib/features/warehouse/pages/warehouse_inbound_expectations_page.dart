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
import '../providers/procurement_inbound_count_providers.dart';
import '../repositories/procurement_inbound_repository.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _load(int page) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(procurementInboundRepositoryProvider)
          .expectations(page: page);
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
          if (ref.read(isSuperAdminProvider) ||
              ref
                  .read(currentPermissionsProvider)
                  .contains(Perm.procurementInspectionView))
            Padding(
              padding: const EdgeInsets.only(right: UtenSpacing.s8),
              child: UtenButton(
                size: UtenButtonSize.large,
                type: UtenButtonType.tonal,
                icon: Icons.fact_check_outlined,
                onPressed: () => context.push(RouteName.warehouseInspections),
                child: const Text('待检处置'),
              ),
            ),
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
            _ExpectationSummary(total: result.total),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '刷新失败：$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: UtenSpacing.s16),
            if (result.items.isEmpty)
              const SizedBox(
                height: 380,
                child: UtenEmpty(
                  icon: Icons.inventory_2_outlined,
                  message: '目前没有预计到货',
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

class _ExpectationSummary extends StatelessWidget {
  const _ExpectationSummary({required this.total});
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      label: '共有 $total 张待到货订货单',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.32),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.28),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: UtenRadius.mdAll,
              ),
              child: Icon(
                Icons.local_shipping_outlined,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '待到货 $total 张',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  const Text('这里只显示财务已经批准、可以准备收货的订货单。'),
                ],
              ),
            ),
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
              value: expectation.warehouseName ?? '—',
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
            const SizedBox(height: UtenSpacing.s12),
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
