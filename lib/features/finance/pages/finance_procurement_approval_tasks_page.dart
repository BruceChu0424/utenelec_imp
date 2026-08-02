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
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../finance_workflow_routes.dart';
import '../models/finance_procurement_workflow.dart';
import '../providers/finance_procurement_approval_count_provider.dart';
import '../repositories/finance_procurement_workflow_repository.dart';

class FinanceProcurementApprovalTasksPage extends ConsumerStatefulWidget {
  const FinanceProcurementApprovalTasksPage({super.key});

  @override
  ConsumerState<FinanceProcurementApprovalTasksPage> createState() =>
      _FinanceProcurementApprovalTasksPageState();
}

class _FinanceProcurementApprovalTasksPageState
    extends ConsumerState<FinanceProcurementApprovalTasksPage> {
  FinanceProcurementApprovalPage? _result;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;

  bool get _allowed {
    return ref.read(isSuperAdminProvider) ||
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.financeOrderApprovalView);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _load(int page) async {
    if (!_allowed) return;
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(financeProcurementWorkflowRepositoryProvider)
          .approvalTasks(page: page);
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(financeProcurementApprovalCountProvider);
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '待审任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  void _open(FinanceProcurementApprovalTask task) {
    final route = task.detailRoute;
    if (route == null) {
      context.appWarning('该任务缺少有效的订货类型或单据编号，请刷新后重试');
      return;
    }
    goFrom(context, route);
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final allowed =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.financeOrderApprovalView);
    return Scaffold(
      appBar: UtenAppBar(
        title: '订货审批任务中心',
        leading: UtenBackButton(
          onPressed: () => backTo(
            context,
            defaultPath: FinanceWorkflowRoutes.approvalTasks.replaceFirst(
              '/procurement-approvals',
              '',
            ),
          ),
        ),
        actions: allowed
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: UtenSpacing.s8),
                  child: UtenButton(
                    key: const Key('finance-approval-refresh'),
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.refresh_rounded,
                    isLoading: _loading && _result != null,
                    onPressed: _loading
                        ? null
                        : () => _load(_result?.page ?? 1),
                    child: const Text('刷新'),
                  ),
                ),
              ]
            : null,
      ),
      body: SafeArea(
        child: !allowed
            ? UtenEmpty.error(
                message: '无权查看订货审批任务',
                description: '只有被授权的财务审核人员可以进入。',
              )
            : _loading && _result == null
            ? const UtenSkeletonList()
            : _error != null && _result == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: () => _load(1),
              )
            : _buildList(context),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final result =
        _result ??
        const FinanceProcurementApprovalPage(
          items: <FinanceProcurementApprovalTask>[],
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
            _ApprovalSummary(total: result.total),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              _InlineError(message: _error!, onRetry: () => _load(result.page)),
            ],
            const SizedBox(height: UtenSpacing.s16),
            if (result.items.isEmpty)
              const SizedBox(
                height: 420,
                child: UtenEmpty(
                  icon: Icons.task_alt_rounded,
                  message: '目前没有待您审核的订货单',
                  description: '只有明确分配给您的采购或委外订货单才会出现在这里。',
                ),
              )
            else
              for (var i = 0; i < result.items.length; i++) ...[
                _ApprovalTaskCard(
                  key: Key('finance-approval-task-${result.items[i].caseId}'),
                  task: result.items[i],
                  onTap: () => _open(result.items[i]),
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

class _ApprovalSummary extends StatelessWidget {
  const _ApprovalSummary({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      label: '待我审核 $total 张订货单',
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
                Icons.approval_outlined,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '待我审核 $total 张',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '仅显示明确分配给您的采购和委外订货单',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApprovalTaskCard extends StatelessWidget {
  const _ApprovalTaskCard({super.key, required this.task, required this.onTap});

  final FinanceProcurementApprovalTask task;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final submitted = ChinaDateTime.formatIsoInstant(
      task.submittedAt,
      fallback: task.submittedAt ?? '—',
    );
    final amount = task.amount == null
        ? null
        : '${task.currencyName?.isNotEmpty == true ? '${task.currencyName} ' : '¥'}${task.amount}';
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: task.canOpen,
        label: '${task.orderTypeLabel} ${task.billNo}，点击查看订货单',
        child: Material(
          color: theme.colorScheme.surface,
          borderRadius: UtenRadius.lgAll,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 120),
              padding: const EdgeInsets.all(UtenSpacing.s16),
              decoration: BoxDecoration(
                borderRadius: UtenRadius.lgAll,
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      UtenStatusBadge(
                        label: task.orderTypeLabel,
                        type:
                            task.orderType ==
                                FinanceProcurementOrderType.purchase
                            ? UtenStatusBadgeType.info
                            : task.orderType ==
                                  FinanceProcurementOrderType.subcontract
                            ? UtenStatusBadgeType.accent
                            : UtenStatusBadgeType.danger,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Expanded(
                        child: Text(
                          task.billNo,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, size: 28),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  Wrap(
                    spacing: UtenSpacing.s16,
                    runSpacing: UtenSpacing.s8,
                    children: [
                      _TaskInfo(
                        icon: Icons.storefront_outlined,
                        label: '供应商',
                        value: task.supplierName ?? '未填写',
                      ),
                      if (amount != null)
                        _TaskInfo(
                          icon: Icons.payments_outlined,
                          label: '金额',
                          value: amount,
                        ),
                      _TaskInfo(
                        icon: Icons.person_outline_rounded,
                        label: '提交人',
                        value: task.submittedByName ?? '—',
                      ),
                      _TaskInfo(
                        icon: Icons.schedule_outlined,
                        label: '提交时间',
                        value: submitted,
                      ),
                      if (task.expectedDate?.isNotEmpty == true)
                        _TaskInfo(
                          icon: Icons.local_shipping_outlined,
                          label: '交货日期',
                          value: task.expectedDate!,
                        ),
                      if (task.sourceApplicationCount != null)
                        _TaskInfo(
                          icon: Icons.account_tree_outlined,
                          label: '申请来源',
                          value: '${task.sourceApplicationCount} 张',
                        ),
                    ],
                  ),
                  if (!task.canOpen) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      '任务数据不完整，暂不能打开；请刷新或联系管理员。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskInfo extends StatelessWidget {
  const _TaskInfo({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 180),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: UtenSpacing.s4),
          Flexible(
            child: Text(
              '$label：$value',
              style: theme.textTheme.bodyMedium,
              softWrap: true,
            ),
          ),
        ],
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
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(child: Text(message)),
          const SizedBox(width: UtenSpacing.s8),
          UtenButton(
            size: UtenButtonSize.large,
            type: UtenButtonType.tonal,
            icon: Icons.refresh_rounded,
            onPressed: onRetry,
            child: const Text('重试'),
          ),
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
