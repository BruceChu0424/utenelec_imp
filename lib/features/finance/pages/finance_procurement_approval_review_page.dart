// 订货审批审核详情页（财务专用视图，与采购/委外业务订货详情页分离）。
//
// 设计目标（对齐销售订单财务审核页 V300 范式 = 大公司审批中心：单据信息 +
// 风险快照 + 底部双决策）：
//  - 供应商财务快照卡：应付余额（AP 未结合计）/ 本单金额 / 折合本币——财务放行前必看；
//  - 订单信息卡：币种加粗红色、汇率、税率、结算方式等商业事实；数据源为审批 case
//    投影（审批哈希锁定的提交内容），不是业务编辑视角；
//  - 订货明细保持全局统一表格（MasterDataTableView 嵌入模式），逐行带申请来源单号；
//  - 审批历史卡：逐轮 提交/驳回/通过 事件与驳回原因；
//  - 底栏三操作：驳回（必填原因）/ 通过（选填备注）/ 返回——不必退回任务中心即可决策。
// 本页不出现采购/委外业务操作（改量/编辑/红冲/收货），职责分离；按钮按服务端
// allowedActions（实时审核资格 × 权限码）渲染，未授权动作不显示。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart' show utenFmtIsoTime;
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../finance_workflow_routes.dart';
import '../models/finance_procurement_workflow.dart';
import '../providers/finance_procurement_approval_count_provider.dart';
import '../repositories/finance_procurement_workflow_repository.dart';

class FinanceProcurementApprovalReviewPage extends ConsumerStatefulWidget {
  const FinanceProcurementApprovalReviewPage({super.key, required this.caseId});

  final String caseId;

  @override
  ConsumerState<FinanceProcurementApprovalReviewPage> createState() =>
      _FinanceProcurementApprovalReviewPageState();
}

