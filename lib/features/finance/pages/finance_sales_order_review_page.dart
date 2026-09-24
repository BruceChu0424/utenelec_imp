// 销售订货单财务审核详情页（V300 专用审核视图，与销售端订单详情分离）。
//
// 设计目标（对齐大公司审批中心：SAP/Oracle 审批详情 = 单据信息 + 风险快照 + 双决策）：
//  - 客户财务快照卡：应收余额 / 信用额度 / 铺底额，超信用红色告警——财务确认前必看；
//  - 订单信息卡：币种加粗红色、发运策略、结帐方式等商业事实；资金状态读取独立财务汇总；
//  - 产品明细保持全局统一表格（MasterDataTableView 嵌入模式）；
//  - 底栏双决策：驳回（必填原因，通知归属销售修正）/ 确认通过（选填备注，放行计划部）。
// 本页不出现销售端运营操作（改量/排产进度/取消订单/红冲），职责分离。
import '../../../shared/attachments/business_attachment_section.dart';
import 'package:flutter/material.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/data_display/uten_revision_table.dart';
import '../widgets/sales_order_revision_table.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/sales_order_finance_confirmation.dart';
import '../repositories/sales_order_finance_confirmation_repository.dart';
import '../../../shared/widgets/sales_order_money_summary_card.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/formatters/exact_decimal.dart';

class FinanceSalesOrderReviewPage extends ConsumerStatefulWidget {
  const FinanceSalesOrderReviewPage({
    super.key,
    required this.id,
    this.returnTo,
  });

  final String id;
  final String? returnTo;

  @override
  ConsumerState<FinanceSalesOrderReviewPage> createState() =>
      _FinanceSalesOrderReviewPageState();
}

