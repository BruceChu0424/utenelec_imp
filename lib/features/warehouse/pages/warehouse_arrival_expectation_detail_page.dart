// 预计到货任务详情页（/warehouse/inbound/expectations/:expectationId）。
//
// 2026-09-04 用户口径：任务中心双击行不再弹居中「到货详情」弹窗，直接进入
// 本页——单据概要、流水线步骤、待收明细与就地办理（登记实际到货 / 继续送检 /
// 前往到货异常）一屏完成；动作完成后本页就地按最新数据刷新，返回列表时任务
// 中心经 refreshTick 联动重拉。深链冷启动无 extra 时按 id 在对应来源分页里
// 找回任务（每页上限 100，找回失败给出明确引导）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/procurement_inbound_repository.dart';

class WarehouseArrivalExpectationDetailPage extends ConsumerStatefulWidget {
  const WarehouseArrivalExpectationDetailPage({
    super.key,
    required this.expectationId,
    this.initial,
  });

  final String expectationId;
  final InboundExpectation? initial;

  @override
  ConsumerState<WarehouseArrivalExpectationDetailPage> createState() =>
      _WarehouseArrivalExpectationDetailPageState();
}

class _WarehouseArrivalExpectationDetailPageState
    extends ConsumerState<WarehouseArrivalExpectationDetailPage> {
  InboundExpectation? _task;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _task = widget.initial;
    if (_task == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final current = _task;
    try {
      final repo = ref.read(procurementInboundRepositoryProvider);
      // 列表接口是该任务唯一的权威来源（无独立详情端点）：按已知来源分页找回。
      InboundExpectation? found;
      if (current != null) {
        final page = await repo.expectations(
          orderType: current.orderType == ProcurementInboundOrderType.unknown
              ? null
              : current.orderType,
        );
        found = page.items
            .where((item) => item.id == widget.expectationId)
            .firstOrNull;
        found ??= await _findByScanningAll(repo);
      } else {
        found = await _findByScanningAll(repo);
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (found != null) {
          _task = found;
        } else {
          // 任务已办结（送检后移交品质部/异常闭环）即从预计到货列表消失。
          _error =
              '该预计到货任务已不在待办列表：可能已送检（结果在「品质部检查'
              '结果」页跟踪）或已闭环，请返回任务中心刷新。';
        }
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (error, stackTrace) {
      debugPrint('预计到货详情刷新异常: $error\n$stackTrace');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '预计到货详情加载失败（$error）';
      });
    }
  }

  Future<InboundExpectation?> _findByScanningAll(
    ProcurementInboundRepository repo,
  ) async {
    for (final type in [
      ProcurementInboundOrderType.purchase,
      ProcurementInboundOrderType.subcontract,
    ]) {
      final page = await repo.expectations(orderType: type);
      final hit = page.items
          .where((item) => item.id == widget.expectationId)
          .firstOrNull;
      if (hit != null) return hit;
    }
    return null;
  }

  Future<void> _createReceipt() async {
    final expectation = _task;
    if (expectation == null) return;
    final prefill = expectation.toReceiptPrefill();
    final route = expectation.orderType.receiptCreateRoute;
    if (prefill == null || route == null) {
      context.appWarning('该预计到货任务暂不能登记，请刷新后重试');
      return;
    }
    final registration = await context.push<WarehouseArrivalRegistration>(
      route,
      extra: prefill,
    );
    if (registration == null || !mounted) return;
    // 登记完成即回任务中心处理下一张（toast 由全局通知宿主接管存活）。
    _announceRegistration(registration);
    context.pop();
  }

  /// 断点恢复：草稿收货单一键「继续送检」（与任务中心详情同口径）。
  Future<void> _completeRegistration() async {
    final expectation = _task;
    if (expectation == null || expectation.draftReceiptIds.isEmpty) return;
    final confirmed = await showUtenReviewerConfirmDialog(
      context,
      title: '继续送检',
      actionLabel: '送检',
      confirmLabel: '确认送检',
      message:
          '将把已登记的到货数量送品质部待检(IQC)：检验合格后转仓库待入库任务，'
          '仓库确认实物与库位后库存才增加；'
          '实到超过财务批准量时系统自动隔离并通知财务审核组，不会入库、不会生成应付。'
          '单价按订货单自动带入，无需填写。',
    );
    if (confirmed != true) return;
    try {
      final registration = await ref
          .read(procurementInboundRepositoryProvider)
          .completeArrival(expectation.draftReceiptIds.first);
      if (!mounted) return;
      // 送检完成即回任务中心处理下一张（toast 由全局通知宿主接管存活）。
      _announceRegistration(registration);
      context.pop();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('送检失败，请稍后重试');
    }
  }

  void _announceRegistration(WarehouseArrivalRegistration registration) {
    invalidateWarehouseTaskCounts(ref);
    switch (registration.outcome) {
      case WarehouseArrivalRegistrationOutcome.submittedForInspection:
        context.appSuccess(
          '到货已送检(${registration.receiptBillNo ?? ''})：'
          '检查进度与结果请在「品质部检查结果」页查看；'
          '合格后在同一页核对实物与库位确认入库',
        );
      case WarehouseArrivalRegistrationOutcome.excessQuarantined:
        context.appWarning(
          '实到超过财务批准量，已隔离未入库(${registration.receiptBillNo ?? ''})：'
          '待财务在到货异常审批定案后，可在「到货异常任务中心」一键入库',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    return Scaffold(
      appBar: UtenAppBar(
        title: '到货详情',
        subtitle: task?.billNo ?? '预计到货任务',
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: RouteName.warehouseInboundTasks),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: UtenSpacing.s8),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: _loading && task == null
              ? const Center(child: CircularProgressIndicator())
              : task == null
              ? UtenEmpty.error(
                  message: _error ?? '任务不存在',
                  actionLabel: '重新加载',
                  onAction: _refresh,
                )
              : _DetailBody(
                  expectation: task,
                  inlineError: _error,
                  onCreateReceipt: _createReceipt,
                  onCompleteRegistration: _completeRegistration,
                  onOpenExceptions: () =>
                      context.go(RouteName.warehouseArrivalExceptions),
                ),
        ),
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({
    required this.expectation,
    required this.onCreateReceipt,
    required this.onCompleteRegistration,
    required this.onOpenExceptions,
    this.inlineError,
  });

  final InboundExpectation expectation;
  final VoidCallback onCreateReceipt;
  final VoidCallback onCompleteRegistration;
  final VoidCallback onOpenExceptions;
  final String? inlineError;

  InboundArrivalStep get _step => expectation.arrivalStep;

  String _stepLabel(InboundArrivalStep step) => switch (step) {
    InboundArrivalStep.readyToRegister => '待登记到货',
    InboundArrivalStep.draftPendingInspection => '已登记 · 待送检',
    InboundArrivalStep.excessPendingFinance => '超量 · 待财务审批',
    InboundArrivalStep.awaitingQuality => '已送检 · 结果见「品质部检查结果」',
    InboundArrivalStep.blocked => '暂不能登记',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final receivableItems = expectation.items.where((item) => item.canReceive);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (inlineError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Text(
              inlineError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                    Icon(
                      switch (_step) {
                        InboundArrivalStep.readyToRegister =>
                          Icons.inventory_2_outlined,
                        InboundArrivalStep.draftPendingInspection =>
                          Icons.pending_actions_outlined,
                        InboundArrivalStep.excessPendingFinance =>
                          Icons.account_balance_outlined,
                        InboundArrivalStep.awaitingQuality =>
                          Icons.fact_check_outlined,
                        InboundArrivalStep.blocked => Icons.block_outlined,
                      },
                      size: 16,
                      color: _step == InboundArrivalStep.excessPendingFinance
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Text(
                      _stepLabel(_step),
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: _step == InboundArrivalStep.excessPendingFinance
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurface,
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
                  // 订货单不再携带仓库：有建议仓带出建议，否则登记到货时选择。
                  value:
                      expectation.warehouseName ??
                      (expectation.suggestedWarehouseName != null
                          ? '建议 ${expectation.suggestedWarehouseName}'
                          : '登记到货时选择'),
                ),
                _InfoLine(
                  icon: Icons.event_outlined,
                  label: '预计到货',
                  value: expectation.expectedDate ?? '未填写',
                ),
                _InfoLine(
                  icon: Icons.inventory_outlined,
                  label: '数量进度',
                  value:
                      '应到 ${procurementQty(expectation.orderedQty)}，'
                      '已收 ${procurementQty(expectation.acceptedQty)}，'
                      '待收 ${procurementQty(expectation.effectiveRemainingQty)}',
                ),
                if (expectation.registeredQty > 0)
                  _InfoLine(
                    icon: Icons.pending_actions_outlined,
                    label: '在途',
                    value:
                        '已登记待审核 ${procurementQty(expectation.registeredQty)}'
                        '(审核通过后转品质部检验)',
                  ),
                if (expectation.pendingInspectionReceipts > 0)
                  _InfoLine(
                    icon: Icons.fact_check_outlined,
                    label: '已送检',
                    value:
                        '${expectation.pendingInspectionReceipts} 张收货单等待品质结果'
                        '（在「品质部检查结果」页跟踪）',
                  ),
                _InfoLine(
                  icon: Icons.person_outline_rounded,
                  label: '负责人',
                  value: expectation.ownerEmployeeName ?? '—',
                ),
                const Divider(height: UtenSpacing.s24),
                Text(
                  '${receivableItems.length} 条待收明细',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                for (final item in receivableItems)
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
                        if (item.registeredQty > 0)
                          '已登记待审核 ${procurementQty(item.registeredQty)}'
                              '${item.unitName == null ? '' : ' ${item.unitName}'}',
                        '待收 ${procurementQty(item.effectiveRemainingQty)}'
                            '${item.unitName == null ? '' : ' ${item.unitName}'}',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  switch (_step) {
                    InboundArrivalStep.readyToRegister =>
                      expectation.awaitingReceiptReview
                          ? '本批已登记待送检；「继续送检」完成后再登记剩余量。'
                          : '按实际到货数量登记，保存即送品质部检验。',
                    InboundArrivalStep.draftPendingInspection =>
                      '到货已登记待送检：点「继续送检」完成这一步，'
                          '送检后由品质部检验入库。',
                    InboundArrivalStep.excessPendingFinance =>
                      '实到超过财务批准量，已隔离：未入库、未生成应付。'
                          '财务定案后可在「到货异常任务中心」一键入库或办理退回。',
                    InboundArrivalStep.awaitingQuality =>
                      '已送检：检查进度与结果请在「品质部检查结果」页查看；'
                          '合格后在该页核对实物和库位确认入库。',
                    InboundArrivalStep.blocked =>
                      '任务数据或服务端授权不完整，请刷新；前端不会代替服务端放行。',
                  },
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _step == InboundArrivalStep.excessPendingFinance
                        ? theme.colorScheme.error
                        : _step == InboundArrivalStep.awaitingQuality ||
                              _step == InboundArrivalStep.draftPendingInspection
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        // 与旧详情弹窗同口径：办结态按钮保留但禁用——状态文案本身就是信息
        //（已送检张数/暂不能登记原因），不给仓库多余操作。
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: Align(
            alignment: Alignment.centerRight,
            child: UtenButton(
              key: Key('create-receipt-${expectation.id}'),
              size: UtenButtonSize.large,
              icon: switch (_step) {
                InboundArrivalStep.readyToRegister =>
                  Icons.inventory_2_outlined,
                InboundArrivalStep.draftPendingInspection =>
                  Icons.fact_check_outlined,
                InboundArrivalStep.excessPendingFinance =>
                  Icons.account_balance_outlined,
                _ => Icons.hourglass_empty_outlined,
              },
              onPressed: switch (_step) {
                InboundArrivalStep.readyToRegister => onCreateReceipt,
                InboundArrivalStep.draftPendingInspection =>
                  onCompleteRegistration,
                InboundArrivalStep.excessPendingFinance => onOpenExceptions,
                _ => null,
              },
              child: Text(switch (_step) {
                InboundArrivalStep.readyToRegister => '登记实际到货',
                InboundArrivalStep.draftPendingInspection => '继续送检',
                InboundArrivalStep.excessPendingFinance =>
                  '超量待财务(${expectation.openArrivalExceptions}) · 去处理',
                InboundArrivalStep.awaitingQuality =>
                  '已送检(${expectation.pendingInspectionReceipts}) · 结果见品质检查结果页',
                InboundArrivalStep.blocked => '暂不能登记',
              }),
            ),
          ),
        ),
      ],
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
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
