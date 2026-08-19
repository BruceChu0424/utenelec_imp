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
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/metric_filter_cards.dart';
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

  /// 类型筛选卡：null = 全部待审；否则只看采购/委外。
  FinanceProcurementOrderType? _orderType;

  /// 按类型计数（后端全量口径）；null = 尚未返回，卡片显示 '—'。
  Map<String, int>? _typeCounts;

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

  /// 卡片单选互斥：点选即切换；再点已选卡回「全部」。
  void _selectType(FinanceProcurementOrderType? type) {
    final next = _orderType == type ? null : type;
    if (next == _orderType) return;
    setState(() => _orderType = next);
    _load(1);
  }

  /// 当前筛选口径的提示文案：卡片内不放说明文字（与资产与待摊工作台的指标卡一致），
  /// 口径说明放卡片下方的整行提示条，点击卡片随选中态切换。
  String get _scopeHint => switch (_orderType) {
    FinanceProcurementOrderType.purchase => '仅显示明确分配给您的采购订货单。',
    FinanceProcurementOrderType.subcontract => '仅显示明确分配给您的委外订货单。',
    _ => '仅显示明确分配给您的采购和委外订货单。',
  };

  int? _typeCount(FinanceProcurementOrderType? type) {
    final counts = _typeCounts;
    if (counts == null) return null;
    return switch (type) {
      null => counts.values.fold<int>(0, (a, b) => a + b),
      FinanceProcurementOrderType.purchase => counts['PURCHASE'] ?? 0,
      FinanceProcurementOrderType.subcontract => counts['SUBCONTRACT'] ?? 0,
      _ => 0,
    };
  }

  Future<void> _load(int page) async {
    if (!_allowed) return;
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(financeProcurementWorkflowRepositoryProvider);
      final result = await repo.approvalTasks(
        page: page,
        orderType: _orderType,
      );
      // 类型计数失败不阻断列表（卡片降级为 '—'）。
      repo
          .approvalTypeCounts()
          .then((counts) {
            if (mounted) setState(() => _typeCounts = counts);
          })
          .catchError((_) {});
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

  // ==== 页内审批（V229 审核组的权威操作位）====
  // 订货详情页不再提供审批按钮：采购/委外视角只看到「等待财务通过」，
  // 审核动作收敛到本任务中心（财务专属页面，服务端仍有资格校验兜底）。

  bool _busyApproving = false;

  Future<void> _approveTask(FinanceProcurementApprovalTask task) async {
    if (_busyApproving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('通过 ${task.billNo}？'),
        content: Text(
          '通过后${task.orderTypeLabel}立即生效，并生成仓库预计到货任务。确认通过？',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认通过'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final repo = ref.read(financeProcurementWorkflowRepositoryProvider);
    await _runTaskAction(
      () => repo.approveOrder(task.orderType, task.orderId, task.version ?? 0),
      '财务审核已通过',
    );
  }

  Future<void> _rejectTask(FinanceProcurementApprovalTask task) async {
    if (_busyApproving) return;
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        var value = '';
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: Text('退回 ${task.billNo}'),
            content: TextField(
              autofocus: true,
              minLines: 3,
              maxLines: 5,
              maxLength: 1000,
              onChanged: (v) => setDialogState(() => value = v.trim()),
              decoration: const InputDecoration(
                labelText: '退回原因（必填）',
                hintText: '请写清需要制单人修改的内容',
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed:
                    value.isEmpty ? null : () => Navigator.pop(ctx, value),
                child: const Text('确认退回'),
              ),
            ],
          ),
        );
      },
    );
    if (reason == null || reason.isEmpty || !mounted) return;
    final repo = ref.read(financeProcurementWorkflowRepositoryProvider);
    await _runTaskAction(
      () => repo.rejectOrder(
        task.orderType,
        task.orderId,
        task.version ?? 0,
        reason,
      ),
      '已退回制单人修改',
    );
  }

  Future<void> _runTaskAction(Future<Object?> Function() action, String okMsg) async {
    setState(() => _busyApproving = true);
    try {
      await action();
      if (!mounted) return;
      context.appSuccess(okMsg);
      ref.invalidate(financeProcurementApprovalCountProvider);
      await _load(_result?.page ?? 1);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('审批操作失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busyApproving = false);
    }
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
            // 顶部类型筛选卡与任务工作台统一（MetricFilterCards）：全部/采购/委外，
            // 卡片即筛选、单选互斥、再点已选卡回「全部」；计数走后端全量口径。
            // 卡片内不放说明文字（与资产与待摊的指标卡一致），口径提示在下方整行提示条。
            Semantics(
              header: true,
              label: '待我审核 ${result.total} 张订货单',
              child: MetricFilterCards(
                key: const Key('finance-approval-type-cards'),
                items: [
                  MetricFilterCardItem(
                    key: 'all',
                    label: '全部待审',
                    value: _typeCount(null),
                    icon: Icons.approval_outlined,
                    selected: _orderType == null,
                    onTap: () => _selectType(null),
                  ),
                  MetricFilterCardItem(
                    key: 'purchase',
                    label: '采购订货',
                    value: _typeCount(FinanceProcurementOrderType.purchase),
                    tone: 'info',
                    icon: Icons.shopping_cart_outlined,
                    selected:
                        _orderType == FinanceProcurementOrderType.purchase,
                    onTap: () =>
                        _selectType(FinanceProcurementOrderType.purchase),
                  ),
                  MetricFilterCardItem(
                    key: 'subcontract',
                    label: '委外订货',
                    value: _typeCount(FinanceProcurementOrderType.subcontract),
                    tone: 'warning',
                    icon: Icons.precision_manufacturing_outlined,
                    selected:
                        _orderType == FinanceProcurementOrderType.subcontract,
                    onTap: () =>
                        _selectType(FinanceProcurementOrderType.subcontract),
                  ),
                ],
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            _ScopeHintBanner(message: _scopeHint),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              _InlineError(message: _error!, onRetry: () => _load(result.page)),
            ],
            const SizedBox(height: UtenSpacing.s16),
            if (result.items.isEmpty)
              SizedBox(
                height: 420,
                child: UtenEmpty(
                  icon: Icons.task_alt_rounded,
                  message: _orderType == null
                      ? '目前没有待审核的订货单'
                      : '该类型目前没有待审核的订货单',
                  description: '财务部门持权人员及被点名授权的员工均可在此处理采购或委外订货单。',
                ),
              )
            else
              for (var i = 0; i < result.items.length; i++) ...[
                _ApprovalTaskCard(
                  key: Key('finance-approval-task-${result.items[i].caseId}'),
                  task: result.items[i],
                  onTap: () => _open(result.items[i]),
                  onApprove: () => _approveTask(result.items[i]),
                  onReject: () => _rejectTask(result.items[i]),
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

class _ApprovalTaskCard extends StatelessWidget {
  const _ApprovalTaskCard({
    super.key,
    required this.task,
    required this.onTap,
    this.onApprove,
    this.onReject,
  });

  final FinanceProcurementApprovalTask task;
  final VoidCallback onTap;

  /// 页内审批回调（服务端按 V229 资格放行 allowedActions）。
  final VoidCallback? onApprove;
  final VoidCallback? onReject;

  bool get _canApprove =>
      onApprove != null && task.allowedActions.contains('APPROVE');
  bool get _canReject =>
      onReject != null && task.allowedActions.contains('REJECT');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final submitted = DisplayDateTime.beijing(
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
                  // 页内审批操作行：审批的权威操作位在本任务中心
                  //（订货详情页只读展示等待状态，采购/委外视角不出审批按钮）。
                  if (_canApprove || _canReject) ...[
                    const Divider(height: UtenSpacing.s24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (_canReject) ...[
                          UtenButton(
                            key: Key('finance-approval-reject-${task.caseId}'),
                            type: UtenButtonType.danger,
                            size: UtenButtonSize.small,
                            icon: Icons.reply_rounded,
                            onPressed: onReject,
                            child: const Text('退回修改'),
                          ),
                          if (_canApprove)
                            const SizedBox(width: UtenSpacing.s8),
                        ],
                        if (_canApprove)
                          UtenButton(
                            key: Key('finance-approval-approve-${task.caseId}'),
                            size: UtenButtonSize.small,
                            icon: Icons.check_circle_outline,
                            onPressed: onApprove,
                            child: const Text('通过'),
                          ),
                      ],
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

/// 口径提示条：筛选卡下方整行说明（资产与待摊工作台横幅同款布局），
/// 浅蓝 info 容器色（灰底 + hover 会被误读成「灰色面板」）。
class _ScopeHintBanner extends StatelessWidget {
  const _ScopeHintBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final background =
        isDark ? UtenColors.infoContainerDark : UtenColors.infoContainer;
    final foreground =
        isDark ? UtenColors.onInfoContainerDark : UtenColors.onInfoContainer;
    return Semantics(
      container: true,
      label: '筛选口径：$message',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: foreground.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, color: foreground),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
              ),
            ),
          ],
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
