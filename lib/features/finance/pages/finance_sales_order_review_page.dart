import 'package:uten_imp/components/feedback/uten_dialog.dart';
import '../../../shared/business_columns/business_columns_table.dart';
// 销售订货单财务审核详情页（V300 专用审核视图，与销售端订单详情分离）。
//
// 设计目标（对齐大公司审批中心：SAP/Oracle 审批详情 = 单据信息 + 风险快照 + 双决策）：
//  - 客户财务快照卡：应收余额 / 信用额度 / 铺底额，超信用红色告警——财务确认前必看；
//    ADR-128 起应收按本单币种显示，卡片用财务共用的 FinancePartySnapshotCard；
//  - 订单信息卡：币种加粗红色、发运策略、结帐方式等商业事实；资金状态读取独立财务汇总；
//  - 产品明细保持全局统一表格（MasterDataTableView 嵌入模式）；
//  - 底栏双决策：驳回（必填原因，通知归属销售修正）/ 确认通过（选填备注，放行计划部）。
// 审核只查看提交的商业事实；需要修正时驳回，由销售修改并重新送审。
//
// 2026-09-27 报价核价(ADR-134)：报价转入的订单在状态条下显示「来源报价 · 报价已核价 · 一致」
// 条带；明细多出报价单价/报价折扣/与报价三列，并只读显示订单与报价的差异。
// 带客户文件信息的行再显示文件单价/文件型号/文件品名。
// 新增文字走 arb；只在有来源报价或文件信息时才取本地化实例(老订单照旧)。
import '../../../shared/attachments/business_attachment_section.dart';
import 'package:flutter/material.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/data_display/uten_detail_summary_card.dart';
import '../../../components/data_display/uten_revision_table.dart';
import '../../../components/data_display/uten_status_badge.dart';
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
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/measurement/exact_measurement_totals.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../../shared/widgets/sales_document_layout.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/sales_order_finance_confirmation.dart';
import '../repositories/sales_order_finance_confirmation_repository.dart';
import '../widgets/finance_document_unapproval_action.dart';
import '../../../shared/drafts/review_task_draft.dart';
import '../../../shared/drafts/review_authority_refresh_mixin.dart';
import '../../../shared/widgets/sales_order_money_summary_card.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../widgets/finance_party_snapshot_card.dart';

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
    extends ConsumerState<FinanceSalesOrderReviewPage>
    with
        FormDraftMixin<FinanceSalesOrderReviewPage>,
        ReviewTaskDraftMixin<FinanceSalesOrderReviewPage>,
        ReviewAuthorityRefreshMixin<FinanceSalesOrderReviewPage> {
  SalesOrderFinanceReview? _review;
  bool _loading = true;
  bool _busy = false;
  bool _authorityStale = false;
  @override
  Set<String> get reviewAuthorityPermissionCodes => const {
    Perm.salesOrderFinanceView,
    Perm.salesOrderFinanceConfirm,
    Perm.salesOrderReverse,
  };
  @override
  bool get reviewAuthorityRefreshBlocked =>
      _loading ||
      _busy ||
      formDraftHasUnknownSubmission ||
      formDraftRestorationBlocked;
  @override
  Future<void> refreshReviewAuthority() => _load(authorityOnly: true);
  bool _summaryExpanded = false;
  String? _error;

  /// 明细行勾选集（2026-10-10 审核页防看岔行口径：纯阅读辅助，无行级批量
  /// 动作，整单决策仍走底部确认/驳回）。
  final Set<String> _selectedLineIds = <String>{};

  // Decisions require confirmed live ownership, including after every dialog.
  TaskClaimSession? _reviewClaim;
  int _loadGeneration = 0;
  final _confirmRemark = TextEditingController();
  final _rejectReason = TextEditingController();
  @override
  bool get formDraftBusy => _busy;
  @override
  FormDraftDescriptor get reviewDraftDescriptor =>
      FormDraftCatalog.financeSalesOrderReview;
  @override
  String get reviewDraftRoute =>
      '/finance/sales-order-confirmations/${Uri.encodeComponent(widget.id)}';
  @override
  Map<String, dynamic> get reviewDraftSource => {
    'subjectId': widget.id,
    'version': _review?.financeReviewRevision,
    'lineIds':
        (_review?.items.map((line) => line.itemId).toList() ?? <String>[])
          ..sort(),
  };
  @override
  bool get reviewDraftEditable =>
      _review != null &&
      _canConfirm &&
      !_review!.financeConfirmed &&
      !_review!.financeRejected &&
      _review!.requotedToId == null;
  @override
  bool canDispatchReviewCommand(String action) =>
      reviewDraftEditable &&
      _reviewClaim?.isReady == true &&
      (action == 'confirm' || action == 'reject');
  @override
  Iterable<Listenable> get formDraftListenables => [
    _confirmRemark,
    _rejectReason,
  ];
  @override
  Map<String, dynamic> captureReviewInputs() => {
    'confirmRemark': _confirmRemark.text,
    'rejectReason': _rejectReason.text,
  };
  @override
  void restoreReviewInputs(Map<String, dynamic> inputs) {
    _confirmRemark.text = inputs['confirmRemark'] as String? ?? '';
    _rejectReason.text = inputs['rejectReason'] as String? ?? '';
  }

  @override
  Future<void> reloadReviewSource() async {
    await _load();
    if (_error != null || _review == null) {
      throw StateError(_error ?? '订单审核结果尚未读取');
    }
  }

  @override
  Future<bool> recoverReviewCommand(Map<String, dynamic> command) async {
    final current = await ref
        .read(salesOrderFinanceConfirmationRepositoryProvider)
        .review(widget.id);
    final source = command['source'];
    if (source is! Map ||
        source['subjectId'] != widget.id ||
        current.orderId != widget.id ||
        source['version'] != current.financeReviewRevision) {
      return false;
    }
    return switch (command['action']) {
      'confirm' =>
        current.financeConfirmed &&
            (current.financeConfirmRemark ?? '').trim() ==
                ((command['request'] as Map?)?['remark'] as String? ?? '')
                    .trim(),
      'reject' =>
        current.financeRejected &&
            current.financeRejectedReason ==
                (command['request'] as Map?)?['reason'],
      _ => false,
    };
  }

  @override
  void closeRecoveredReview() => _closeAfterDecision();
  bool get _canConfirm =>
      !_authorityStale &&
      _review?.requotedToId == null &&
      (ref.read(isSuperAdminProvider) ||
          ref.read(currentPermissionsProvider).containsAll({
            Perm.salesOrderFinanceView,
            Perm.salesOrderFinanceConfirm,
          }));

  @override
  void initState() {
    super.initState();
    initializeReviewAuthorityRefresh();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    ++_loadGeneration;
    _reviewClaim?.removeListener(_claimChanged);
    _reviewClaim?.releaseAll().ignore();
    _confirmRemark.dispose();
    _rejectReason.dispose();
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

  Future<void> _load({bool authorityOnly = false}) async {
    final previousReview = _review;
    final preserveInputs = authorityOnly && previousReview != null;
    if (preserveInputs && reviewAuthorityRefreshBlocked) return;
    if (!preserveInputs) await prepareReviewReload();
    if (!mounted || !formDraftIdentityIsCurrent) return;
    final generation = ++_loadGeneration;
    final container = ProviderScope.containerOf(context, listen: false);
    final identity = container.read(sessionProvider);
    setState(() {
      _loading = true;
      _error = null;
      if (!preserveInputs) {
        _review = null;
        _authorityStale = false;
      }
    });
    try {
      _reviewClaim?.removeListener(_claimChanged);
      await _reviewClaim?.releaseAll();
      if (!mounted ||
          generation != _loadGeneration ||
          !container.read(sessionProvider).isSameIdentity(identity)) {
        return;
      }
      _reviewClaim = null;
      if (_canConfirm) {
        final claim = financeReviewClaim(
          container,
          localizations: AppLocalizations.of(context),
        )..addListener(_claimChanged);
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
          !container.read(sessionProvider).isSameIdentity(identity)) {
        return;
      }
      if (preserveInputs &&
          (review.financeReviewRevision !=
                  previousReview.financeReviewRevision ||
              review.financeConfirmed != previousReview.financeConfirmed ||
              review.financeRejected != previousReview.financeRejected ||
              review.requotedToId != previousReview.requotedToId)) {
        await _reviewClaim?.releaseAll();
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          _authorityStale = true;
          _loading = false;
          _error = AppLocalizations.of(context).financeReviewAuthorityChanged;
        });
        return;
      }
      setState(() {
        _review = review;
        _authorityStale = false;
        _loading = false;
        if (!preserveInputs) {
          _confirmRemark.clear();
          _rejectReason.clear();
        }
      });
      await bindReviewDraft();
      if (review.financeConfirmed ||
          review.financeRejected ||
          review.requotedToId != null) {
        await _reviewClaim?.releaseAll();
      }
    } on ApiException catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = e.message;
        if (preserveInputs) _authorityStale = true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = AppLocalizations.of(context).financeReviewLoadFailed;
        if (preserveInputs) _authorityStale = true;
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
      context.appWarning('审核认领还没有生效，请重新认领并核对内容');
      return;
    }
    final controller = _confirmRemark;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => UtenAlertDialog(
        title: Text('确认通过 ${reviewed.billNo}'),
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
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      if (!await claim.validateForDecision() ||
          !mounted ||
          generation != _loadGeneration ||
          !identical(reviewed, _review)) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '审核内容或认领已变化，请重新认领并核对');
        }
        return;
      }
      await submitReviewCommand(
        'confirm',
        () => ref
            .read(salesOrderFinanceConfirmationRepositoryProvider)
            .confirm(
              widget.id,
              remark: remark,
              expectedRevision: reviewed.financeReviewRevision,
              expectedClaimId: claim.claimIdFor(
                'SALES_ORDER_FINANCE_CONFIRM',
                widget.id,
              )!,
            ),
        request: {'remark': remark.trim()},
      );
      if (!mounted) return;
      await finishReviewDraft();
      if (!mounted || !formDraftIdentityIsCurrent) return;
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

  String get _returnPath =>
      widget.returnTo ??
      '/finance/sales-order-confirmations?state=${_review?.financeConfirmed == true
          ? 'confirmed'
          : (_review?.financeReviewRevision ?? 0) > 0
          ? 'changes'
          : 'pending'}';

  Future<void> _leaveReview() async {
    if (!await confirmFormDraftExit() || !mounted) return;
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
      context.appWarning('审核认领还没有生效，请重新认领并核对内容');
      return;
    }
    final controller = _rejectReason;
    String? errorText;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => UtenAlertDialog(
          title: Text('驳回 ${reviewed.billNo}'),
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
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      if (!await claim.validateForDecision() ||
          !mounted ||
          generation != _loadGeneration ||
          !identical(reviewed, _review)) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '审核内容或认领已变化，请重新认领并核对');
        }
        return;
      }
      await submitReviewCommand(
        'reject',
        () => ref
            .read(salesOrderFinanceConfirmationRepositoryProvider)
            .reject(
              widget.id,
              reason: reason,
              expectedRevision: reviewed.financeReviewRevision,
              expectedClaimId: claim.claimIdFor(
                'SALES_ORDER_FINANCE_CONFIRM',
                widget.id,
              )!,
            ),
        request: {'reason': reason.trim()},
      );
      if (!mounted) return;
      await finishReviewDraft();
      if (!mounted || !formDraftIdentityIsCurrent) return;
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
    scheduleReviewAuthorityRefresh();
    ref.watch(sessionProvider);
    ref.listen(sessionProvider, (previous, next) {
      // 只有真实换身份才清空（换号/登出/模拟切换/业务重置）；token 静默刷新、
      // 同身份授权变化由独立监听刷新动作与认领，保留原审核输入。
      if (previous?.isSameIdentity(next) ?? false) return;
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
    return withFormDraft(
      Scaffold(
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
                  // 默认容器不设固定最大宽度，正文随导航收起和窗口加宽扩展；
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
                              _summaryCard(
                                theme,
                                _review!,
                                canViewMoneySummary: canViewMoneySummary,
                              ),
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
                const Positioned.fill(
                  child: UtenBusyOverlay(title: '正在处理，请稍候'),
                ),
            ],
          ),
        ),
        // 2026-09-14 UI 统一口径：底部吸底双决策改右下悬浮组（UtenFloatingActionGroup，
        // 与出货财审专页/确认列表同款）；大小/高度/禁用态全站统一。
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: _review == null ? null : _floatingActions(),
      ),
    );
  }

  /// 右下悬浮操作组：待确认=驳回(红)+确认通过；历史按原单反审权限办理。
  /// 未完成审核认领时按钮置灰（点击提示原因），认领就绪才可提交决定。
  Widget _floatingActions() {
    final claimReady = _reviewClaim?.isReady == true;
    final canDecide =
        _canConfirm && !_review!.financeConfirmed && !_review!.financeRejected;
    if (!canDecide) {
      return UtenFloatingActionGroup(
        children: [
          if (_review!.financeConfirmed &&
              _review!.requotedToId == null &&
              (ref.watch(isSuperAdminProvider) ||
                  ref.watch(currentPermissionsProvider).containsAll({
                    'sales_order:view',
                    'sales_order:reverse',
                  })))
            FinanceDocumentUnapprovalAction(
              key: const Key('finance-sales-order-unapprove'),
              family: 'salesOrder',
              documentId: widget.id,
              revision: _review!,
              validateReview: () async {
                final current = await ref
                    .read(salesOrderFinanceConfirmationRepositoryProvider)
                    .review(widget.id);
                return current.financeConfirmed &&
                    current.requotedToId == null &&
                    current.financeReviewRevision ==
                        _review!.financeReviewRevision;
              },
              onCompleted: _closeAfterDecision,
            ),
          if (_review!.requotedToId != null &&
              ref
                  .watch(currentPermissionsProvider)
                  .contains(Perm.salesQuoteView))
            UtenButton(
              key: const Key('finance-review-requote'),
              type: UtenButtonType.secondary,
              size: UtenButtonSize.large,
              icon: Icons.open_in_new_rounded,
              onPressed: () => context.push(
                '/sales/quotes/${_review!.requotedToId}?history=1',
              ),
              child: const Text('查看首次重新报价'),
            )
          else if (_review!.requotedToId != null)
            const Text('首次重新报价历史已保留；需销售报价查看权限'),
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
    return UtenStatusBadge(
      label: r.readOnlyReason != null
          ? '只读'
          : r.financeConfirmed
          ? '已财务确认'
          : r.financeRejected
          ? '已驳回 · 待销售修改'
          : r.revisionDiff != null
          ? '修改后待复审'
          : '待财务确认',
      type: r.readOnlyReason != null
          ? UtenStatusBadgeType.neutral
          : r.financeConfirmed
          ? UtenStatusBadgeType.success
          : r.financeRejected
          ? UtenStatusBadgeType.danger
          : UtenStatusBadgeType.warning,
    );
  }

  /// 客户财务快照卡(ADR-128)：本单金额与客户在本单币种下的应收 / 可用预收 / 还差多少
  /// 放在一起比；信用额度只和全部币种应收(折本币，不扣预收)比，超额标红并出横幅。
  /// 来源报价条带(ADR-134)：来源报价单号 + 核价人 + 与报价是否一致。
  Widget _sourceQuoteStrip(ThemeData theme, SalesOrderFinanceReview r) {
    final l10n = AppLocalizations.of(context);
    final quote = r.sourceQuote!;
    final mismatched = r.items.where((it) => it.matchesQuote == false).length;
    final allMatch = r.matchesQuote ?? (mismatched == 0);
    final confirmedBy = quote.financeConfirmedByName;
    final confirmedLabel = confirmedBy == null
        ? l10n.salesQuoteStatusSourceQuoteConfirmed
        : quote.financeConfirmedAt == null
        ? l10n.quoteFinanceOrderQuoteConfirmedBy(confirmedBy)
        : '${l10n.quoteFinanceOrderQuoteConfirmedBy(confirmedBy)}'
              ' · ${utenFmtIsoTime(quote.financeConfirmedAt)}';
    return Container(
      key: const Key('finance-review-source-quote'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                l10n.quoteFinanceOrderSourceQuote(quote.billNo ?? '—'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              UtenStatusBadge(
                label: confirmedLabel,
                type: UtenStatusBadgeType.success,
                icon: Icons.verified_rounded,
              ),
              UtenStatusBadge(
                key: const Key('finance-review-quote-match'),
                label: allMatch
                    ? l10n.quoteFinanceOrderAllMatch
                    : l10n.quoteFinanceOrderMismatch(mismatched),
                type: allMatch
                    ? UtenStatusBadgeType.success
                    : UtenStatusBadgeType.warning,
                icon: allMatch
                    ? Icons.check_circle_outline_rounded
                    : Icons.warning_amber_rounded,
              ),
            ],
          ),
          if (allMatch) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(
              l10n.quoteFinanceOrderChipHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _clientFinanceCard(SalesOrderFinanceReview r) {
    return FinancePartySnapshotCard(
      title: '客户往来',
      balance: r.clientBalance,
      embedded: true,
      expanded: _summaryExpanded,
      limitLabel: '信用额度',
      overLimitWarning: '该客户全部币种应收(折本币，不扣预收)已超信用额度，请谨慎确认',
      trailing: [
        FinanceSnapshotMetric(
          '铺底额',
          r.clientCreditFloor == null
              ? null
              : financeMoneyWithUnitSuffix(
                  r.clientCreditFloor,
                  currencyName: r.clientBalance?.baseCurrencyName,
                  fullCurrencyName: true,
                ),
        ),
      ],
    );
  }

  Widget _summaryCard(
    ThemeData theme,
    SalesOrderFinanceReview r, {
    required bool canViewMoneySummary,
  }) {
    Widget card(
      List<Widget> metrics,
      List<Widget> fundingDetails,
      List<Widget> fundingNotices,
    ) => UtenDetailSummaryCard(
      key: ValueKey('sales-order-summary-${r.orderId}'),
      heading: Wrap(
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (r.revisionDiff != null)
            const Text('销售订单修改', key: Key('sales-order-revision-heading')),
          Text(r.billNo),
          Text(
            '${r.clientName ?? '—'}'
            '${r.clientCode == null ? '' : ' (${r.clientCode})'}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      status: _statusStrip(theme, r),
      expanded: _summaryExpanded,
      onExpandedChanged: (value) => setState(() => _summaryExpanded = value),
      primary: [
        UtenSummaryField(
          label: '本单金额',
          value: financeMoneyWithUnitSuffix(
            r.totalOriginal,
            currencyName: r.currencyName,
            currencyCode: r.currencyCode,
            fullCurrencyName: true,
          ),
          emphasis: true,
          danger: true,
        ),
        ...metrics,
        UtenSummaryField(label: '交货日', value: r.deliverDate, emphasis: true),
      ],
      facts: [
        UtenSummaryField(label: '业务员', value: r.sellerName),
        UtenSummaryField(label: '结帐方式', value: r.settlementMethodName),
        UtenSummaryField(
          label: '发运策略',
          value: r.shipmentPolicyName ?? r.shipmentPolicy,
        ),
      ],
      notices: [
        if (r.readOnlyReason != null)
          Text(
            r.readOnlyReason!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        if (r.sourceQuote != null) _sourceQuoteStrip(theme, r),
        _clientFinanceCard(r),
        ...fundingNotices,
      ],
      details: [
        UtenSummaryFacts(
          children: [
            UtenSummaryField(label: '单据日期', value: r.billDate),
            UtenSummaryField(label: '制单员', value: r.makerName),
            UtenSummaryField(label: '制单时间', value: utenFmtIsoTime(r.createdAt)),
            UtenSummaryField(label: '合同号', value: r.contractNo),
            if (r.financeConfirmed)
              UtenSummaryField(label: '财务确认人', value: r.financeConfirmedByName),
            if (r.financeConfirmedAt != null)
              UtenSummaryField(
                label: '财务确认时间',
                value: utenFmtIsoTime(r.financeConfirmedAt),
              ),
          ],
        ),
        UtenSummaryField(label: '备注', value: r.remark),
        if (fundingDetails.isNotEmpty)
          Text('订单资金明细', style: theme.textTheme.titleSmall),
        ...fundingDetails,
      ],
    );
    if (!canViewMoneySummary) return card(const [], const [], const []);
    return SalesOrderMoneySummaryCard(
      salesOrderId: widget.id,
      showOrderTotal: false,
      summaryBuilder: (context, metrics, details, notices) =>
          card(metrics, details, notices),
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
        currencyLabel: r.currencyLabel,
        summaryBar: _itemsSummary(r),
      );
    }
    final hasQuote = r.sourceQuote != null;
    final hasFile = r.items.any(
      (it) =>
          it.clientPrice != null ||
          it.clientModel != null ||
          it.clientGoodsName != null,
    );
    // 老订单(无来源报价、无客户文件信息)不取本地化实例，列与文案保持原样。
    final l10n = hasQuote || hasFile ? AppLocalizations.of(context) : null;
    return MasterDataTableView<SalesOrderFinanceReviewLine>(
      tableKey: 'sales.order.items',
      primary: true,
      bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
      // 行勾选（防看岔行）：单击选中该行、再点取消、点其他行自动换选（单选
      // 互斥，2026-10-10 口径「默认不要多选」）；无批量动作，「已选 N」胶囊
      // 也不驻留——选中态由青绿行高亮表达，不画最前列勾选框列。
      selectable: true,
      showSelectionColumn: false,
      singleSelection: true,
      showSelectionSummary: false,
      idOf: (it) => it.itemId.isEmpty ? null : it.itemId,
      selectedIds: _selectedLineIds,
      onSelectedIdsChanged: (next) => setState(() {
        _selectedLineIds
          ..clear()
          ..addAll(next);
      }),
      columns:
          canonicalSalesColumns<MasterColumnDef<SalesOrderFinanceReviewLine>>([
            // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列，
            // 不再拼成「编号 · 名称(颜色 · 单位)」一长串。
            MasterColumnDef(
              key: 'goods',
              label: '货品名称',
              width: 200,
              value: (it) => it.goodsName ?? it.goodsCode ?? '—',
            ),
            MasterColumnDef<SalesOrderFinanceReviewLine>(
              key: 'nameEn',
              label: '英文名称',
              width: 180,
              value: (line) => line.goodsNameEn,
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
            // 2026-10-10「数量+单位」全站口径：单位内联在数字后（12 PCS），
            // 独立「单位」列退役；客型列此前已退役（开单不录入，审单看是空列）。
            MasterColumnDef(
              key: 'qty',
              label: '数量',
              width: 125,
              type: 'number',
              value: (it) => formatExactQtyWithUnit(it.qty, it.unitName),
            ),
            // 实际重量列已下线（2026-09-04：单位已表达重量，销售订单编辑不再录入）。
            // 2026-10-10 金额带单位口径：币种后缀进数值（0.5 元 / 1500 美金），列头
            // 不再重复写币种。
            MasterColumnDef(
              key: 'price',
              label: '单价',
              width: 130,
              type: 'money',
              value: (it) => financeMoneyWithUnitSuffix(
                it.price,
                currencyName: r.currencyName,
                currencyCode: r.currencyCode,
              ),
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
              label: '总金额(订单币种)',
              width: 150,
              type: 'money',
              value: (it) => financeMoneyWithUnitSuffix(
                it.amountOriginal,
                currencyName: r.currencyName,
                currencyCode: r.currencyCode,
              ),
            ),
            if (l10n != null && hasQuote) ...[
              MasterColumnDef(
                key: 'quotePrice',
                label: l10n.quoteFinanceOrderColQuotePrice,
                width: 130,
                type: 'money',
                value: (it) =>
                    financeLocalMoneyWithUnitSuffix(_trimNum(it.quotePrice)),
              ),
              MasterColumnDef(
                key: 'quoteDiscount',
                label: l10n.quoteFinanceOrderColQuoteDiscount,
                width: 96,
                type: 'number',
                value: (it) => _trimNum(it.quoteDiscount),
              ),
              MasterColumnDef(
                key: 'matchesQuote',
                label: l10n.quoteFinanceOrderColMatch,
                width: 96,
                value: (it) => switch (it.matchesQuote) {
                  true => l10n.quoteFinanceOrderMatchYes,
                  false => l10n.quoteFinanceOrderMatchNo,
                  null => null,
                },
                cellColor: (context, it) => it.matchesQuote == false
                    ? Theme.of(context).colorScheme.errorContainer
                    : null,
              ),
            ],
            if (l10n != null && hasFile) ...[
              MasterColumnDef(
                key: 'clientPrice',
                // 文件单价带文件币种后缀；文件币种未知时退回纯数值。
                label: l10n.quoteFinanceOrderColFilePrice(
                  r.clientFileCurrency ??
                      l10n.quoteFinanceOrderFileCurrencyUnknown,
                ),
                width: 140,
                type: 'money',
                value: (it) => r.clientFileCurrency == null
                    ? _trimNum(it.clientPrice)
                    : financeMoneyWithUnitSuffix(
                        it.clientPrice,
                        currencyName: r.clientFileCurrency,
                      ),
              ),
              MasterColumnDef(
                key: 'clientModel',
                label: l10n.quoteFinanceOrderColFileModel,
                width: 130,
                value: (it) => it.clientModel,
              ),
              MasterColumnDef(
                key: 'clientGoodsName',
                label: l10n.quoteFinanceOrderColFileName,
                width: 200,
                value: (it) => it.clientGoodsName,
              ),
            ],
            MasterColumnDef(
              key: 'remark',
              label: '备注',
              width: 160,
              value: (it) =>
                  (it.remark?.isNotEmpty ?? false) ? it.remark : null,
            ),
            ...businessReadOnlyColumns<SalesOrderFinanceReviewLine>(
              r.items,
              columnsOf: (line) => line.extraColumns,
            ),
          ], keyOf: (column) => column.key),
      items: r.items,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      emptyMessage: '(无明细)',
      // 2026-09-15 用户口径：合计条属于表格那一块——渲染进表体滚动内容
      // 末尾（最后一行数据之下），不钉在表体外/按钮上方。
      summaryBar: _itemsSummary(r),
    );
  }

  Widget? _itemsSummary(SalesOrderFinanceReview r) => r.items.isEmpty
      ? null
      : UtenTotalsSummaryBar(
          density: true,
          rowCount: r.items.length,
          entries: [
            UtenTotalEntry(
              '合计数量',
              exactMeasurementTotalsText(
                r.items.map(
                  (it) => ExactMeasuredAmount(
                    value: it.qty,
                    unitId: it.unitId,
                    unitName: it.unitName,
                  ),
                ),
              ),
            ),
            UtenTotalEntry(
              '合计金额',
              financeMoneyWithUnitSuffix(
                r.totalOriginal,
                currencyName: r.currencyName,
                currencyCode: r.currencyCode,
              ),
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

  /// 数量/单价/汇率按原文去掉末尾多余的 0, 不四舍五入到 2 位。
  String? _trimNum(String? raw) => financeExactTrimmed(raw);
}
