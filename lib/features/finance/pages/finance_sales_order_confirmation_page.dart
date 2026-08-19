import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../models/sales_order_finance_confirmation.dart';
import '../providers/sales_order_finance_confirmation_count_provider.dart';
import '../repositories/sales_order_finance_confirmation_repository.dart';

/// 销售订货单财务确认任务页（V294 闸门，V300 重设计）。
///
/// 对齐大公司审批中心（审批收件箱）范式：
///  - 顶部摘要条：当前视图待办笔数 + 说明；
///  - 分段 Tab：待确认（未驳回，可办）/ 已驳回（待销售修正）；
///  - 卡片即决策：金额/客户应收余额/交货紧迫度一眼可见，卡上直接 确认/驳回，
///    点卡进入财务审核详情页（客户财务快照 + 产品明细）；
///  - 驳回必填原因并通知归属销售；确认后计划部才可见并排产。
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

  /// 分段视图：false=待确认（默认）；true=已驳回。
  bool _showRejected = false;

  bool get _canView {
    return ref.read(isSuperAdminProvider) ||
        ref.read(currentPermissionsProvider).contains(Perm.salesOrderFinanceView);
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
          .pending(page: page, rejected: _showRejected);
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

  void _switchTab(bool rejected) {
    if (rejected == _showRejected) return;
    setState(() {
      _showRejected = rejected;
      _result = null;
    });
    _load(1);
  }

  /// 打开财务审核详情页；确认/驳回后返回 true → 刷新当前视图。
  Future<void> _open(SalesOrderFinancePendingItem item) async {
    final changed = await context.push<bool>(item.detailRoute);
    if (changed == true && mounted) {
      _load(_result?.page ?? 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final allowed =
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.salesOrderFinanceView);
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
            : _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
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
            _summaryStrip(theme, result),
            const SizedBox(height: UtenSpacing.s12),
            _tabs(theme),
            const SizedBox(height: UtenSpacing.s12),
            if (_error != null) ...[
              _InlineError(message: _error!, onRetry: () => _load(result.page)),
              const SizedBox(height: UtenSpacing.s12),
            ],
            if (result.items.isEmpty)
              SizedBox(
                height: 420,
                child: UtenEmpty(
                  icon: _showRejected
                      ? Icons.undo_rounded
                      : Icons.task_alt_rounded,
                  message: _showRejected
                      ? '没有被财务驳回的销售订货单'
                      : '目前没有待财务确认的销售订货单',
                  description: _showRejected
                      ? '被驳回的订单会出现在这里，销售修正后可重新确认。'
                      : '销售订货单审核后会出现在这里；确认后计划部才可见并排产。',
                ),
              )
            else
              for (var i = 0; i < result.items.length; i++) ...[
                _ConfirmationTaskCard(
                  key: Key(
                    'sales-order-finance-task-${result.items[i].orderId}',
                  ),
                  item: result.items[i],
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

  /// 顶部摘要条：当前视图笔数 + 流程说明。
  Widget _summaryStrip(ThemeData theme, SalesOrderFinancePendingPage result) {
    return Container(
      key: const Key('sales-order-finance-summary'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: UtenRadius.lgAll,
      ),
      child: Row(
        children: [
          Icon(
            Icons.fact_check_outlined,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _showRejected
                      ? '已驳回 ${result.total} 笔'
                      : '待确认 ${result.total} 笔',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  _showRejected
                      ? '驳回件待销售修正；修正后财务再次确认即放行计划部'
                      : '点卡片进审核详情：核对金额、发运策略与客户应收后再确认',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 分段 Tab：待确认 / 已驳回。
  Widget _tabs(ThemeData theme) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<bool>(
        key: const Key('sales-order-finance-tabs'),
        segments: const [
          ButtonSegment(
            value: false,
            label: Text('待确认'),
            icon: Icon(Icons.pending_actions_rounded, size: 18),
          ),
          ButtonSegment(
            value: true,
            label: Text('已驳回'),
            icon: Icon(Icons.undo_rounded, size: 18),
          ),
        ],
        selected: {_showRejected},
        onSelectionChanged: (selection) => _switchTab(selection.first),
      ),
    );
  }
}

class _ConfirmationTaskCard extends StatelessWidget {
  const _ConfirmationTaskCard({
    super.key,
    required this.item,
    required this.onTap,
  });

  final SalesOrderFinancePendingItem item;
  final VoidCallback onTap;

  /// 交货紧迫度：已逾期/今日/≤3 天 → 红色提示（与销售列表延期预警同口径）。
  _DeliverUrgency get _urgency {
    final raw = item.deliverDate;
    if (raw == null || raw.isEmpty) return _DeliverUrgency.none;
    final date = DateTime.tryParse(raw);
    if (date == null) return _DeliverUrgency.none;
    final today = DateTime.now();
    final diff = DateTime(date.year, date.month, date.day)
        .difference(DateTime(today.year, today.month, today.day))
        .inDays;
    if (diff < 0) return _DeliverUrgency.overdue;
    if (diff <= 3) return _DeliverUrgency.soon;
    return _DeliverUrgency.normal;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currency =
        item.currencyCode?.isNotEmpty == true ? item.currencyCode! : '';
    final amount = item.totalOriginal == null
        ? null
        : '${currency.isEmpty ? '' : '$currency '}${item.totalOriginal}';
    final urgency = _urgency;
    return Material(
      color: theme.colorScheme.surface,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              // 驳回件左侧红条：收件箱式一眼区分。
              left: BorderSide(
                width: 3,
                color: item.financeRejected
                    ? theme.colorScheme.error
                    : Colors.transparent,
              ),
            ),
          ),
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
                    Text(
                      amount,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '客户：${item.clientName ?? '—'}　业务员：${item.sellerName ?? '—'}',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: UtenSpacing.s4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '交货日期：${item.deliverDate ?? '未定'}'
                      '　明细：${item.itemCount} 行'
                      '　开单：${item.billDate ?? '—'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: urgency == _DeliverUrgency.overdue ||
                                urgency == _DeliverUrgency.soon
                            ? theme.colorScheme.error
                            : null,
                        fontWeight: urgency == _DeliverUrgency.normal
                            ? null
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                  if (urgency == _DeliverUrgency.overdue)
                    _urgencyTag(theme, '已逾期')
                  else if (urgency == _DeliverUrgency.soon)
                    _urgencyTag(theme, '临近交货'),
                ],
              ),
              if (item.clientOutstanding != null) ...[
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '客户应收余额：${item.clientOutstanding}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (item.financeRejected) ...[
                const SizedBox(height: UtenSpacing.s8),
                Container(
                  padding: const EdgeInsets.all(UtenSpacing.s8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer.withValues(
                      alpha: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(UtenRadius.md),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.undo_rounded,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Expanded(
                        child: Text(
                          '已驳回：${item.financeRejectedReason ?? '未注明原因'}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: UtenSpacing.s12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  UtenButton(
                    key: Key('sales-order-finance-review-${item.orderId}'),
                    type: UtenButtonType.secondary,
                    icon: Icons.fact_check_outlined,
                    onPressed: onTap,
                    child: Text(
                      item.financeRejected ? '查看并处理' : '审核',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _urgencyTag(ThemeData theme, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.error,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

enum _DeliverUrgency { none, normal, soon, overdue }

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