class _FinanceSalesOrderReviewPageState
    extends ConsumerState<FinanceSalesOrderReviewPage> {
  SalesOrderFinanceReview? _review;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  // Decisions require confirmed live ownership, including after every dialog.
  TaskClaimSession? _reviewClaim;
  int _loadGeneration = 0;

  bool get _canConfirm =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.salesOrderFinanceConfirm);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    ++_loadGeneration;
    _reviewClaim?.removeListener(_claimChanged);
    _reviewClaim?.releaseAll().ignore();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant FinanceSalesOrderReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) _load();
  }

  void _claimChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final container = ProviderScope.containerOf(context, listen: false);
    final identity = container.read(sessionProvider);
    setState(() {
      _loading = true;
      _error = null;
      _review = null;
    });
    try {
      _reviewClaim?.removeListener(_claimChanged);
      await _reviewClaim?.releaseAll();
      if (!mounted ||
          generation != _loadGeneration ||
          !identical(container.read(sessionProvider), identity)) {
        return;
      }
      _reviewClaim = null;
      if (_canConfirm) {
        final claim = financeReviewClaim(container)..addListener(_claimChanged);
        _reviewClaim = claim;
        // Claim before reading the commercial facts protected by the lease.
        await claim.claimAll('SALES_ORDER_FINANCE_CONFIRM', [widget.id]);
        if (!mounted || generation != _loadGeneration || !claim.isCurrent) {
          await claim.releaseAll();
          return;
        }
      }
      final review = await ref
          .read(salesOrderFinanceConfirmationRepositoryProvider)
          .review(widget.id);
      if (!mounted ||
          generation != _loadGeneration ||
          !identical(container.read(sessionProvider), identity)) {
        return;
      }
      setState(() {
        _review = review;
        _loading = false;
      });
      if (review.financeConfirmed || review.financeRejected) {
        await _reviewClaim?.releaseAll();
      }
    } on ApiException catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = '审核详情加载失败，请检查网络或权限后重试';
        _loading = false;
      });
    }
  }

  Future<void> _confirm() async {
    if (!_canConfirm) {
      context.appWarning('您没有销售订单财务确认权限');
      return;
    }
    final claim = _reviewClaim;
    final reviewed = _review;
    final generation = _loadGeneration;
    if (claim == null || !claim.isReady || reviewed == null || _busy) {
      context.appWarning('尚未取得有效审核占用，请重新认领并核对内容');
      return;
    }
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('确认通过 $widgetSafeBillNo'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const UtenReviewerResponsibilityNotice(
                actionLabel: '销售订单财务确认',
                description: '确认后系统将记录当前审核员，并由该审核员承担本次财务放行责任。',
              ),
              const SizedBox(height: UtenSpacing.s12),
              const Text('确认通过后，该订单将对计划部可见并可排产。可填写确认备注(选填)：'),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                key: const Key('finance-review-confirm-remark'),
                controller: controller,
                maxLength: 500,
                maxLines: 2,
                decoration: UtenInputDecoration(
                  const InputDecoration(
                    labelText: '确认备注(选填)',
                    border: OutlineInputBorder(),
                  ),
                  info: workflowFieldText(context).workflowFinanceReviewHint,
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
          FinanceReviewClaimButton(
            key: const Key('finance-review-confirm-submit'),
            claim: claim,
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
      if (!await claim.validateForDecision() ||
          !mounted ||
          generation != _loadGeneration ||
          !identical(reviewed, _review)) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '审核内容或占用已变化，请重新认领并核对');
        }
        return;
      }
      await ref
          .read(salesOrderFinanceConfirmationRepositoryProvider)
          .confirm(
            widget.id,
            remark: remark,
            expectedRevision: reviewed.financeReviewRevision,
            expectedClaimId: claim.claimIdFor(
              'SALES_ORDER_FINANCE_CONFIRM',
              widget.id,
            )!,
          );
      if (!mounted) return;
      context.appSuccess('已确认通过，计划部已可接手排产');
      refreshBadges(ref);
      _closeAfterDecision();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('确认失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get widgetSafeBillNo => _review?.billNo ?? '';

  /// 办结后的落点：调用方带 returnTo（确认队列/修改队列/业务审核中心）则原样
  /// 回去；深链无 returnTo 时按审核轮次归位（改过的单回「修改」队列）。
  String get _returnPath =>
      widget.returnTo ??
      ((_review?.financeReviewRevision ?? 0) > 0
          ? '/finance/sales-order-changes'
          : '/finance/sales-order-confirmations');

  Future<void> _leaveReview() async {
    await _reviewClaim?.releaseAll();
    if (!mounted) return;
    // 纯查看返回：不 bump、不推进刷新（ADR-108「纯查看后返回不重拉」），
    // 能 pop 就 pop 回打开方；深链无栈才归位到队列页。
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      context.go(_returnPath);
    }
  }

  /// 决策（确认/驳回）完成后的落点：
  /// - 从确认列表/审核中心 push 进来 → 带 true 返回值 pop，打开方立即重拉
  ///   （2026-09-24 用户反馈「审批通过后任务中心待审批还在，要手动刷新才消失」：
  ///   此前 returnTo 非空一律 context.go，`push<bool>` 的 Future 恒返回 null，
  ///   打开方的刷新分支成了死代码，go 重建队列页还丢掉筛选/页码）；
  /// - 从 V459 审核弹窗「去审核」router.go 直达 / 深链 → 路由栈空，
  ///   直接 pop 会抛 GoError 并被外层 catch 误报「确认失败」（v2026.09.03-1
  ///   实际已确认成功）——改跳回确认列表页。
  void _closeAfterDecision() {
    bumpListRefresh(ref, 'finance:sales-order:$_returnPath');
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(true);
    } else {
      context.go(_returnPath);
    }
  }

  Future<void> _reject() async {
    if (!_canConfirm) {
      context.appWarning('您没有销售订单财务确认权限');
      return;
    }
    final claim = _reviewClaim;
    final reviewed = _review;
    final generation = _loadGeneration;
    if (claim == null || !claim.isReady || reviewed == null || _busy) {
      context.appWarning('尚未取得有效审核占用，请重新认领并核对内容');
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
                  actionLabel: '销售订单财务驳回',
                  description: '确认后系统将记录当前审核员、驳回原因和时间，请对本次决定负责。',
                ),
                const SizedBox(height: UtenSpacing.s12),
                const Text('驳回不会改动订单与库存预留；驳回原因将通知归属销售，修正后可重新确认。'),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  key: const Key('finance-review-reject-reason'),
                  controller: controller,
                  autofocus: true,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: '驳回原因(必填)',
                      border: const OutlineInputBorder(),
                      error: utenFieldError(errorText),
                    ),
                    info: workflowFieldText(context).workflowFinanceRejectHint,
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
            FinanceReviewClaimButton(
              key: const Key('finance-review-reject-submit'),
              claim: claim,
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
      if (!await claim.validateForDecision() ||
          !mounted ||
          generation != _loadGeneration ||
          !identical(reviewed, _review)) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '审核内容或占用已变化，请重新认领并核对');
        }
        return;
      }
      await ref
          .read(salesOrderFinanceConfirmationRepositoryProvider)
          .reject(
            widget.id,
            reason: reason,
            expectedRevision: reviewed.financeReviewRevision,
            expectedClaimId: claim.claimIdFor(
              'SALES_ORDER_FINANCE_CONFIRM',
              widget.id,
            )!,
          );
      if (!mounted) return;
      context.appSuccess('已驳回，归属销售将收到修正通知');
      refreshBadges(ref);
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
    ref.watch(sessionProvider);
    ref.listen(sessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      ++_loadGeneration;
      _reviewClaim?.removeListener(_claimChanged);
      _reviewClaim?.releaseAll().ignore();
      _reviewClaim = null;
      if (mounted) {
        setState(() {
          _review = null;
          _loading = false;
          _error = '登录身份已变化，请重新加载并认领审核';
        });
      }
    });
    final theme = Theme.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    final canViewMoneySummary =
        permissions.contains(Perm.financeViewAll) &&
        permissions.contains(Perm.customerPrepaymentView);
    return Scaffold(
      appBar: UtenAppBar(
        title: _review?.revisionDiff != null ? '销售订单修改审核' : '销售订单财务审核',
        leading: UtenBackButton(onPressed: _leaveReview),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            _loading
                ? const Center(
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
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
                : _review == null
                ? const SizedBox.shrink()
                // 2026-09-15 表格宽度口径二修（用户反馈）：上午收进 narrow(1120) 后两侧
                // 大留白，弃 narrow 改默认容器（1600 钳制），对齐新建销售订货单页；
                // 滚动仍为折叠头+表内滚：上滑先收卡片区，明细标题吸顶后在表格内部滚。
                : UtenContentContainer(
                    child: UtenCollapsingHeaderScrollView(
                      collapsingHeader: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_canConfirm &&
                                !_review!.financeConfirmed &&
                                !_review!.financeRejected &&
                                _reviewClaim?.isReady != true) ...[
                              FinanceReviewClaimNotice(
                                claim: _reviewClaim,
                                onRetry: _busy ? null : _load,
                              ),
                              const SizedBox(height: UtenSpacing.s12),
                            ],
                            _statusStrip(theme, _review!),
                            const SizedBox(height: UtenSpacing.s12),
                            _clientFinanceCard(theme, _review!),
                            const SizedBox(height: UtenSpacing.s12),
                            _orderCard(theme, _review!),
                            if (canViewMoneySummary) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              ExpansionTile(
                                title: const Text('资金情况'),
                                children: [
                                  SalesOrderMoneySummaryCard(
                                    salesOrderId: widget.id,
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: UtenSpacing.s12),
                            if (_review!
                                    .revisionDiff
                                    ?.headerChanges
                                    .isNotEmpty ==
                                true) ...[
                              UtenRevisionFields(
                                changes: [
                                  for (final change
                                      in _review!.revisionDiff!.headerChanges)
                                    UtenRevisionField(
                                      label: change.field,
                                      before: _revisionHeaderValue(
                                        change.field,
                                        change.beforeValue,
                                      ),
                                      after: _revisionHeaderValue(
                                        change.field,
                                        change.afterValue,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: UtenSpacing.s12),
                            ],
                            // 销售在订单上上传的合同/确认件（2026-09-09）：财务确认前
                            // 可直接查看（图片/PDF/文本内嵌预览），不再切回销售详情页。
                            BusinessAttachmentSection(
                              ownerType: 'SALES_ORDER',
                              ownerId: _review!.orderId,
                              // 前端展示门=attachment:view；行级可读性由服务端策略复核。
                              canView: ref
                                  .watch(currentPermissionsProvider)
                                  .contains(Perm.attachmentView),
                              canManage: false,
                              title: '销售附件（合同/客户确认/图片）',
                            ),
                            if (_review!.financeRejected) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              _rejectRecordCard(theme, _review!),
                            ],
                          ],
                        ),
                      ),
                      body: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenFloatingActionGroup.controlHeight +
                              UtenSpacing.s32,
                        ),
                        child: _itemsCard(theme, _review!),
                      ),
                    ),
                  ),
            // 处理中屏幕中央加载动画（对齐出货财审专页口径：按钮 isLoading 同步
            // 转圈，不再用固定底栏占位）。
            if (_busy)
              const Positioned.fill(child: UtenBusyOverlay(title: '正在处理，请稍候')),
          ],
        ),
      ),
      // 2026-09-14 UI 统一口径：底部吸底双决策改右下悬浮组（UtenFloatingActionGroup，
      // 与出货财审专页/确认列表同款）；大小/高度/禁用态全站统一。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _review == null ? null : _floatingActions(),
    );
  }

  /// 右下悬浮操作组：待确认=驳回(红)+确认通过；已确认/已驳回/无权限=只留返回。
  /// 未完成审核认领时按钮置灰（点击提示原因），认领就绪才可提交决定。
  Widget _floatingActions() {
    final claimReady = _reviewClaim?.isReady == true;
    final canDecide =
        _canConfirm && !_review!.financeConfirmed && !_review!.financeRejected;
    if (!canDecide) {
      return UtenFloatingActionGroup(
        children: [
          UtenButton(
            key: const Key('finance-review-back'),
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            icon: Icons.arrow_back_rounded,
            onPressed: _leaveReview,
            child: const Text('返回'),
          ),
        ],
      );
    }
    return UtenFloatingActionGroup(
      children: [
        UtenButton(
          key: const Key('finance-review-reject'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: Icons.undo_rounded,
          onPressed: claimReady && !_busy ? _reject : null,
          onDisabledTap: claimReady
              ? null
              : () => context.appWarning('请先完成审核认领，再驳回'),
          child: const Text('驳回'),
        ),
        UtenButton(
          key: const Key('finance-review-confirm'),
          size: UtenButtonSize.large,
          icon: Icons.fact_check_outlined,
          isLoading: _busy,
          onPressed: claimReady && !_busy ? _confirm : null,
          onDisabledTap: claimReady
              ? null
              : () => context.appWarning('请先完成审核认领，再确认'),
          child: const Text('确认通过'),
        ),
      ],
    );
  }

  /// 顶部状态条：单据号 + 已确认/已驳回/待确认状态。
  Widget _statusStrip(ThemeData theme, SalesOrderFinanceReview r) {
    final isRevision = r.revisionDiff != null;
    final confirmed = r.financeConfirmed;
    final rejected = r.financeRejected;
    final color = confirmed
        ? theme.colorScheme.primary
        : rejected
        ? theme.colorScheme.error
        : theme.colorScheme.tertiary;
    final icon = confirmed
        ? Icons.verified_rounded
        : rejected
        ? Icons.undo_rounded
        : Icons.pending_actions_rounded;
    final statusText = confirmed
        ? '已财务确认 · ${r.financeConfirmedByName ?? '当前审核员'}'
              '${r.financeConfirmedAt == null ? '' : ' · ${utenFmtIsoTime(r.financeConfirmedAt)}'}'
        : rejected
        ? '已驳回 · 待销售修改'
        : r.revisionDiff != null
        ? '修改后待复审'
        : '待财务确认';
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
                Text(
                  isRevision ? '销售订单修改' : r.billNo,
                  key: isRevision
                      ? const Key('sales-order-revision-heading')
                      : null,
                  style:
                      (isRevision
                              ? theme.textTheme.titleLarge
                              : theme.textTheme.titleMedium)
                          ?.copyWith(
                            fontWeight: isRevision
                                ? FontWeight.w800
                                : FontWeight.w700,
                            color: isRevision
                                ? theme.colorScheme.primary
                                : null,
                          ),
                ),
                Wrap(
                  spacing: UtenSpacing.s12,
                  runSpacing: UtenSpacing.s4,
                  children: [
                    if (isRevision)
                      Text(r.billNo, style: theme.textTheme.bodyMedium),
                    Text(
                      statusText,
                      style: theme.textTheme.bodySmall?.copyWith(color: color),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 客户财务快照卡：应收余额 / 信用额度 / 铺底额 + 超信用告警。
  Widget _clientFinanceCard(ThemeData theme, SalesOrderFinanceReview r) {
    final over = r.clientOverCredit;
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
                    '客户财务快照 · ${r.clientName ?? '—'}'
                    '${r.clientCode != null ? '(${r.clientCode})' : ''}',
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
                  '应收余额(本币)',
                  _money(r.clientOutstanding),
                  emphasis: true,
                  danger: over,
                ),
                _metric(theme, '信用额度', _money(r.clientCredit)),
                _metric(theme, '铺底额', _money(r.clientCreditFloor)),
                _metric(
                  theme,
                  '本单金额',
                  _money(r.totalOriginal),
                  emphasis: true,
                  danger: true,
                ),
              ],
            ),
            if (over) ...[
              const SizedBox(height: UtenSpacing.s8),
              Container(
                key: const ValueKey('finance-review-over-credit'),
                padding: const EdgeInsets.all(UtenSpacing.s8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(UtenRadius.md),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        '该客户应收余额已超信用额度，请谨慎确认',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
    bool danger = false,
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
            color: danger ? theme.colorScheme.error : null,
          ),
        ),
      ],
    );
  }

  /// 订单信息卡：币种加粗红色与销售端详情同规则。
  Widget _orderCard(ThemeData theme, SalesOrderFinanceReview r) {
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenFormGrid(
              children: [
                kv('业务员', r.sellerName),
                kv('交货日', r.deliverDate),
                kv('币种', _currencyLabel(r), highlight: true),
                kv('发运策略', r.shipmentPolicyName ?? r.shipmentPolicy),
                kv('结帐方式', r.settlementMethodName),
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('更多订单信息'),
              children: [
                UtenFormGrid(
                  children: [
                    kv('单据日期', r.billDate),
                    kv('制单员', r.makerName),
                    kv('制单时间', utenFmtIsoTime(r.createdAt)),
                    kv('合同号', r.contractNo),
                    kv('备注', r.remark),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 产品明细：保持全局统一表格（MasterDataTableView），2026-09-15 起随折叠容器
  /// 内滚（primary 拾取联动控制器）——标题钉在 body 顶，表格占满剩余高度内部滚动，
  /// 合计条走 summaryBar 槽位 + summaryBarInline（表内脚注：跟在最后一行数据
  /// 之下随表体滚动，不再钉在表体外的底部）。
  Widget _itemsCard(ThemeData theme, SalesOrderFinanceReview r) {
    if (r.revisionDiff != null) {
      return SalesOrderRevisionTable(
        diff: r.revisionDiff!,
        currencyLabel: _currencyLabel(r),
        summaryBar: _itemsSummary(r),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '产品明细(${r.items.length})',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: MasterDataTableView<SalesOrderFinanceReviewLine>(
            primary: true,
            bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
            columns: [
              // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列，
              // 不再拼成「编号 · 名称(颜色 · 单位)」一长串。
              MasterColumnDef(
                key: 'goods',
                label: '货品名称',
                width: 200,
                value: (it) => it.goodsName ?? it.goodsCode ?? '—',
              ),
              MasterColumnDef(
                key: 'goodsCode',
                label: '编号',
                width: 130,
                value: (it) => UtenGoodsAttributeCell.text(it.goodsCode),
                cellBuilder: (_, it) => UtenGoodsAttributeCell(it.goodsCode),
              ),
              MasterColumnDef(
                key: 'colorName',
                label: '颜色',
                width: 96,
                value: (it) => UtenGoodsAttributeCell.text(it.colorName),
                cellBuilder: (_, it) => UtenGoodsAttributeCell(it.colorName),
              ),
              MasterColumnDef(
                key: 'unitName',
                label: '单位',
                width: 80,
                value: (it) => UtenGoodsAttributeCell.text(it.unitName),
                cellBuilder: (_, it) => UtenGoodsAttributeCell(it.unitName),
              ),
              MasterColumnDef(
                key: 'clientModel',
                label: '客型',
                width: 110,
                value: (it) => UtenGoodsAttributeCell.text(it.clientModel),
                cellBuilder: (_, it) => UtenGoodsAttributeCell(it.clientModel),
              ),
              MasterColumnDef(
                key: 'qty',
                label: '数量',
                width: 90,
                type: 'number',
                value: (it) => _trimNum(it.qty),
              ),
              // 实际重量列已下线（2026-09-04：单位已表达重量，销售订单编辑不再录入）。
              MasterColumnDef(
                key: 'price',
                label: '单价',
                width: 110,
                type: 'money',
                value: (it) => _trimNum(it.price),
              ),
              MasterColumnDef(
                key: 'discount',
                label: '折扣',
                width: 80,
                type: 'number',
                value: (it) => _trimNum(it.discount),
              ),
              MasterColumnDef(
                key: 'amount',
                label: '金额(${_currencyLabel(r)})',
                width: 120,
                type: 'money',
                value: (it) => _trimNum(it.amountOriginal),
              ),
              MasterColumnDef(
                key: 'remark',
                label: '备注',
                width: 160,
                value: (it) =>
                    (it.remark?.isNotEmpty ?? false) ? it.remark : null,
              ),
            ],
            items: r.items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            emptyMessage: '(无明细)',
            // 2026-09-15 用户口径：合计条属于表格那一块——渲染进表体滚动内容
            // 末尾（最后一行数据之下），不钉在表体外/按钮上方。
            summaryBar: _itemsSummary(r),
            summaryBarInline: true,
          ),
        ),
      ],
    );
  }

  Widget? _itemsSummary(SalesOrderFinanceReview r) => r.items.isEmpty
      ? null
      : UtenTotalsSummaryBar(
          density: true,
          entries: [
            UtenTotalEntry(
              '合计数量',
              measurementTotalsText(
                r.items.map(
                  (it) => MeasuredAmount(
                    value: double.tryParse(it.qty ?? '') ?? 0,
                    unitId: it.unitId,
                    unitName: it.unitName,
                  ),
                ),
              ),
            ),
            UtenTotalEntry(
              '合计金额(${_currencyLabel(r)})',
              _money(r.totalOriginal),
              danger: true,
            ),
          ],
        );

  /// 驳回记录卡：原因 + 驳回人 + 时间。
  Widget _rejectRecordCard(ThemeData theme, SalesOrderFinanceReview r) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.undo_rounded, color: theme.colorScheme.error),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '驳回记录',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(r.financeRejectedReason ?? '未注明原因'),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '${r.financeRejectedByName ?? '—'} · ${utenFmtIsoTime(r.financeRejectedAt)}',
                    style: theme.textTheme.bodySmall?.copyWith(
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

  /// 币种展示只使用主档名称或可读标准代码，不暴露旧数字编号。
  String _revisionHeaderValue(String field, String value) => field == '发运策略'
      ? switch (value) {
          'ALLOW_PARTIAL' => '允许分批发货',
          'REQUIRE_COMPLETE' => '整单齐套后发货',
          'CUSTOMER_CONFIRM' => '客户确认后分批',
          'LEGACY_UNSPECIFIED' => '历史订单(未指定)',
          _ => value,
        }
      : value;

  String _currencyLabel(SalesOrderFinanceReview r) =>
      financeCurrencyDisplayLabel(name: r.currencyName, code: r.currencyCode) ??
      '订单币种';

  /// 金额按服务端十进制原文显示(ADR-112): 至少 2 位小数、多余的 0 去掉, 不经过 double、不四舍五入。
  String _money(String? raw) {
    if (raw == null || raw.isEmpty) return '—';
    return financeExactDecimal(raw) == null
        ? raw
        : financeExactMoneyDisplay(raw);
  }

  /// 数量/单价/汇率按原文去掉末尾多余的 0, 不四舍五入到 2 位。
  String? _trimNum(String? raw) => financeExactTrimmed(raw);
}
