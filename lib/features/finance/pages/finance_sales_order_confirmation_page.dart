import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../models/sales_order_finance_confirmation.dart';
import '../providers/sales_order_finance_confirmation_count_provider.dart';
import '../repositories/sales_order_finance_confirmation_repository.dart';

/// 销售订货单财务确认任务页（V294 闸门）。
///
/// 已审核的销售订货单在此等待财务确认；确认后订单才进入计划部视野
/// （物料分析/待排产/MRP/计划关联均以财务确认为准入）。
class FinanceSalesOrderConfirmationPage extends ConsumerStatefulWidget {
  const FinanceSalesOrderConfirmationPage({super.key});

  @override
  ConsumerState<FinanceSalesOrderConfirmationPage> createState() =>
      _FinanceSalesOrderConfirmationPageState();
}

class _FinanceSalesOrderConfirmationPageState
    extends ConsumerState<FinanceSalesOrderConfirmationPage> {
  SalesOrderFinancePendingPage? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;

  bool get _canView {
    return ref.read(isSuperAdminProvider) ||
        ref.read(currentPermissionsProvider).contains(Perm.salesOrderFinanceView);
  }

  bool get _canConfirm {
    return ref.read(isSuperAdminProvider) ||
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.salesOrderFinanceConfirm);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _load(int page) async {
    if (!_canView) return;
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(salesOrderFinanceConfirmationRepositoryProvider)
          .pending(page: page);
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(salesOrderFinanceConfirmationCountProvider);
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '待确认任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _confirm(SalesOrderFinancePendingItem item) async {
    if (!_canConfirm) {
      context.appWarning('您没有销售订单财务确认权限');
      return;
    }
    final remark = await _askRemark(item);
    if (remark == null || !mounted) return; // 用户取消
    try {
      await ref
          .read(salesOrderFinanceConfirmationRepositoryProvider)
          .confirm(item.orderId, remark: remark);
      if (!mounted) return;
      context.appSuccess('订单 ${item.billNo} 已确认，计划部已可接手');
      _load(_result?.page ?? 1);
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appError(error.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('确认失败，请刷新后重试');
    }
  }

  /// 备注弹窗：返回 null = 取消；空串 = 不填备注直接确认。
  Future<String?> _askRemark(SalesOrderFinancePendingItem item) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('财务确认 ${item.billNo}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('确认后该订单将对计划部可见并可排产。可填写确认备注（选填）：'),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: controller,
              maxLength: 500,
              maxLines: 2,
              decoration: const InputDecoration(
                hintText: '确认备注（选填，≤500 字）',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('sales-order-finance-confirm-submit'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed != true) return null;
    return controller.text;
  }

  void _open(SalesOrderFinancePendingItem item) {
    goFrom(context, item.detailRoute);
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final allowed =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.salesOrderFinanceView);
    final canConfirm =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.salesOrderFinanceConfirm);
    return Scaffold(
      appBar: UtenAppBar(
        title: '销售订单财务确认',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: '/finance'),
        ),
        actions: allowed
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: UtenSpacing.s8),
                  child: UtenButton(
                    key: const Key('sales-order-finance-confirm-refresh'),
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.refresh_rounded,
                    isLoading: _loading && _result != null,
                    onPressed:
                        _loading ? null : () => _load(_result?.page ?? 1),
                    child: const Text('刷新'),
                  ),
                ),
              ]
            : null,
      ),
      body: SafeArea(
        child: !allowed
            ? UtenEmpty.error(
                message: '无权查看销售订单财务确认任务',
                description: '只有被授权的财务人员可以进入（权限设置中授予 sales_order_finance 权限）。',
              )
            : _loading && _result == null
            ? const UtenSkeletonList()
            : _error != null && _result == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: () => _load(1),
              )
            : _buildList(context, canConfirm),
      ),
    );
  }

  Widget _buildList(BuildContext context, bool canConfirm) {
    final result =
        _result ??
        const SalesOrderFinancePendingPage(
          items: <SalesOrderFinancePendingItem>[],
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
            if (_error != null) ...[
              _InlineError(message: _error!, onRetry: () => _load(result.page)),
              const SizedBox(height: UtenSpacing.s12),
            ],
            if (result.items.isEmpty)
              const SizedBox(
                height: 420,
                child: UtenEmpty(
                  icon: Icons.task_alt_rounded,
                  message: '目前没有待财务确认的销售订货单',
                  description: '销售订货单审核后会出现在这里；确认后计划部才可见并排产。',
                ),
              )
            else
              for (var i = 0; i < result.items.length; i++) ...[
                _ConfirmationTaskCard(
                  key: Key(
                    'sales-order-finance-task-${result.items[i].orderId}',
                  ),
                  item: result.items[i],
                  canConfirm: canConfirm,
                  onTap: () => _open(result.items[i]),
                  onConfirm: () => _confirm(result.items[i]),
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

class _ConfirmationTaskCard extends StatelessWidget {
  const _ConfirmationTaskCard({
    super.key,
    required this.item,
    required this.canConfirm,
    required this.onTap,
    required this.onConfirm,
  });

  final SalesOrderFinancePendingItem item;
  final bool canConfirm;
  final VoidCallback onTap;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final amount = item.totalOriginal == null
        ? null
        : '${item.currencyCode?.isNotEmpty == true ? '${item.currencyCode} ' : ''}${item.totalOriginal}';
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.billNo,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (amount != null)
                    Text(amount, style: theme.textTheme.titleSmall),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '客户：${item.clientName ?? '—'}　业务员：${item.sellerName ?? '—'}',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '交货日期：${item.deliverDate ?? '未定'}　明细：${item.itemCount} 行　开单：${item.billDate ?? '—'}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: UtenSpacing.s12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  UtenButton(
                    key: Key('sales-order-finance-confirm-${item.orderId}'),
                    icon: Icons.fact_check_outlined,
                    onPressed: canConfirm ? onConfirm : null,
                    child: const Text('财务确认'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      borderRadius: UtenRadius.lgAll,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
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
        IconButton(
          onPressed: loading || page <= 1 ? null : () => onPage(page - 1),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Text('$page / $totalPages'),
        IconButton(
          onPressed:
              loading || page >= totalPages ? null : () => onPage(page + 1),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}