class _FinanceProcurementApprovalReviewPageState
    extends ConsumerState<FinanceProcurementApprovalReviewPage> {
  FinanceProcurementApprovalReview? _review;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _canView =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.financeOrderApprovalView);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!_canView) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final review = await ref
          .read(financeProcurementWorkflowRepositoryProvider)
          .review(widget.caseId);
      if (!mounted) return;
      setState(() {
        _review = review;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '审核详情加载失败，请检查网络或权限后重试';
        _loading = false;
      });
    }
  }

  String get widgetSafeBillNo => _review?.billNo ?? '';

  /// 决策完成后的落点：从任务中心 push 进来 → pop(true) 让列表刷新；
  /// 深链/通知直达导致路由栈空 → 跳回任务中心列表（不裸 pop——GoError 会被
  /// 外层 catch 误报成决策失败）。
  void _closeAfterDecision() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(true);
    } else {
      context.go(FinanceWorkflowRoutes.approvalTasks);
    }
  }

  Future<void> _approve() async {
    final review = _review;
    if (review == null || _busy) return;
    final decision = review.decisionItem;
    if (decision == null || !review.allowedActions.contains('APPROVE')) {
      context.appWarning('当前账号不可办理该笔通过，请刷新后重试');
      return;
    }
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('通过 $widgetSafeBillNo'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const UtenReviewerResponsibilityNotice(
                actionLabel: '订货财务审批·通过',
                description: '确认后系统将以当前审核员记录通过责任，本操作即时生效。',
              ),
              const SizedBox(height: UtenSpacing.s12),
              const Text('通过后订货单立即生效，并生成仓库预计到货任务。可填写审批备注(选填)：'),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                key: const Key('finance-order-review-approve-remark'),
                controller: controller,
                maxLength: 500,
                maxLines: 2,
                decoration: const InputDecoration(
                  hintText: '审批备注(选填，≤500 字，如：已核对供应商账期)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('finance-order-review-approve-submit'),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('确认通过'),
          ),
        ],
      ),
    );
    final remark = controller.text;
    Future<void>.delayed(const Duration(milliseconds: 300), controller.dispose);
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(financeProcurementWorkflowRepositoryProvider)
          .approveOrdersBatch([decision], remark: remark);
      if (!mounted) return;
      context.appSuccess('已通过 $widgetSafeBillNo，仓库预计到货任务已生成');
      ref.invalidate(financeProcurementApprovalCountProvider);
      _closeAfterDecision();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('通过失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    final review = _review;
    if (review == null || _busy) return;
    final decision = review.decisionItem;
    if (decision == null || !review.allowedActions.contains('REJECT')) {
      context.appWarning('当前账号不可办理该笔驳回，请刷新后重试');
      return;
    }
    final controller = TextEditingController();
    String? errorText;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          title: Text('驳回 $widgetSafeBillNo'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const UtenReviewerResponsibilityNotice(
                  actionLabel: '订货财务审批·驳回',
                  description: '确认后系统将记录当前审核员、驳回原因和时间，请对本次决定负责。',
                ),
                const SizedBox(height: UtenSpacing.s12),
                const Text('驳回不改动订货单内容；原因将通知原制单人修改后重新提交。'),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  key: const Key('finance-order-review-reject-reason'),
                  controller: controller,
                  autofocus: true,
                  maxLength: 1000,
                  minLines: 3,
                  maxLines: 5,
                  onChanged: (_) => setDialogState(() => errorText = null),
                  decoration: InputDecoration(
                    hintText: '驳回原因(必填，如：单价待复核 / 供应商资料待更新)',
                    border: const OutlineInputBorder(),
                    error: utenFieldError(errorText),
                  ),
                ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('finance-order-review-reject-submit'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogCtx).colorScheme.error,
              ),
              onPressed: () {
                if (controller.text.trim().isEmpty) {
                  setDialogState(() => errorText = '请填写驳回原因');
                  return;
                }
                Navigator.pop(dialogCtx, true);
              },
              child: const Text('确认驳回'),
            ),
          ],
        ),
      ),
    );
    final reason = controller.text;
    Future<void>.delayed(const Duration(milliseconds: 300), controller.dispose);
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(financeProcurementWorkflowRepositoryProvider)
          .rejectOrdersBatch([decision], reason);
      if (!mounted) return;
      context.appSuccess('已驳回 $widgetSafeBillNo，制单人将收到修正通知');
      ref.invalidate(financeProcurementApprovalCountProvider);
      _closeAfterDecision();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('驳回失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canView =
        ref.watch(isSuperAdminProvider) ||
        ref
            .watch(currentPermissionsProvider)
            .contains(Perm.financeOrderApprovalView);
    final review = _review;
    final showActions =
        review != null &&
        review.isPending &&
        (review.allowedActions.contains('APPROVE') ||
            review.allowedActions.contains('REJECT'));
    return Scaffold(
      appBar: UtenAppBar(
        title: '订货审批审核详情',
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: FinanceWorkflowRoutes.approvalTasks),
        ),
      ),
      body: SafeArea(
        child: !canView
            ? Center(
                child: Text(
                  '无权查看订货审批任务',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              )
            : _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      UtenButton(
                        type: UtenButtonType.secondary,
                        icon: Icons.refresh_rounded,
                        onPressed: _load,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              )
            : review == null
            ? const SizedBox.shrink()
            : UtenContentContainer.narrow(
                child: ListView(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  children: [
                    _statusStrip(theme, review),
                    const SizedBox(height: UtenSpacing.s12),
                    _supplierFinanceCard(theme, review),
                    const SizedBox(height: UtenSpacing.s12),
                    _orderCard(theme, review),
                    const SizedBox(height: UtenSpacing.s12),
                    _itemsSection(theme, review),
                    const SizedBox(height: UtenSpacing.s12),
                    _historyCard(theme, review),
                  ],
                ),
              ),
      ),
      bottomNavigationBar: !showActions
          ? null
          : SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(
                    top: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: _busy
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                          SizedBox(width: UtenSpacing.s12),
                          Text('正在处理，请稍候…'),
                        ],
                      )
                    : Wrap(
                        alignment: WrapAlignment.center,
                        spacing: UtenSpacing.s12,
                        runSpacing: UtenSpacing.s8,
                        children: [
                          UtenButton(
                            key: const Key('finance-order-review-back'),
                            type: UtenButtonType.tonal,
                            icon: Icons.arrow_back_rounded,
                            onPressed: () => backTo(
                              context,
                              defaultPath: FinanceWorkflowRoutes.approvalTasks,
                            ),
                            child: const Text('返回'),
                          ),
                          if (review.allowedActions.contains('REJECT'))
                            UtenButton(
                              key: const Key('finance-order-review-reject'),
                              type: UtenButtonType.danger,
                              icon: Icons.undo_rounded,
                              onPressed: _reject,
                              child: const Text('驳回'),
                            ),
                          if (review.allowedActions.contains('APPROVE'))
                            UtenButton(
                              key: const Key('finance-order-review-approve'),
                              type: UtenButtonType.success,
                              icon: Icons.check_circle_outline_rounded,
                              onPressed: _approve,
                              child: const Text('通过'),
                            ),
                        ],
                      ),
              ),
            ),
    );
  }

  /// 顶部状态条：单号 + 订货类型 + 财务审核状态与下一步说明。
  Widget _statusStrip(ThemeData theme, FinanceProcurementApprovalReview r) {
    final pending = r.isPending;
    final rejected = r.status == 'REJECTED';
    final approved = r.status == 'APPROVED';
    final color = pending
        ? theme.colorScheme.tertiary
        : rejected
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final icon = pending
        ? Icons.pending_actions_rounded
        : rejected
        ? Icons.undo_rounded
        : Icons.verified_rounded;
    final statusText = pending
        ? '待财务审核 · 通过后订货生效并生成仓库预计到货任务'
        : rejected
        ? '已被财务驳回 · 等待制单人修改后重新提交'
        : approved
        ? '已通过 · 订货已生效'
        : '已撤回';
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        r.billNo,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Text(
                      '${r.orderTypeLabel} · 第 ${r.attempt ?? 1} 轮',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Text(
                  statusText,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 供应商财务快照卡：应付余额（本币）+ 本单金额（原币/本币）。
  Widget _supplierFinanceCard(
    ThemeData theme,
    FinanceProcurementApprovalReview r,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '供应商财务快照 · ${r.supplierName ?? '—'}'
                    '${r.supplierCode != null ? '(${r.supplierCode})' : ''}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenFormGrid(
              children: [
                _metric(
                  theme,
                  '应付余额(本币)',
                  _money(r.supplierApBalance),
                  emphasis: true,
                ),
                _metric(
                  theme,
                  '本单金额(${_currencyLabel(r)})',
                  _money(r.totalOriginal),
                ),
                _metric(theme, '折合本币', _money(r.totalLocal)),
                _metric(theme, '税率', _trimNum(r.taxRate) ?? '—'),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '应付余额 = 该供应商未结应付合计（与应付台账同口径），供放行参考。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(
    ThemeData theme,
    String label,
    String value, {
    bool emphasis = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: emphasis ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ],
    );
  }

  /// 订单信息卡：币种加粗红色，与销售审核详情同规则。
  Widget _orderCard(ThemeData theme, FinanceProcurementApprovalReview r) {
    Widget kv(String label, String? value, {bool highlight = false}) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              (value == null || value.isEmpty) ? '—' : value,
              style: highlight
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.error,
                    )
                  : null,
            ),
          ),
        ],
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenFormGrid(
          children: [
            kv('单据日期', r.billDate),
            kv('订货类型', r.orderTypeLabel),
            kv('供应商', r.supplierName),
            kv('仓库', r.warehouseName),
            kv('币种', _currencyLabel(r), highlight: true),
            kv('汇率', _trimNum(r.exchangeRate)),
            kv('结算方式', r.settlementMethodName),
            kv('订货人', r.purchaserName),
            kv('制单员', r.makerName),
            kv('提交人', r.submittedByName),
            kv('提交时间', utenFmtIsoTime(r.submittedAt)),
            kv('预计到货日', r.deliverDate),
            kv(
              '来源申请',
              r.sourceApplicationCount > 0
                  ? '${r.sourceApplicationCount} 张'
                  : null,
            ),
            kv('备注', r.remark),
          ],
        ),
      ),
    );
  }

  /// 订货明细：保持全局统一表格（MasterDataTableView 嵌入模式）。
  Widget _itemsSection(ThemeData theme, FinanceProcurementApprovalReview r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '订货明细(${r.items.length})',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        MasterDataTableView<FinanceProcurementReviewLine>(
          embedded: true,
          columns: [
            MasterColumnDef(
              key: 'lineNo',
              label: '行号',
              width: 64,
              type: 'number',
              value: (it) => it.lineNo.toString(),
            ),
            MasterColumnDef(
              key: 'goods',
              label: '货品',
              width: 260,
              value: (it) {
                final base = [
                  if (it.goodsCode != null) it.goodsCode!,
                  if (it.goodsName != null) it.goodsName!,
                ].join(' · ');
                final suffix = [
                  if (it.colorName != null) it.colorName!,
                  if (it.unitName != null) it.unitName!,
                ].join(' · ');
                return suffix.isEmpty ? base : '$base($suffix)';
              },
            ),
            MasterColumnDef(
              key: 'qty',
              label: '数量',
              width: 90,
              type: 'number',
              value: (it) => _trimNum(it.qty),
            ),
            MasterColumnDef(
              key: 'price',
              label: '单价',
              width: 110,
              type: 'money',
              value: (it) => _trimNum(it.price),
            ),
            MasterColumnDef(
              key: 'amountOriginal',
              label: '金额(${_currencyLabel(r)})',
              width: 120,
              type: 'money',
              value: (it) => _trimNum(it.amountOriginal),
            ),
            MasterColumnDef(
              key: 'amountLocal',
              label: '金额(本币)',
              width: 120,
              type: 'money',
              value: (it) => _trimNum(it.amountLocal),
            ),
            MasterColumnDef(
              key: 'deliverDate',
              label: '交货日',
              width: 110,
              type: 'date',
              value: (it) => it.deliverDate,
            ),
            MasterColumnDef(
              key: 'sourceDocNo',
              label: '申请来源',
              width: 170,
              value: (it) => it.sourceDocNo,
            ),
          ],
          items: r.items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          emptyMessage: '(无明细)',
        ),
      ],
    );
  }

  /// 审批历史卡：逐轮 提交/驳回/通过 事件与原因。
  Widget _historyCard(ThemeData theme, FinanceProcurementApprovalReview r) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '审批历史',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            for (final entry in r.history) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    entry.eventType.toUpperCase() == 'REJECTED'
                        ? Icons.undo_rounded
                        : entry.eventType.toUpperCase() == 'APPROVED'
                        ? Icons.check_circle_outline_rounded
                        : Icons.send_outlined,
                    size: 18,
                    color: entry.eventType.toUpperCase() == 'REJECTED'
                        ? theme.colorScheme.error
                        : entry.eventType.toUpperCase() == 'APPROVED'
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '第 ${entry.attempt} 轮 · ${entry.eventLabel}'
                          '${entry.actorName != null ? ' · ${entry.actorName}' : ''}'
                          '${entry.occurredAt != null ? ' · ${utenFmtIsoTime(entry.occurredAt)}' : ''}',
                          style: theme.textTheme.bodySmall,
                        ),
                        if (entry.reason != null &&
                            entry.reason!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            '原因：${entry.reason}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: entry.eventType.toUpperCase() == 'REJECTED'
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
            ],
          ],
        ),
      ),
    );
  }

  /// 币种展示只使用主档名称或可读标准代码，不暴露旧数字编号。
  String _currencyLabel(FinanceProcurementApprovalReview r) =>
      financeCurrencyDisplayLabel(name: r.currencyName) ?? '原币';

  String _money(String? raw) {
    if (raw == null || raw.isEmpty) return '—';
    final v = double.tryParse(raw);
    return v == null ? raw : v.toStringAsFixed(2);
  }

  String? _trimNum(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final v = double.tryParse(raw);
    if (v == null) return raw;
    return v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);
  }
}
