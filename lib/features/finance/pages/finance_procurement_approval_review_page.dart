import '../../../shared/business_columns/business_columns_table.dart';
// 订货审批审核详情页（财务专用视图，与采购/委外业务订货详情页分离）。
//
// 设计目标（对齐销售订单财务审核页 V300 范式 = 大公司审批中心：单据信息 +
// 风险快照 + 底部双决策）：
//  - 供应商财务快照卡：应付余额（AP 未结合计）/ 本单金额 / 折合人民币——财务放行前必看；
//  - 订单信息卡：币种加粗红色、税率、结算方式等商业事实；数据源为审批 case
//    投影（审批哈希锁定的提交内容），不是业务编辑视角；
//  - 订货明细保持全局统一表格，独立 tableKey（2026-10-10：不再复用编辑页
//    purchase/subcontract.order.items——MasterDataTableView 保存布局合并会把
//    本页新键甩到尾部，且本页列序与编辑页不同）；
//  - 滚动结构对齐销售财审页（2026-10-10）：UtenCollapsingHeaderScrollView
//    折叠头（状态条/快照/订单信息/附件/审批历史）+ body 明细表内滚；
//  - 汇率（case 级记账汇率，非行单位换算率）：2026-10-10 起直接在明细表「汇率」
//    列单元格里填写（case 级单值，任一格输入全列同步），实时重算折合人民币列
//    与合计，通过时随审批落 case（V438 迁移冻结期间订单表头汇率禁改）；已批
//    只读显示财务落定的汇率；
//  - 明细表支持行勾选（2026-10-10 审核页防看岔行口径）：纯阅读辅助，无行级
//    批量动作，整单决策仍走底部通过/驳回；
//  - 审批历史卡：逐轮 提交/驳回/通过 事件与驳回原因；
//  - 底栏三操作：驳回（必填原因）/ 通过（选填备注）/ 返回——不必退回任务中心即可决策。
// 本页不出现采购/委外业务操作（改量/编辑/红冲/收货），职责分离；按钮按服务端
// allowedActions（实时审核资格 × 权限码）渲染，未授权动作不显示。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/data_display/uten_revision_table.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart' show utenFmtIsoTime;
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../finance_workflow_routes.dart';
import '../models/finance_procurement_workflow.dart';
import '../models/finance_procurement_revision.dart';
import '../repositories/finance_procurement_workflow_repository.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../../shared/models/party_open_balance.dart';
import '../widgets/finance_party_snapshot_card.dart';

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
  TaskClaimSession? _reviewClaim;
  int _loadGeneration = 0;

  /// 汇率编辑框（case 级记账汇率，非行单位换算率）：加载后预填
  /// financeExchangeRate ?? 提交快照 exchangeRate ?? 1，未批 case 可改。
  final TextEditingController _rateController = TextEditingController();

  /// 明细行勾选集（防看岔行的纯阅读辅助，无行级批量动作）。
  final Set<String> _selectedLineIds = <String>{};

  void _claimChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ++_loadGeneration;
    _rateController.dispose();
    _reviewClaim?.removeListener(_claimChanged);
    _reviewClaim?.releaseAll().ignore();
    super.dispose();
  }

  @override
  void didUpdateWidget(
    covariant FinanceProcurementApprovalReviewPage oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.caseId != widget.caseId) _load();
  }

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
          !container.read(sessionProvider).isSameIdentity(identity)) {
        return;
      }
      _reviewClaim = null;
      final permissions = ref.read(currentPermissionsProvider);
      if (ref.read(isSuperAdminProvider) ||
          permissions.contains(Perm.financeOrderApprovalApprove) ||
          permissions.contains(Perm.financeOrderApprovalReject)) {
        final claim = financeReviewClaim(container)..addListener(_claimChanged);
        _reviewClaim = claim;
        await claim.claimAll('PROCUREMENT_FINANCE_APPROVE', [widget.caseId]);
        if (!mounted || generation != _loadGeneration || !claim.isCurrent) {
          await claim.releaseAll();
          return;
        }
      }
      final review = await ref
          .read(financeProcurementWorkflowRepositoryProvider)
          .review(widget.caseId);
      if (!mounted ||
          generation != _loadGeneration ||
          !container.read(sessionProvider).isSameIdentity(identity)) {
        return;
      }
      setState(() {
        _review = review;
        _loading = false;
        // 汇率编辑框每次加载重置为 case 默认值（已批 = 财务落定值，未批 = 快照兜底）。
        _rateController.text = _defaultRateText(review);
      });
      if (!review.isPending) await _reviewClaim?.releaseAll();
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

  String get widgetSafeBillNo => _review?.billNo ?? '';

  // —— 汇率（case 级记账汇率）—————————————————————————————

  /// case 汇率默认值：已批 = 财务通过时落定的 financeExchangeRate；未批 = 提交
  /// 时订单表头快照 exchangeRate（V438 冻结口径），都没有时兜底 1。
  String _defaultRateText(FinanceProcurementApprovalReview r) =>
      financeExactTrimmed(r.financeExchangeRate) ??
      financeExactTrimmed(r.exchangeRate) ??
      '1';

  /// 编辑框当前是否为合法的 >0 十进制汇率（科学计数法等 double 能解析、
  /// 十进制精确乘算不认的写法一并判非法，避免折合列悄悄回落默认值）。
  bool _rateInputValid() {
    final exact = financeExactTrimmed(_rateController.text.trim());
    if (exact == null || financeExactDecimal(exact) == null) return false;
    return (double.tryParse(exact) ?? 0) > 0;
  }

  String? _rateInputError() => _rateController.text.trim().isEmpty
      ? '请填写大于 0 的汇率'
      : _rateInputValid()
      ? null
      : '汇率必须是大于 0 的数字';

  /// 当前生效汇率（十进制原文）：未批 case 优先取编辑框合法输入，输入中的
  /// 空值/非法值暂按默认值显示；已批/已驳回只读取财务落定值。
  String _effectiveRateText(FinanceProcurementApprovalReview r) {
    if (r.isPending && _rateInputValid()) {
      return financeExactTrimmed(_rateController.text.trim())!;
    }
    return _defaultRateText(r);
  }

  /// 折合人民币 = 原币金额 × 当前汇率（十进制精确乘积，不经过 double）；
  /// 任一侧缺失/非法时返回 null，由调用方回落提交快照的本币金额。
  String? _convertedLocalText(String? amountOriginal, String rateText) =>
      financeExactMultiplyTexts([amountOriginal, rateText]);

  /// 行「折合人民币」：原币金额 × 当前汇率；原币缺失（历史快照）回落快照本币。
  String _lineAmountLocal(FinanceProcurementReviewLine line, String rateText) =>
      financeMoneyText(
        _convertedLocalText(line.amountOriginal, rateText) ?? line.amountLocal,
      );

  /// 合计「折合人民币」：服务端权威原币总额 × 当前汇率；缺原币回落快照本币。
  String _totalAmountLocal(FinanceProcurementApprovalReview r) =>
      financeMoneyText(
        _convertedLocalText(r.totalOriginal, _effectiveRateText(r)) ??
            r.totalLocal,
      );

  /// 通过提交用汇率数值：前置校验后理论必为 >0；异常兜底 null（不进请求体）。
  double? _effectiveRateDouble(FinanceProcurementApprovalReview r) {
    final parsed = double.tryParse(_effectiveRateText(r));
    return (parsed != null && parsed > 0) ? parsed : null;
  }

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
    final claim = _reviewClaim;
    final generation = _loadGeneration;
    if (review.isPending && !_rateInputValid()) {
      context.appWarning(_rateInputError() ?? '汇率必须大于 0');
      return;
    }
    if (claim == null || !claim.isReady) {
      context.appWarning('审核认领还没有生效，请重新认领');
      return;
    }
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
          FinanceReviewClaimButton(
            key: const Key('finance-order-review-approve-submit'),
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
          !identical(review, _review)) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '审核认领或内容已变化，请重新核对');
        }
        return;
      }
      await ref
          .read(financeProcurementWorkflowRepositoryProvider)
          .approveOrdersBatch([
            decision.withClaimId(
              claim.claimIdFor('PROCUREMENT_FINANCE_APPROVE', widget.caseId)!,
            ),
          ], remark: remark, exchangeRate: _effectiveRateDouble(review));
      if (!mounted) return;
      context.appSuccess('已通过 $widgetSafeBillNo，仓库预计到货任务已生成');
      refreshBadges(ref);
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
    final claim = _reviewClaim;
    final generation = _loadGeneration;
    if (claim == null || !claim.isReady) {
      context.appWarning('审核认领还没有生效，请重新认领');
      return;
    }
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
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      hintText: '驳回原因(必填，如：单价待复核 / 供应商资料待更新)',
                      border: const OutlineInputBorder(),
                      error: utenFieldError(errorText),
                    ),
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
              key: const Key('finance-order-review-reject-submit'),
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
          !identical(review, _review)) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '审核认领或内容已变化，请重新核对');
        }
        return;
      }
      await ref
          .read(financeProcurementWorkflowRepositoryProvider)
          .rejectOrdersBatch([
            decision.withClaimId(
              claim.claimIdFor('PROCUREMENT_FINANCE_APPROVE', widget.caseId)!,
            ),
          ], reason);
      if (!mounted) return;
      context.appSuccess('已驳回 $widgetSafeBillNo，制单人将收到修正通知');
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
      // 只有真实换身份才清空（换号/登出/模拟切换/业务重置）；token 静默刷新、
      // 权限滑动更新保持页面与认领（服务端在决策时点重校验权限）。
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
        child: Stack(
          children: [
            !canView
                ? Center(
                    child: Text(
                      '无权查看订货审批任务',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  )
                : _loading
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
                : review == null
                ? const SizedBox.shrink()
                // 2026-10-10 滚动结构对齐销售财审页：折叠头（卡片随页滚走）+
                // body 明细表内滚——整页 ListView + embedded 吸顶表头的旧结构
                // 会让表头吸到屏幕顶，弃。
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
                            if (review.isPending &&
                                review.allowedActions.isNotEmpty &&
                                _reviewClaim?.isReady != true) ...[
                              FinanceReviewClaimNotice(
                                claim: _reviewClaim,
                                onRetry: _busy ? null : _load,
                              ),
                              const SizedBox(height: UtenSpacing.s12),
                            ],
                            _statusStrip(theme, review),
                            const SizedBox(height: UtenSpacing.s12),
                            _supplierFinanceCard(theme, review),
                            const SizedBox(height: UtenSpacing.s12),
                            _orderCard(theme, review),
                            if (procurementHeaderUnknownLabels(
                              review.previousHeaderSnapshot,
                              review.headerSnapshot,
                            ).isNotEmpty)
                              Text(
                                '历史未留存${procurementHeaderUnknownLabels(review.previousHeaderSnapshot, review.headerSnapshot).join('、')}，无法确认这些字段是否修改。',
                              ),
                            if (procurementHeaderChanges(
                              review.previousHeaderSnapshot,
                              review.headerSnapshot,
                            ).isNotEmpty) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              UtenRevisionFields(
                                changes: [
                                  for (final change
                                      in procurementHeaderChanges(
                                        review.previousHeaderSnapshot,
                                        review.headerSnapshot,
                                      ))
                                    UtenRevisionField(
                                      label: change.label,
                                      before: change.before,
                                      after: change.after,
                                    ),
                                ],
                              ),
                            ],
                            // 财务审核只读查看采购/委外合同原件；后端按「待审可见」口径终审，
                            // 审核页不提供上传/删除（原件不能在审批时被悄悄替换）。
                            if (review.orderId.isNotEmpty &&
                                review.orderType !=
                                    FinanceProcurementOrderType.unknown) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              BusinessAttachmentSection(
                                key: const ValueKey(
                                  'finance-order-review-attachments',
                                ),
                                ownerType:
                                    review.orderType ==
                                        FinanceProcurementOrderType.purchase
                                    ? 'PURCHASE_ORDER'
                                    : 'SUBCONTRACT_ORDER',
                                ownerId: review.orderId,
                                canView: true,
                                canManage: false,
                                title: '合同与确认文件（只读）',
                              ),
                            ],
                            const SizedBox(height: UtenSpacing.s12),
                            _historyCard(theme, review),
                          ],
                        ),
                      ),
                      body: Padding(
                        // 底部留出右下悬浮操作组的高度，合计条不被按钮盖住。
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenFloatingActionGroup.controlHeight +
                              UtenSpacing.s32,
                        ),
                        child: _itemsCard(theme, review),
                      ),
                    ),
                  ),
            // 处理中屏幕中央加载动画（对齐财审专页口径：按钮 isLoading 同步转圈，
            // 不再用固定底栏占位）。
            if (_busy)
              const Positioned.fill(child: UtenBusyOverlay(title: '正在处理，请稍候')),
          ],
        ),
      ),
      // 2026-09-14 UI 统一口径：吸底双决策改右下悬浮组，大小/高度/禁用态全站统一。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: !showActions
          ? null
          : UtenFloatingActionGroup(
              children: [
                UtenButton(
                  key: const Key('finance-order-review-back'),
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.large,
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
                    size: UtenButtonSize.large,
                    icon: Icons.undo_rounded,
                    onPressed: _reviewClaim?.isReady == true && !_busy
                        ? _reject
                        : null,
                    onDisabledTap: _reviewClaim?.isReady == true
                        ? null
                        : () => context.appWarning('请先完成审核认领，再驳回'),
                    child: const Text('驳回'),
                  ),
                if (review.allowedActions.contains('APPROVE'))
                  UtenButton(
                    key: const Key('finance-order-review-approve'),
                    type: UtenButtonType.success,
                    size: UtenButtonSize.large,
                    icon: Icons.check_circle_outline_rounded,
                    isLoading: _busy,
                    onPressed: _reviewClaim?.isReady == true && !_busy
                        ? _approve
                        : null,
                    onDisabledTap: _reviewClaim?.isReady == true
                        ? null
                        : () => context.appWarning('请先完成审核认领，再通过'),
                    child: const Text('通过'),
                  ),
              ],
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
    final changed = r.previousItems.isNotEmpty;
    final revisionTitle = r.orderType == FinanceProcurementOrderType.subcontract
        ? '委外订单修改'
        : '采购订单修改';
    final statusText = pending
        ? (changed ? '修改后待复核' : '待财务审核')
        : rejected
        ? '已退回 · 待修改重提'
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
                if (changed) ...[
                  Text(
                    revisionTitle,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                ],
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

  /// 供应商财务快照卡(ADR-128)：本单金额与供应商在本单币种下的应付 / 可抵预付与贷项 /
  /// 还差多少放在一起比(财务共用 FinancePartySnapshotCard)；其它币种另列、不换算。
  /// 2026-10-10 订货审批口径：标题（供应商）红色加粗；「折合人民币」随汇率编辑联动。
  Widget _supplierFinanceCard(ThemeData theme, FinanceProcurementApprovalReview r) {
    final convertedTotal =
        _convertedLocalText(r.totalOriginal, _effectiveRateText(r)) ??
        r.totalLocal;
    return FinancePartySnapshotCard(
      title:
          '供应商财务快照 · ${r.supplierName ?? '—'}'
          '${r.supplierCode != null ? '(${r.supplierCode})' : ''}',
      titleStyle: TextStyle(
        color: theme.colorScheme.error,
        fontWeight: FontWeight.w800,
      ),
      balance: r.supplierBalance,
      side: PartyBalanceSide.supplier,
      leading: [
        FinanceSnapshotMetric(
          '本单金额',
          financeMoneyWithUnitSuffix(
            r.totalOriginal,
            currencyName: r.currencyName,
          ),
          emphasis: true,
          danger: true,
        ),
      ],
      trailing: [
        FinanceSnapshotMetric(
          '折合人民币',
          r.supplierBalance?.baseMoneyText(convertedTotal) ??
              financeMoneyText(convertedTotal),
        ),
        FinanceSnapshotMetric('税率', _trimNum(r.taxRate)),
      ],
    );
  }

  /// 订单信息卡：币种、供应商加粗红色（2026-10-10 订货审批口径：供应商是本页
  /// 核对主体）；汇率跟明细表上方编辑器走（case 级记账口径），不在此重复。
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
            kv('供应商', r.supplierName, highlight: true),
            kv('仓库', r.warehouseName),
            kv('币种', r.currencyLabel, highlight: true),
            kv('结算方式', r.settlementMethodName),
            kv('订货人', r.purchaserName),
            kv('制单员', r.makerName),
            kv('提交人', r.submittedByName),
            kv('提交时间', utenFmtIsoTime(r.submittedAt)),
            kv('预计到货日', r.deliverDate),
            kv(
              '来源申请',
              r.items.any((line) => !line.displaySnapshotComplete)
                  ? '历史未留存'
                  : r.sourceApplicationCount > 0
                  ? '${r.sourceApplicationCount} 张'
                  : '无申请来源',
            ),
            kv(
              '备注',
              r.headerSnapshot.containsKey('remark') ? r.remark : '历史未留存',
            ),
          ],
        ),
      ),
    );
  }

  /// 订货明细卡（联动容器 body）：修订对比表随折叠头联动内滚（primary 拾取
  /// 注入的 PrimaryScrollController）；汇率在表内「汇率」列单元格编辑、合计条
  /// 钉在表下——改汇率立即可见折合人民币列与合计变化。
  Widget _itemsCard(ThemeData theme, FinanceProcurementApprovalReview r) {
    final revisions = procurementRevisionRows(r.previousItems, r.items);
    final comparing = r.previousItems.isNotEmpty;
    final rateText = _effectiveRateText(r);
    final hasUnknown = [
      ...r.previousItems,
      ...r.items,
    ].any((line) => !line.displaySnapshotComplete);
    String? extra(
      FinanceProcurementReviewLine line,
      String? value, {
      bool numeric = false,
    }) => !line.displaySnapshotComplete
        ? '历史未留存'
        : numeric
        ? _trimNum(value)
        : value;
    final changed = revisions
        .where((row) => !row.unchanged && !row.needsReview)
        .toList();
    final unknownCount = revisions.where((row) => row.needsReview).length;
    final added = changed.where((row) => row.before == null).length;
    final removed = changed.where((row) => row.after == null).length;
    final modified = changed.length - added - removed;
    final rows = <UtenRevisionRow<FinanceProcurementReviewLine>>[
      if (!comparing)
        for (final item in r.items)
          UtenRevisionRow(value: item, kind: UtenRevisionKind.unchanged)
      else
        for (final revision in revisions)
          if (revision.unchanged)
            UtenRevisionRow(
              value: revision.after!,
              kind: UtenRevisionKind.unchanged,
              label: revision.after!.displaySnapshotComplete ? null : '已存内容相同',
            )
          else ...[
            if (revision.before != null)
              UtenRevisionRow(
                value: revision.before!,
                kind: UtenRevisionKind.removed,
                label: revision.after == null
                    ? '已删除'
                    : !revision.before!.displaySnapshotComplete
                    ? '原记录·缺项'
                    : '原内容',
              ),
            if (revision.after != null)
              UtenRevisionRow(
                value: revision.after!,
                kind: UtenRevisionKind.added,
                label: revision.before == null
                    ? '新增'
                    : revision.needsReview
                    ? '本次·待核对'
                    : '修改后',
                changedKeys: revision.before == null
                    ? const {}
                    : _visibleChangedKeys(
                        procurementChangedFields(
                          revision.before!,
                          revision.after!,
                        ),
                      ),
              ),
          ],
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 2026-09-25 用户口径：纯计数标题「订货明细(N)」退役；修订对比统计行是
            // 表体看不出的信息，保留。
            if (comparing) ...[
              Text(
                '明细对比 · 修改 $modified 行 · 删除 $removed 行 · 新增 $added 行${unknownCount > 0 ? ' · 待核对 $unknownCount 行' : ''}',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (hasUnknown)
                Text(
                  '历史记录部分字段未留存，未知不代表未修改；历史名称按现有档案显示。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              const SizedBox(height: UtenSpacing.s8),
            ],
            Expanded(
              child: UtenRevisionTable<FinanceProcurementReviewLine>(
                // 2026-10-10 独立 tableKey：不再复用编辑页
                // purchase/subcontract.order.items——保存布局按 key 合并会把
                // 本页新键（_revision/汇率/折合人民币…）全部甩到列尾。
                tableKey: switch (r.orderType) {
                  FinanceProcurementOrderType.purchase =>
                    'finance.procurement.review.purchase.items',
                  FinanceProcurementOrderType.subcontract =>
                    'finance.procurement.review.subcontract.items',
                  FinanceProcurementOrderType.unknown =>
                    'finance.procurement.unknown.items',
                },
                key: const Key('procurement-approval-revision-table'),
                // 数量/单价/总金额/折合人民币/超收(损耗)% 是财务逐行核对值，
                // 全程红色加粗（UtenRevisionTable 口径）。
                highlightColumnKeys: switch (r.orderType) {
                  FinanceProcurementOrderType.purchase => const {
                    'qty',
                    'price',
                    'amountOriginal',
                    'amountLocal',
                    'allowedOverReceiptPct',
                  },
                  FinanceProcurementOrderType.subcontract => const {
                    'qty',
                    'price',
                    'amountOriginal',
                    'amountLocal',
                    'allowedLossPct',
                  },
                  FinanceProcurementOrderType.unknown => const {
                    'qty',
                    'price',
                    'amountOriginal',
                    'amountLocal',
                  },
                },
                primary: true,
                // 行勾选（防看岔行）：单选互斥——点其他行自动换选、再点取消，
                // 选中态由行高亮表达，不画勾选框列也不驻「已选」胶囊；修订对比
                // 的「修改前」快照行不可选，同一业务行的「修改后」行选中即代表
                // 该行。
                selectable: true,
                showSelectionColumn: false,
                singleSelection: true,
                showSelectionSummary: false,
                idOf: (line) => line.orderItemId,
                selectedIds: _selectedLineIds,
                onSelectedIdsChanged: (next) => setState(() {
                  _selectedLineIds
                    ..clear()
                    ..addAll(next);
                }),
                // 汇率列 = 表格内可编辑单元格（2026-10-10 用户口径：汇率写在表格
                // 对应行的单元格里，不再表下另起一行编辑器）。
                cellBuilders: {
                  'exchangeRate': (cellContext, row) {
                    if (!r.isPending || row.kind == UtenRevisionKind.removed) {
                      return Text(
                        _trimNum(rateText) ?? '1',
                        key: const Key('finance-order-review-rate-readonly'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      );
                    }
                    return TextField(
                      key: const Key('finance-order-review-rate-field'),
                      controller: _rateController,
                      onChanged: (_) => setState(() {}),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: UtenInputDecoration(
                        InputDecoration(
                          isDense: true,
                          hintText: '大于 0',
                          error: utenFieldError(_rateInputError()),
                        ),
                      ),
                    );
                  },
                },
                columns: [
                  MasterColumnDef(
                    key: 'sourceDocNo',
                    label: '来源单号',
                    width: 170,
                    value: (it) => extra(it, it.sourceDocNo),
                  ),
                  MasterColumnDef(
                    key: 'sourceApplicationNos',
                    label: '申请来源 / 分配数量',
                    width: 280,
                    value: (it) => extra(it, it.sourceApplicationNos),
                  ),
                  MasterColumnDef(
                    key: 'lineNo',
                    label: '行号',
                    width: 64,
                    type: 'number',
                    value: (it) => it.lineNo.toString(),
                  ),
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
                  // 2026-10-10「数量+单位」全站口径：单位内联在数字后（12 PCS），
                  // 独立单位列退役（formatQtyWithUnit 是唯一拼装点）。
                  MasterColumnDef(
                    key: 'qty',
                    label: '数量',
                    width: 110,
                    type: 'number',
                    value: (it) =>
                        formatQtyWithUnit(double.tryParse(it.qty ?? ''), it.unitName),
                  ),
                  // 采购=允许超收%（ADR-144，审批哈希快照自带，空=不允许超收）；
                  // 委外=允许损耗%。数值后直接带 %（2026-10-10 财务口径）。
                  if (r.orderType == FinanceProcurementOrderType.purchase)
                    MasterColumnDef(
                      key: 'allowedOverReceiptPct',
                      label: '允许超收',
                      width: 120,
                      info: '供应商累计送货在 数量×(1+允许超收%) 以内照常入库、立应付，超出部分才转财务审核组审批；批准后不能再改。',
                      value: (it) {
                        final v = _trimNum(it.allowedOverReceiptPct);
                        return v == null ? '不允许' : '$v%';
                      },
                    ),
                  if (r.orderType == FinanceProcurementOrderType.subcontract)
                    MasterColumnDef(
                      key: 'allowedLossPct',
                      label: '允许损耗',
                      width: 120,
                      value: (it) {
                        if (!it.displaySnapshotComplete) return '历史未留存';
                        final v = _trimNum(it.allowedLossPct);
                        return v == null ? null : '$v%';
                      },
                    ),
                  // 金额列自动带币种后缀（2026-10-10 口径「单价 0.5 元 / 总金额
                  // 1500 美金」），币种不再写进列头。
                  MasterColumnDef(
                    key: 'price',
                    label: '单价',
                    width:
                        [
                          ...r.previousItems,
                          ...r.items,
                        ].any((it) => it.totalAmountInput != null)
                        ? 190
                        : 130,
                    type: 'money',
                    info: '标注“参考”的单价由填写的总金额反算；除不尽时仅显示参考值，结算按单据记录的总金额。',
                    value: (it) => it.totalAmountInput == null
                        ? financeMoneyWithUnitSuffix(
                            it.price,
                            currencyName: r.currencyName,
                          )
                        : '${financeMoneyWithUnitSuffix(it.price, currencyName: r.currencyName)}（参考）',
                  ),
                  MasterColumnDef(
                    key: 'amountOriginal',
                    label: comparing ? '原币总金额' : '总金额',
                    width: 150,
                    type: 'money',
                    value: (it) => financeMoneyWithUnitSuffix(
                      it.amountOriginal,
                      currencyName: r.currencyName,
                    ),
                  ),
                  // 汇率 = case 级记账汇率：未批 case 在本列单元格填写（全列同步），
                  // 实时重算折合人民币列/合计/快照卡；已批只读财务落定值。行单位
                  // 换算率（1箱=24只）与货币无关，2026-10-10 起退役本表。
                  MasterColumnDef(
                    key: 'exchangeRate',
                    label: '汇率',
                    width: 140,
                    type: 'number',
                    info: '未审批时在本列单元格填写记账汇率（同单全行同值，任一格输入全列同步）；折合人民币 = 总金额 × 汇率，实时重算。通过时随审批写入本单，驳回不落汇率。',
                    value: (_) => _trimNum(rateText),
                  ),
                  // 折合人民币 = 总金额 × 当前汇率（实时联动；原币缺失回落快照本币）。
                  MasterColumnDef(
                    key: 'amountLocal',
                    label: '折合人民币',
                    width: 150,
                    type: 'money',
                    value: (it) => financeLocalMoneyWithUnitSuffix(
                      _lineAmountLocal(it, rateText),
                    ),
                  ),
                  MasterColumnDef(
                    key: 'deliverDate',
                    label: '交货日',
                    width: 110,
                    type: 'date',
                    value: (it) => it.deliverDate,
                  ),
                  if (r.orderType == FinanceProcurementOrderType.purchase &&
                      [...r.previousItems, ...r.items].any(
                        (line) =>
                            line.giftQty != null && _trimNum(line.giftQty) != '0',
                      ))
                    MasterColumnDef(
                      key: 'giftQty',
                      label: '赠品数量',
                      width: 110,
                      value: (it) => extra(it, it.giftQty, numeric: true),
                    ),
                  MasterColumnDef(
                    key: 'remark',
                    label: '行备注',
                    width: 220,
                    value: (it) => extra(it, it.remark),
                  ),
                  ...businessReadOnlyColumns<FinanceProcurementReviewLine>([
                    ...r.previousItems,
                    ...r.items,
                  ], columnsOf: (line) => line.extraColumns),
                ],
                rows: rows,
              ),
            ),
            if (r.items.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s8),
              UtenTotalsSummaryBar(
                density: true,
                rowCount: r.items.length,
                entries: [
                  // 合计数量按单位分组（不同单位绝不相加）：多单位显示「12 个 · 3 箱」。
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
                    '合计金额',
                    financeMoneyWithUnitSuffix(
                      r.totalOriginal,
                      currencyName: r.currencyName,
                    ),
                    danger: true,
                  ),
                  // 折合人民币随汇率编辑实时重算（totalOriginal × 当前汇率）。
                  UtenTotalEntry(
                    '折合人民币',
                    financeLocalMoneyWithUnitSuffix(_totalAmountLocal(r)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 变更红格的列键映射：单位列已并入「数量」（2026-10-10 数量+单位内联口径），
  /// 单独的单位变化落到数量列红格；换算率列退役后键仍留在变更集（行配对判定
  /// 依赖完整字段比较），只是不再对应可见列。
  Set<String> _visibleChangedKeys(Set<String> fields) => {
    ...fields,
    if (fields.contains('unitName')) 'qty',
  };

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

  /// 数量/单价/汇率按原文去掉末尾多余的 0, 不四舍五入到 2 位。
  String? _trimNum(String? raw) => financeExactTrimmed(raw);
}
