// 销售订货单财务审核详情页（V300 专用审核视图，与销售端订单详情分离）。
//
// 设计目标（对齐大公司审批中心：SAP/Oracle 审批详情 = 单据信息 + 风险快照 + 双决策）：
//  - 客户财务快照卡：应收余额 / 信用额度 / 铺底额，超信用红色告警——财务确认前必看；
//  - 订单信息卡：币种加粗红色、发运策略、结帐方式等商业事实；资金状态读取独立财务汇总；
//  - 产品明细保持全局统一表格（MasterDataTableView 嵌入模式）；
//  - 底栏双决策：驳回（必填原因，通知归属销售修正）/ 确认通过（选填备注，放行计划部）。
// 本页不出现销售端运营操作（改量/排产进度/取消订单/红冲），职责分离。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart';
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
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/repositories/task_claim_repository.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/sales_order_finance_confirmation.dart';
import '../providers/sales_order_finance_confirmation_count_provider.dart';
import '../repositories/sales_order_finance_confirmation_repository.dart';
import '../../../shared/widgets/sales_order_money_summary_card.dart';

class FinanceSalesOrderReviewPage extends ConsumerStatefulWidget {
  const FinanceSalesOrderReviewPage({super.key, required this.id});

  final String id;

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

  // V459 认领会话：进入审核详情即认领 SALES_ORDER_FINANCE_CONFIRM——
  // 其他财务的弹卡/收件台显示「XX 正在审核」。纯 UX/防碰撞层，fail-open。
  TaskClaimSession? _reviewClaim;
  String? _claimedByOtherName;

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
    _reviewClaim?.releaseAll().ignore();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final review = await ref
          .read(salesOrderFinanceConfirmationRepositoryProvider)
          .review(widget.id);
      if (!mounted) return;
      setState(() {
        _review = review;
        _loading = false;
      });
      // 待确认单据才认领（已确认/已驳回无认领意义）。
      if (!review.financeConfirmed && !review.financeRejected) {
        _reviewClaim = TaskClaimSession(ref.read(taskClaimRepositoryProvider));
        await _reviewClaim!.claimAll('SALES_ORDER_FINANCE_CONFIRM', [
          widget.id,
        ]);
        if (mounted) {
          setState(() {
            _claimedByOtherName = _reviewClaim!.blocked
                ? _reviewClaim!.blockedByName
                : null;
          });
        }
      }
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

