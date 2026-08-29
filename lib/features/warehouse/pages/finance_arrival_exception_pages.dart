import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../providers/procurement_inbound_count_providers.dart';
import '../repositories/procurement_inbound_repository.dart';

class FinanceArrivalExceptionTasksPage extends ConsumerStatefulWidget {
  const FinanceArrivalExceptionTasksPage({super.key});

  @override
  ConsumerState<FinanceArrivalExceptionTasksPage> createState() =>
      _FinanceArrivalExceptionTasksPageState();
}

class _FinanceArrivalExceptionTasksPageState
    extends ConsumerState<FinanceArrivalExceptionTasksPage> {
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
    final requestVersion = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(procurementInboundRepositoryProvider)
          .financeTasks(page: page);
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _result = result;
        _loading = false;
      });
      ref.invalidate(financeArrivalExceptionCountProvider);
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '超量到货任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: UtenAppBar(
        title: '超量到货审批',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: const Key('finance-arrival-refresh'),
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
            _FinanceTaskSummary(total: result.total),
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
                  message: '目前没有待审批的超量到货',
                  description: '财务部门持权人员及被点名授权的员工均可在此处理到货超量审批。',
                ),
              )
            else
              for (var i = 0; i < result.items.length; i++) ...[
                _FinanceTaskCard(
                  key: Key('finance-arrival-task-${result.items[i].id}'),
                  task: result.items[i],
                  onOpen: () => context.push(
                    RoutePath.financeArrivalException(result.items[i].id),
                  ),
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

class _FinanceTaskSummary extends StatelessWidget {
  const _FinanceTaskSummary({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      label: '待我审批 $total 条超量到货',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
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
                Icons.rule_folder_outlined,
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '待我审批 $total 条',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  const Text('审批完成前不入库、不立应付，仓库也不能绕过。'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FinanceTaskCard extends StatelessWidget {
  const _FinanceTaskCard({super.key, required this.task, required this.onOpen});

  final ProcurementArrivalException task;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label:
          '${task.orderType.label} ${task.orderBillNo}，超量 ${procurementQty(task.requestedExcessQty)}',
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.lgAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: task.id.isEmpty ? null : onOpen,
          child: Container(
            constraints: const BoxConstraints(minHeight: 144),
            padding: const EdgeInsets.all(UtenSpacing.s16),
            decoration: BoxDecoration(
              borderRadius: UtenRadius.lgAll,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    UtenStatusBadge(
                      label: task.orderType.label,
                      type:
                          task.orderType == ProcurementInboundOrderType.purchase
                          ? UtenStatusBadgeType.info
                          : UtenStatusBadgeType.accent,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        task.orderBillNo,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, size: 28),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s12),
                Text('${task.goodsCode} ${task.goodsName}'.trim()),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '实到 ${procurementQty(task.declaredQty)}，已批准剩余 ${procurementQty(task.approvedRemainingQty)}',
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '需审批超量 ${procurementQty(task.requestedExcessQty)} ${task.unitName ?? ''}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (task.excessAmountLocal?.isNotEmpty == true) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  Text('超量金额(服务端快照)：${task.excessAmountLocal}'),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FinanceArrivalExceptionDetailPage extends ConsumerStatefulWidget {
  const FinanceArrivalExceptionDetailPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<FinanceArrivalExceptionDetailPage> createState() =>
      _FinanceArrivalExceptionDetailPageState();
}

class _FinanceArrivalExceptionDetailPageState
    extends ConsumerState<FinanceArrivalExceptionDetailPage> {
  ProcurementArrivalException? _task;
  FinanceArrivalDecision? _decision;
  final _customQty = TextEditingController();
  final _reason = TextEditingController();
  bool _loading = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _customQty.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final task = await ref
          .read(procurementInboundRepositoryProvider)
          .financeTaskDetail(widget.id);
      if (!mounted) return;
      setState(() {
        _task = task;
        _decision = null;
        _customQty.clear();
        _reason.clear();
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '审批详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  bool _actionAllowed(
    ProcurementArrivalException task,
    FinanceArrivalDecision decision,
  ) {
    return switch (decision) {
      FinanceArrivalDecision.rejectExcess => task.canRejectExcess,
      FinanceArrivalDecision.approveCustom => task.canApproveCustom,
      FinanceArrivalDecision.approveAll => task.canApproveAll,
    };
  }

  Future<void> _submit() async {
    final task = _task;
    final decision = _decision;
    if (_saving || task == null) return;
    if (decision == null) {
      context.appWarning('请先选择一种财务处理方案');
      return;
    }
    if (!_actionAllowed(task, decision)) {
      context.appWarning('该任务已变化或不再允许此操作，请刷新');
      return;
    }
    num? customExcess;
    if (decision == FinanceArrivalDecision.approveCustom) {
      customExcess = num.tryParse(_customQty.text.trim());
      if (customExcess == null ||
          customExcess <= 0 ||
          customExcess >= task.requestedExcessQty) {
        context.appWarning(
          '自定义批准超量必须大于 0，且小于 ${procurementQty(task.requestedExcessQty)}',
        );
        return;
      }
    }
    final reason = _reason.text.trim();
    final needsReason = decision != FinanceArrivalDecision.rejectExcess;
    if (needsReason && reason.isEmpty) {
      context.appWarning('批准超量时必须填写财务理由');
      return;
    }
    if (reason.length > 1000) {
      context.appWarning('财务理由不能超过 1000 个字');
      return;
    }

    final proposedAccepted = switch (decision) {
      FinanceArrivalDecision.rejectExcess => task.approvedRemainingQty,
      FinanceArrivalDecision.approveCustom =>
        task.approvedRemainingQty + customExcess!,
      FinanceArrivalDecision.approveAll => task.declaredQty,
    };
    final proposedReturn = switch (decision) {
      FinanceArrivalDecision.rejectExcess => task.requestedExcessQty,
      FinanceArrivalDecision.approveCustom =>
        task.requestedExcessQty - customExcess!,
      FinanceArrivalDecision.approveAll => 0,
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('再次确认财务决定'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const UtenReviewerResponsibilityNotice(
              actionLabel: '超量到货财务审批',
              description: '确认后，系统将以此登录员工记录本次超量到货财务决定责任。',
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(decision.label, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              '预计允许入库：${procurementQty(proposedAccepted)} ${task.unitName ?? ''}',
            ),
            Text(
              '预计退回供应商：${procurementQty(proposedReturn)} ${task.unitName ?? ''}',
            ),
            const SizedBox(height: UtenSpacing.s12),
            const Text('金额和最终数量由服务端复核并记录；本页不自行计算权威金额。'),
            if (task.excessAmountLocal?.isNotEmpty == true) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text('检测时超量金额快照：${task.excessAmountLocal}'),
            ],
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('返回修改'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.check_rounded),
            label: const Text('确认提交'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      final updated = await ref
          .read(procurementInboundRepositoryProvider)
          .financeDecide(
            id: task.id,
            expectedVersion: task.version,
            decision: decision,
            customApprovedExcessQty: customExcess,
            financeReason: reason,
          );
      if (!mounted) return;
      setState(() {
        _task = updated;
        _decision = null;
        _customQty.clear();
        _reason.clear();
      });
      ref.invalidate(financeArrivalExceptionCountProvider);
      ref.invalidate(warehouseArrivalExceptionCountProvider);
      ref.invalidate(procurementArrivalReturnCountProvider(updated.orderType));
      context.appSuccess(
        '财务决定已记录：允许入库 ${procurementQty(updated.acceptedQty)}，待退 ${procurementQty(updated.unacceptedQty)}',
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appError(error.message);
      if (error.code == 'CONFLICT') await _load();
    } catch (_) {
      if (mounted) context.appError('提交失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    return Scaffold(
      appBar: UtenAppBar(
        title: '超量到货审批详情',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(
            context,
            defaultPath: RouteName.financeArrivalExceptions,
          ),
        ),
        actions: task == null
            ? null
            : [
                Padding(
                  padding: const EdgeInsets.only(right: UtenSpacing.s8),
                  child: UtenButton(
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.refresh_rounded,
                    onPressed: _loading || _saving ? null : _load,
                    child: const Text('刷新'),
                  ),
                ),
              ],
      ),
      body: SafeArea(
        child: _loading && task == null
            ? const UtenSkeletonList()
            : _error != null && task == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : task == null
            ? UtenEmpty.error(message: '任务不存在或并非分配给您')
            : UtenContentContainer.narrow(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s16,
                  ),
                  children: [
                    _FinanceStatusBanner(task: task),
                    const SizedBox(height: UtenSpacing.s12),
                    _ArrivalFactsCard(task: task),
                    if (task.canFinanceDecide) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      _FinanceDecisionPanel(
                        task: task,
                        value: _decision,
                        customController: _customQty,
                        reasonController: _reason,
                        onChanged: (value) => setState(() {
                          _decision = value;
                          if (value != FinanceArrivalDecision.approveCustom) {
                            _customQty.clear();
                          }
                        }),
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s24),
                  ],
                ),
              ),
      ),
      bottomNavigationBar: task?.canFinanceDecide != true
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: UtenButton(
                    key: const Key('finance-arrival-confirm'),
                    size: UtenButtonSize.large,
                    isLoading: _saving,
                    icon: Icons.check_circle_outline_rounded,
                    onPressed: _saving ? null : _submit,
                    child: const Text('确认财务决定'),
                  ),
                ),
              ),
            ),
    );
  }
}

class _FinanceStatusBanner extends StatelessWidget {
  const _FinanceStatusBanner({required this.task});

  final ProcurementArrivalException task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = task.status == 'PENDING_FINANCE';
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: pending
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.secondaryContainer,
        borderRadius: UtenRadius.lgAll,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            pending ? Icons.block_rounded : Icons.info_outline_rounded,
            size: 32,
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.statusLabel,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                const Text('审批完成前，异常到货不计库存、不生成应付。'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ArrivalFactsCard extends StatelessWidget {
  const _ArrivalFactsCard({required this.task});

  final ProcurementArrivalException task;

  @override
  Widget build(BuildContext context) {
    final detected = DisplayDateTime.beijing(
      task.detectedAt,
      fallback: task.detectedAt ?? '—',
    );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${task.goodsCode} ${task.goodsName}'.trim(),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Divider(height: UtenSpacing.s24),
            _Fact(
              label: '来源订货单',
              value: '${task.orderType.label} ${task.orderBillNo}',
            ),
            _Fact(label: '仓库收货单', value: task.receiptBillNo),
            _Fact(label: '供应商', value: task.supplierName ?? '—'),
            _Fact(label: '仓库', value: task.warehouseName ?? '—'),
            _Fact(
              label: '实际到货',
              value:
                  '${procurementQty(task.declaredQty)} ${task.unitName ?? ''}',
            ),
            _Fact(
              label: '财务已批准剩余',
              value:
                  '${procurementQty(task.approvedRemainingQty)} ${task.unitName ?? ''}',
            ),
            _Fact(
              label: '本次申请超量',
              value:
                  '${procurementQty(task.requestedExcessQty)} ${task.unitName ?? ''}',
            ),
            _Fact(label: '检测时单价快照', value: task.unitPrice ?? '—'),
            _Fact(label: '到货原币金额快照', value: task.declaredAmountOriginal ?? '—'),
            _Fact(label: '到货本币金额快照', value: task.declaredAmountLocal ?? '—'),
            _Fact(label: '超量本币金额快照', value: task.excessAmountLocal ?? '—'),
            _Fact(label: '财务审核组', value: task.financeAssigneeName ?? '—'),
            _Fact(label: '仓库登记人', value: task.detectedByEmployeeName ?? '—'),
            _Fact(label: '发现时间', value: detected),
          ],
        ),
      ),
    );
  }
}

class _FinanceDecisionPanel extends StatelessWidget {
  const _FinanceDecisionPanel({
    required this.task,
    required this.value,
    required this.customController,
    required this.reasonController,
    required this.onChanged,
  });

  final ProcurementArrivalException task;
  final FinanceArrivalDecision? value;
  final TextEditingController customController;
  final TextEditingController reasonController;
  final ValueChanged<FinanceArrivalDecision> onChanged;

  bool _enabled(FinanceArrivalDecision decision) => switch (decision) {
    FinanceArrivalDecision.rejectExcess => task.canRejectExcess,
    FinanceArrivalDecision.approveCustom => task.canApproveCustom,
    FinanceArrivalDecision.approveAll => task.canApproveAll,
  };

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
            Text(
              '请选择一个财务决定',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '系统不会预选，必须由您主动确认。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            for (final decision in FinanceArrivalDecision.values) ...[
              _DecisionOption(
                key: Key('finance-arrival-decision-${decision.apiValue}'),
                decision: decision,
                selected: value == decision,
                enabled: _enabled(decision),
                onTap: () => onChanged(decision),
              ),
              if (decision != FinanceArrivalDecision.values.last)
                const SizedBox(height: UtenSpacing.s8),
            ],
            if (value == FinanceArrivalDecision.approveCustom) ...[
              const SizedBox(height: UtenSpacing.s16),
              TextField(
                key: const Key('finance-arrival-custom-excess'),
                controller: customController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}')),
                ],
                decoration: InputDecoration(
                  labelText: '批准的额外超量',
                  helper: UtenFieldMessage.helper(
                    '必须大于 0，且小于 ${procurementQty(task.requestedExcessQty)} ${task.unitName ?? ''}',
                  ),
                ),
              ),
            ],
            if (value != null) ...[
              const SizedBox(height: UtenSpacing.s16),
              TextField(
                key: const Key('finance-arrival-reason'),
                controller: reasonController,
                minLines: 3,
                maxLines: 5,
                maxLength: 1000,
                decoration: InputDecoration(
                  labelText: value == FinanceArrivalDecision.rejectExcess
                      ? '财务理由(可选)'
                      : '财务理由(必填)',
                  hintText: '说明批准超量的业务依据',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DecisionOption extends StatelessWidget {
  const _DecisionOption({
    super.key,
    required this.decision,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final FinanceArrivalDecision decision;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.outlineVariant;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: decision.label,
      child: Material(
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
            : theme.colorScheme.surface,
        borderRadius: UtenRadius.lgAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Container(
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.all(UtenSpacing.s16),
            decoration: BoxDecoration(
              borderRadius: UtenRadius.lgAll,
              border: Border.all(color: color, width: selected ? 2 : 1),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: enabled
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                ),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        decision == FinanceArrivalDecision.rejectExcess
                            ? '${decision.label}(推荐)'
                            : decision.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(decision.description),
                      if (!enabled) ...[
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          '当前任务不允许此操作',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 144, child: Text('$label：')),
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
