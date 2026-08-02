import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../repositories/procurement_inbound_repository.dart';

class WarehouseArrivalExceptionsPage extends ConsumerStatefulWidget {
  const WarehouseArrivalExceptionsPage({super.key});

  @override
  ConsumerState<WarehouseArrivalExceptionsPage> createState() =>
      _WarehouseArrivalExceptionsPageState();
}

class _WarehouseArrivalExceptionsPageState
    extends ConsumerState<WarehouseArrivalExceptionsPage> {
  PagedResult<ProcurementArrivalException>? _result;
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
          .warehouseExceptions(page: page);
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(warehouseArrivalExceptionCountProvider);
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '到货异常加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: UtenAppBar(
        title: '到货异常任务中心',
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

  Widget _buildList(PagedResult<ProcurementArrivalException>? value) {
    final result =
        value ??
        const PagedResult<ProcurementArrivalException>(
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
            _WarehouseExceptionSummary(total: result.total),
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
                  icon: Icons.task_alt_rounded,
                  message: '目前没有到货异常',
                  description: '超出财务批准数量的到货会先隔离，不会直接入库或立应付。',
                ),
              )
            else
              for (var i = 0; i < result.items.length; i++) ...[
                _WarehouseExceptionCard(
                  key: Key('warehouse-arrival-exception-${result.items[i].id}'),
                  task: result.items[i],
                ),
                if (i != result.items.length - 1)
                  const SizedBox(height: UtenSpacing.s12),
              ],
            if (result.totalPages > 1) ...[
              const SizedBox(height: UtenSpacing.s20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  UtenButton(
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.chevron_left_rounded,
                    onPressed: !_loading && result.page > 1
                        ? () => _load(result.page - 1)
                        : null,
                    child: const Text('上一页'),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s16,
                    ),
                    child: Text('第 ${result.page} / ${result.totalPages} 页'),
                  ),
                  UtenButton(
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.chevron_right_rounded,
                    onPressed: !_loading && result.page < result.totalPages
                        ? () => _load(result.page + 1)
                        : null,
                    child: const Text('下一页'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: UtenSpacing.s24),
          ],
        ),
      ),
    );
  }
}

class _WarehouseExceptionSummary extends StatelessWidget {
  const _WarehouseExceptionSummary({required this.total});
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.38),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: theme.colorScheme.error.withValues(alpha: 0.12),
              borderRadius: UtenRadius.mdAll,
            ),
            child: Icon(
              Icons.warning_amber_rounded,
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '异常任务 $total 条',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                const Text('未明确显示“已入库”之前，异常数量都不计库存、不立应付。'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WarehouseExceptionCard extends StatelessWidget {
  const _WarehouseExceptionCard({super.key, required this.task});
  final ProcurementArrivalException task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = task.status == 'PENDING_FINANCE';
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
                  label: task.orderType.label,
                  type: task.orderType == ProcurementInboundOrderType.purchase
                      ? UtenStatusBadgeType.info
                      : UtenStatusBadgeType.accent,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    task.receiptBillNo,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(UtenSpacing.s12),
              decoration: BoxDecoration(
                color: pending
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.secondaryContainer,
                borderRadius: UtenRadius.mdAll,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    pending ? Icons.block_rounded : Icons.info_outline_rounded,
                    color: pending
                        ? theme.colorScheme.onErrorContainer
                        : theme.colorScheme.onSecondaryContainer,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      task.statusLabel,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: pending
                            ? theme.colorScheme.onErrorContainer
                            : theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            _line('货品', '${task.goodsCode} ${task.goodsName}'.trim()),
            _line('订货单', task.orderBillNo),
            _line('供应商', task.supplierName ?? '—'),
            _line('仓库', task.warehouseName ?? '—'),
            _line(
              '数量',
              '实到 ${procurementQty(task.declaredQty)}，批准剩余 ${procurementQty(task.approvedRemainingQty)}',
            ),
            if (task.acceptedQty > 0)
              _line('决定接收', procurementQty(task.acceptedQty)),
            if (task.unacceptedQty > 0)
              _line('待退供应商', procurementQty(task.unacceptedQty)),
            if (task.status == 'RECEIPT_ADJUSTED' ||
                task.status == 'RETURN_REQUIRED') ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '请回到 ${task.orderType.label}收货单 ${task.receiptBillNo} 继续审核；服务端仍会再次校验数量。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 96, child: Text('$label：')),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