  Future<void> _confirm() async {
    if (!_canConfirm) {
      context.appWarning('您没有销售订单财务确认权限');
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
                decoration: const InputDecoration(
                  hintText: '确认备注(选填，≤500 字)',
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
            key: const Key('finance-review-confirm-submit'),
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
          .read(salesOrderFinanceConfirmationRepositoryProvider)
          .confirm(widget.id, remark: remark);
      if (!mounted) return;
      context.appSuccess('已确认通过，计划部已可接手排产');
      ref.invalidate(salesOrderFinanceConfirmationCountProvider);
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

  /// 决策（确认/驳回）完成后的落点：
  /// - 从确认列表 push 进来 → 带 true 返回值 pop，列表刷新；
  /// - 从 V459 审核弹窗「去审核」router.go 直达 / 深链 → 路由栈空，
  ///   直接 pop 会抛 GoError 并被外层 catch 误报「确认失败」（v2026.09.03-1
  ///   实际已确认成功）——改跳回确认列表页。
  void _closeAfterDecision() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(true);
    } else {
      context.go('/finance/sales-order-confirmations');
    }
  }

  Future<void> _reject() async {
    if (!_canConfirm) {
      context.appWarning('您没有销售订单财务确认权限');
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
                  decoration: InputDecoration(
                    hintText: '驳回原因(必填，如：客户欠款超限 / 价格待复核)',
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
              key: const Key('finance-review-reject-submit'),
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
          .read(salesOrderFinanceConfirmationRepositoryProvider)
          .reject(widget.id, reason: reason);
      if (!mounted) return;
      context.appSuccess('已驳回，归属销售将收到修正通知');
      ref.invalidate(salesOrderFinanceConfirmationCountProvider);
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
    final permissions = ref.watch(currentPermissionsProvider);
    final canViewMoneySummary =
        permissions.contains(Perm.financeViewAll) &&
        permissions.contains(Perm.customerPrepaymentView);
    return Scaffold(
      appBar: UtenAppBar(
        title: '销售订单财务审核',
        leading: UtenBackButton(
          onPressed: () => backTo(
            context,
            defaultPath: '/finance/sales-order-confirmations',
          ),
        ),
      ),
      body: SafeArea(
        child: _loading
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
            : _review == null
            ? const SizedBox.shrink()
            : UtenContentContainer.narrow(
                child: ListView(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  children: [
                    // V459 他人认领软提示（单人维护原则：提示不硬拒）。
                    if (_claimedByOtherName != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.tertiaryContainer.withValues(
                            alpha: 0.5,
                          ),
                          borderRadius: UtenRadius.lgAll,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.person_pin_circle_outlined,
                              color: theme.colorScheme.onTertiaryContainer,
                            ),
                            const SizedBox(width: UtenSpacing.s12),
                            Expanded(
                              child: Text(
                                '$_claimedByOtherName 正在审核此订单；请先与其沟通，避免重复处理。',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onTertiaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
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
                      SalesOrderMoneySummaryCard(salesOrderId: widget.id),
                    ],
                    const SizedBox(height: UtenSpacing.s12),
                    _itemsCard(theme, _review!),
                    if (_review!.financeRejected) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      _rejectRecordCard(theme, _review!),
                    ],
                  ],
                ),
              ),
      ),
      bottomNavigationBar:
          _review == null ||
              _review!.financeConfirmed ||
              _review!.financeRejected ||
              !_canConfirm
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
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          UtenButton(
                            key: const Key('finance-review-reject'),
                            type: UtenButtonType.danger,
                            icon: Icons.undo_rounded,
                            onPressed: _reject,
                            child: const Text('驳回'),
                          ),
                          const SizedBox(width: UtenSpacing.s12),
                          UtenButton(
                            key: const Key('finance-review-confirm'),
                            icon: Icons.fact_check_outlined,
                            onPressed: _confirm,
                            child: const Text('确认通过'),
                          ),
                        ],
                      ),
              ),
            ),
    );
  }

  /// 顶部状态条：单据号 + 已确认/已驳回/待确认状态。
  Widget _statusStrip(ThemeData theme, SalesOrderFinanceReview r) {
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
        ? '已被财务驳回，等待销售受控修订并重新审核'
        : '待财务确认 · 确认后计划部才可见并排产';
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
                  r.billNo,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
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
                _metric(theme, '本单金额', _money(r.totalOriginal)),
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
        child: UtenFormGrid(
          children: [
            kv('单据日期', r.billDate),
            kv('业务员', r.sellerName),
            kv('制单员', r.makerName),
            kv('制单时间', utenFmtIsoTime(r.createdAt)),
            kv('交货日', r.deliverDate),
            kv('币种', _currencyLabel(r), highlight: true),
            kv('发运策略', r.shipmentPolicyName ?? r.shipmentPolicy),
            kv('结帐方式', r.settlementMethodName),
            kv('合同号', r.contractNo),
            kv('备注', r.remark),
          ],
        ),
      ),
    );
  }

  /// 产品明细：保持全局统一表格（MasterDataTableView 嵌入模式），不另造样式。
  Widget _itemsCard(ThemeData theme, SalesOrderFinanceReview r) {
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
        MasterDataTableView<SalesOrderFinanceReviewLine>(
          embedded: true,
          columns: [
            MasterColumnDef(
              key: 'goods',
              label: '货品',
              width: 240,
              value: (it) {
                final base = [
                  if (it.goodsCode != null) it.goodsCode!,
                  if (it.goodsName != null) it.goodsName!,
                ].join(' · ');
                final model = it.clientModel;
                final suffix = [
                  if (it.colorName != null) it.colorName!,
                  if (it.unitName != null) it.unitName!,
                ].join(' · ');
                final head = suffix.isEmpty ? base : '$base($suffix)';
                return (model != null && model.isNotEmpty)
                    ? '$head · 客型 $model'
                    : head;
              },
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
        ),
      ],
    );
  }

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
  String _currencyLabel(SalesOrderFinanceReview r) =>
      financeCurrencyDisplayLabel(name: r.currencyName, code: r.currencyCode) ??
      '订单币种';

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
