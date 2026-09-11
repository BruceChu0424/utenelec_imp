// 钱流单据详情页（全页路由，按 docType 参数化）：主表头卡 + 只读明细子表 + 状态门控操作。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。
// 审核后端联动：核销 AR/AP（receipt/payment）/ 账户余额变动 / 写流水 / 登记对账。
// 名称解析：客户/供应商/账户/币种 用 FinanceNameService。
//
// 2026-09-11 折叠头+表内滚改版（对齐采购/货品资料页）：有明细表的单据把整页 ListView
// 换成 UtenCollapsingHeaderScrollView——上滑先折叠头部（提示条/表头卡/预收汇总/附件），
// 「明细 (N)」标题顶到页面顶部后再滚明细表内部；客户预收（无明细表）仍走整页滚动。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/document_scope_write_notice.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_decimal.dart';
import '../models/finance_doc.dart';
import '../providers/finance_name_provider.dart';
import '../repositories/finance_repository.dart';
import '../widgets/finance_status_badge.dart';
import '../../../shared/widgets/sales_order_money_summary_card.dart';

class FinanceDocDetailPage extends ConsumerStatefulWidget {
  const FinanceDocDetailPage({
    super.key,
    required this.docType,
    required this.id,
  });
  final FinanceDocType docType;
  final String id;

  @override
  ConsumerState<FinanceDocDetailPage> createState() =>
      _FinanceDocDetailPageState();
}

class _FinanceDocDetailPageState extends ConsumerState<FinanceDocDetailPage> {
  FinanceDocConfig get _cfg => FinanceDocConfig.by(widget.docType);
  FinanceDocDetail? _detail;
  bool _loading = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool _hasPermission(String? code) =>
      code != null && ref.read(currentPermissionsProvider).contains(code);

  bool get _ordinaryWritable => documentOwnerCanWrite(
    ref.read(documentScopeCapabilityProvider(DocumentDataScope.finance)),
    _detail?.makerId,
  );

  bool get _canEdit => _ordinaryWritable && _hasPermission(_cfg.editPerm);
  bool get _canDelete => _ordinaryWritable && _hasPermission(_cfg.deletePerm);
  bool get _canApprove => _hasPermission(_cfg.approvePerm);
  bool get _canReverse => _hasPermission(_cfg.reversePerm);
  bool get _canConfirmGeneralLedger =>
      _hasPermission(Perm.financeExpenseGlConfirm);

  String get _attachmentOwnerType => switch (widget.docType) {
    FinanceDocType.receipt => 'FINANCE_RECEIPT',
    FinanceDocType.payment => 'FINANCE_PAYMENT',
    FinanceDocType.expense => 'FINANCE_EXPENSE',
    FinanceDocType.otherIncome => 'FINANCE_OTHER_INCOME',
    FinanceDocType.bankTransfer => 'FINANCE_BANK_TRANSFER',
  };

  Future<void> _load() async {
    ref.invalidate(documentScopeCapabilityProvider(DocumentDataScope.finance));
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref
          .read(financeNameServiceProvider)
          .ensureLoaded(refreshAccounts: true);
      // 费用/收入单及销售收款的其它费用项目：预载类别名称。
      if (_cfg.isAllocate || _cfg.type == FinanceDocType.receipt) {
        await ref
            .read(financeNameServiceProvider)
            .loadStyleCategory(
              _cfg.type == FinanceDocType.otherIncome ? 'INCOME' : 'EXPENSE',
            );
      }
      final d = await ref
          .read(financeRepositoryProvider(widget.docType))
          .detail(widget.id);
      if (!mounted) return;
      setState(() {
        _detail = d;
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
        _error = '加载详情失败';
        _loading = false;
      });
    }
  }

  Future<void> _approve() async => _doAction(
    _approvalMessage,
    (repo) => repo.approve(widget.id),
    '已审核',
    reviewerResponsibility: true,
  );

  String get _approvalMessage {
    final d = _detail;
    if (_cfg.type != FinanceDocType.payment ||
        d == null ||
        (d.settlementAuthorityVersion ?? 0) < 2) {
      return '审核后将核销 AR/AP 并变动账户余额、写流水，确认审核？';
    }
    final names = ref.read(financeNameServiceProvider);
    final book = financeExactSumTexts(
      d.items.map((line) => line.appliedAmountLocalText),
    );
    final fx = financeExactSumTexts(
      d.items.map((line) => line.exchangeDiffText),
    );
    return '货款原币：${names.currency(d.currencyId)} ${d.amountOriginalText ?? '—'}\n'
        '银行总扣款：${names.currency(d.accountCurrencyId)} ${d.accountAmountText ?? '—'}\n'
        '其中银行手续费：${d.bankFeeAccountAmountText ?? '0'}\n'
        '冲减应付账面本币：${book ?? '—'}\n'
        '汇兑差额本币：${fx ?? '—'}\n'
        '审核将核销应付、登记实际账户流水并生成付款凭证，确认审核？';
  }

  Future<void> _reverse() async =>
      _doAction('红冲将反向冲销，确认？', (repo) => repo.reverse(widget.id), '已红冲');

  /// C6 财务确认（仅费用单）：已过账 → 财务确认入账。
  Future<void> _glConfirm() async => _doAction(
    '确认该费用单的总账分录入账？',
    (repo) => repo.glConfirm(widget.id),
    '已财务确认',
    reviewerResponsibility: true,
    reviewerActionLabel: '费用单总账确认',
  );

  Future<void> _doAction(
    String confirm,
    Future<void> Function(FinanceRepository) fn,
    String ok, {
    bool reviewerResponsibility = false,
    String reviewerActionLabel = '审核',
  }) async {
    if (_busy) return;
    final c = reviewerResponsibility
        ? await showUtenReviewerConfirmDialog(
            context,
            message: confirm,
            actionLabel: reviewerActionLabel,
          )
        : await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('确认'),
              content: Text(confirm),
              actionsAlignment: MainAxisAlignment.center,
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('确认'),
                ),
              ],
            ),
          );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await fn(ref.read(financeRepositoryProvider(widget.docType)));
      if (!mounted) return;
      context.appSuccess(ok);
      bumpListRefresh(ref, _cfg.refreshKey);
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('操作失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除单据'),
        content: const Text('确定删除该草稿单据吗？'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(financeRepositoryProvider(widget.docType))
          .delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      // 返回键契约（路由设计 §十一）：pop 回来源，栈空回钱流 hub。
      popOrBackTo(context, defaultPath: RouteName.finance);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('删除失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final scopeCapability = ref.watch(
      documentScopeCapabilityProvider(DocumentDataScope.finance),
    );
    final theme = Theme.of(context);
    final names = ref.watch(financeNameServiceProvider);
    final canViewFiles =
        permissions.contains(_cfg.listPerm) &&
        permissions.contains(Perm.financeViewAll) &&
        (_detail?.receiptKind?.trim().toUpperCase() != 'CUSTOMER_PREPAYMENT' ||
            permissions.contains(Perm.customerPrepaymentView));
    return Scaffold(
      appBar: UtenAppBar(
        title: '${_cfg.label}详情',
        // 列表行 push 进（回列表）/ hub 新建保存后 replace 进（栈空→回 hub）；
        // 用 popOrBackTo 兼顾两种入口。
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: RouteName.finance),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer.narrow(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : _error != null
              ? Center(child: Text(_error!))
              : _detail == null
              ? const SizedBox.shrink()
              : _body(theme, names, scopeCapability, canViewFiles),
        ),
      ),
      bottomNavigationBar: _detail == null || _busy ? null : _actions(theme),
    );
  }

  /// 页面正文：有明细表的单据走折叠头联动（上滑先收头部，再滚明细表内部）；
  /// 客户预收无明细表（只有表头卡+预收汇总+凭证），没有可内滚的表格，保持整页滚动。
  Widget _body(
    ThemeData theme,
    FinanceNameService names,
    AsyncValue<DocumentScopeCapability> scopeCapability,
    bool canViewFiles,
  ) {
    final sections = _headerSections(
      theme,
      names,
      scopeCapability,
      canViewFiles,
    );
    if (!_hasItemsTable) {
      return ListView(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        children: sections,
      );
    }
    return UtenCollapsingHeaderScrollView(
      collapsingHeader: Padding(
        padding: const EdgeInsets.fromLTRB(
          UtenSpacing.s12,
          UtenSpacing.s12,
          UtenSpacing.s12,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: sections,
        ),
      ),
      // body：明细标题（钉住）+ 表格占满内滚（primary 拾取联动控制器）。
      body: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: _itemsCard(theme, names),
      ),
    );
  }

  /// 客户预收收款单没有明细行（金额直接落在表头），故不渲染明细表。
  bool get _hasItemsTable =>
      !(_cfg.type == FinanceDocType.receipt &&
          _detail!.receiptKind == 'CUSTOMER_PREPAYMENT');

  /// 折叠头内容（无明细表时即整页 ListView 的 children）：提示条 / 表头卡 /
  /// 预收汇总 / 附件——附件属「备注类小卡」，随头部一起收起。
  List<Widget> _headerSections(
    ThemeData theme,
    FinanceNameService names,
    AsyncValue<DocumentScopeCapability> scopeCapability,
    bool canViewFiles,
  ) {
    return [
      DocumentScopeWriteNotice(
        capability: scopeCapability,
        ownerEmployeeId: _detail!.makerId,
        onRetry: () => ref.invalidate(
          documentScopeCapabilityProvider(DocumentDataScope.finance),
        ),
      ),
      // 表头信息卡文字可框选：外层 UtenContentContainer 已默认包局部
      // SelectionArea（准则 §3.4），无需再单独包。
      _headerCard(theme, names),
      if (_cfg.type == FinanceDocType.receipt &&
          _detail!.receiptKind == 'CUSTOMER_PREPAYMENT' &&
          _detail!.salesOrderId != null) ...[
        const SizedBox(height: UtenSpacing.s12),
        SalesOrderMoneySummaryCard(salesOrderId: _detail!.salesOrderId!),
      ],
      if (canViewFiles) ...[
        const SizedBox(height: UtenSpacing.s12),
        BusinessAttachmentSection(
          ownerType: _attachmentOwnerType,
          ownerId: _detail!.id,
          canView: canViewFiles,
          // 详情=审核页：凭证只读（增删回编辑页）。
          canManage: false,
          readOnlyNote: BusinessAttachmentSection.kReviewReadOnlyAttachmentNote,
          title: '单据和凭证',
          categories: const ['银行回单', '发票', '其他凭证'],
        ),
      ],
    ];
  }

  Widget _headerCard(ThemeData theme, FinanceNameService names) {
    final d = _detail!;
    final isReceipt = _cfg.type == FinanceDocType.receipt;
    final isCustomerPrepayment =
        isReceipt && d.receiptKind == 'CUSTOMER_PREPAYMENT';
    final isVersionedReceipt =
        isReceipt && (d.settlementAuthorityVersion ?? 0) >= 1;
    final isPayment = _cfg.type == FinanceDocType.payment;
    final partyName = _cfg.isClient
        ? names.client(d.clientId)
        : _cfg.isSupplier
        ? names.supplier(d.supplierId)
        : null;
    final accountName = names.account(d.accountId ?? d.outAccountId);
    final cnyReceiptAccount =
        names.accountIsBaseCurrency(d.accountId ?? d.outAccountId) == true;
    final receiptLocalLabel = cnyReceiptAccount ? '本批人民币实际入账' : '本批本位币折算(人民币)';
    final accountCurrencyLabel = names.currency(d.accountCurrencyId) != '—'
        ? names.currency(d.accountCurrencyId)
        : (names.accountCurrency(d.accountId) ?? '账户币种');
    final feeCurrencyLabel = names.currency(d.feeAccountCurrencyId) != '—'
        ? names.currency(d.feeAccountCurrencyId)
        : accountCurrencyLabel;
    final receiptLocal = financeExactSumTexts(
      d.items.map((it) => it.amountLocalText),
    );
    final writeOffLocal = financeExactSumTexts(
      d.items.map((it) => it.writeOffLocalText ?? '0'),
    );
    final appliedLocal = financeExactSumTexts(
      d.items.map((it) => it.appliedAmountLocalText),
    );
    final exchangeDiffLocal = financeExactSumTexts(
      d.items.map((it) => it.exchangeDiffText),
    );
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      _KV('制单员', d.makerName),
      _KV('制单时间', utenFmtIsoTime(d.createdAt)),
      if (isReceipt) _KV('收款业务', financeReceiptKindLabel(d.receiptKind)),
      if (isReceipt)
        _KV(
          '结算口径',
          (d.settlementAuthorityVersion ?? 0) >= 2
              ? '实际银行到账与本批结算分别记录'
              : isVersionedReceipt
              ? 'V1 到账与 AR 核销分层'
              : '历史口径未分层',
        ),
      if (isCustomerPrepayment) _KV('绑定销售订单 UUID', d.salesOrderId),
      if (_cfg.hasParty) _KV(_cfg.partyLabel, partyName),
      _KV(_cfg.accountLabel, accountName),
      if (_cfg.hasCurrency &&
          (!isReceipt || isCustomerPrepayment) &&
          !isVersionedReceipt)
        _KV('币种', names.currency(d.currencyId)),
      if (isReceipt && !isCustomerPrepayment && !isVersionedReceipt)
        _KV('应收币种', names.currency(d.currencyId)),
      if ((!isReceipt || isCustomerPrepayment) &&
          !isVersionedReceipt &&
          d.exchangeRate != null)
        _KV(isCustomerPrepayment ? '当前批次实际到账汇率' : '汇率', d.exchangeRateText),
      if (isCustomerPrepayment &&
          !isVersionedReceipt &&
          d.amountOriginalText != null)
        _KV(
          cnyReceiptAccount ? '本批预收原币金额' : '本批账户原币实际入账',
          financeExactMoneyDisplay(d.amountOriginalText),
        ),
      if (isReceipt &&
          !isCustomerPrepayment &&
          !isVersionedReceipt &&
          d.amountOriginalText != null)
        _KV('本批到账(应收原币)', financeExactMoneyDisplay(d.amountOriginalText)),
      if (isPayment && d.amountOriginalText != null)
        _KV('付款原币金额', financeExactMoneyDisplay(d.amountOriginalText)),
      if (_cfg.hasBankFee && !isVersionedReceipt && d.bankFeeText != null)
        _KV('手续费(人民币)', financeExactMoneyDisplay(d.bankFeeText)),
      if (_cfg.hasOtherFee && !isVersionedReceipt && d.otherFeeText != null)
        _KV('其它费用(人民币)', financeExactMoneyDisplay(d.otherFeeText)),
      if (_cfg.hasOtherFee && d.otherFeeStyleId != null)
        _KV('其它费用项目', names.styleName(d.otherFeeStyleId, 'EXPENSE')),
      if (_cfg.hasInvoiceNo) _KV('发票号', d.invoiceNo),
      if (isVersionedReceipt) ...[
        _KV(
          '结算渠道',
          d.settlementChannel == 'TRADE_AGENT_CONVERSION'
              ? '外贸代理代收结汇'
              : '真实账户直接到账',
        ),
        if (d.settlementAgentSupplierId != null)
          _KV(
            '外贸代理公司',
            d.settlementAgentNameSnapshot ??
                names.supplier(d.settlementAgentSupplierId),
          ),
        _KV('应收/预收原币', names.currency(d.currencyId)),
        _KV(
          (d.settlementAuthorityVersion ?? 0) >= 2 ? '本批汇率报价' : '当前批次实际汇率',
          d.exchangeRateText,
        ),
        _KV(
          '汇率报价方向',
          d.settlementRateQuoteDirection == 'BASE_PER_SETTLEMENT'
              ? '本位币/结算原币（1 原币对应本位币金额）'
              : d.settlementRateQuoteDirection,
        ),
        _KV(
          '汇率来源',
          d.exchangeRateSource == 'TRADE_AGENT_STATEMENT' ? '外贸代理结算单' : '银行回单',
        ),
        _KV('汇率生效时间', utenFmtIsoTime(d.exchangeRateEffectiveAt)),
        _KV('银行入账时间', utenFmtIsoTime(d.bankBookedAt)),
        _KV('银行入账流水号', d.bankReference),
        if (d.agentStatementNo != null) _KV('外贸代理结算单号', d.agentStatementNo),
        _KV('真实收款账户币种', accountCurrencyLabel),
        _KV('账户本位币折算汇率', d.accountExchangeRateText),
        _KV('账户折算汇率来源', switch (d.accountExchangeRateSource) {
          'BASE_CURRENCY_IDENTITY' => '本位币同值',
          'SETTLEMENT_RATE' => '本批结算汇率',
          _ => d.accountExchangeRateSource,
        }),
        _KV('本批客户支付/核销原币', financeExactMoneyDisplay(d.amountOriginalText)),
        _KV(
          (d.settlementAuthorityVersion ?? 0) >= 2
              ? '本批客户已付(人民币)'
              : '本批结算毛额(人民币)',
          financeExactMoneyDisplay(d.settlementGrossLocalText),
        ),
        _KV(
          '真实账户实际入账($accountCurrencyLabel)',
          financeExactMoneyDisplay(d.accountAmountText),
        ),
        _KV('实际入账本位币(人民币)', financeExactMoneyDisplay(d.accountAmountLocalText)),
        _KV(
          '银行手续费($feeCurrencyLabel)',
          financeExactMoneyDisplay(d.bankFeeAccountAmountText),
        ),
        _KV(
          '其它费用($feeCurrencyLabel)',
          financeExactMoneyDisplay(d.otherFeeAccountAmountText),
        ),
        _KV('费用结算方式', switch (d.feeSettlementMode) {
          'DEDUCTED_FROM_PROCEEDS' => '从本批到账中扣除',
          'PAID_SEPARATELY' => '由其它真实账户另付',
          _ => '无费用',
        }),
        _KV('费用承担方', switch (d.feeBearer) {
          'COMPANY' => '本公司承担',
          'NONE' => '无费用',
          _ => '历史未分层',
        }),
        if (d.feePaymentAccountId != null)
          _KV('费用付款账户', names.account(d.feePaymentAccountId)),
        if (d.feePaymentAccountId != null) _KV('费用账户币种', feeCurrencyLabel),
        if (d.feePaymentAccountId != null)
          _KV('费用账户本位币汇率', d.feeAccountExchangeRateText),
        if (d.bankFeeText != null)
          _KV('银行费用本位币(人民币)', financeExactMoneyDisplay(d.bankFeeText)),
        if (d.otherFeeText != null)
          _KV('其它费用本位币(人民币)', financeExactMoneyDisplay(d.otherFeeText)),
      ] else if (isCustomerPrepayment) ...[
        _KV('收款账户币种', names.accountCurrency(d.accountId)),
        _KV(
          cnyReceiptAccount ? '本批人民币实际入账' : '本批本位币折算(人民币)',
          financeExactMoneyDisplay(d.amountLocalText),
        ),
        const _KV('资金来源', '已审核财务收款单；不是销售订单历史订金'),
      ] else if (isReceipt) ...[
        _KV(receiptLocalLabel, financeExactMoneyDisplay(receiptLocal)),
        _KV('本批费用冲销(人民币)', financeExactMoneyDisplay(writeOffLocal)),
        _KV(
          '本批核销折算合计(人民币)',
          financeExactMoneyDisplay(
            financeExactSumTexts([receiptLocal, writeOffLocal]),
          ),
        ),
        _KV('冲减应收账面金额(人民币)', financeExactMoneyDisplay(appliedLocal)),
        _KV('本批汇兑差额(人民币)', financeExactMoneyDisplay(exchangeDiffLocal)),
      ] else if (isPayment && (d.settlementAuthorityVersion ?? 0) >= 2) ...[
        const _KV('付款口径', '实际银行总扣款、货款与手续费分别记录'),
        _KV('本批货款原币', financeExactMoneyDisplay(d.amountOriginalText)),
        _KV(cnyReceiptAccount ? '本批汇率报价' : '外币账户记账汇率', d.exchangeRateText),
        _KV('银行扣款时间', utenFmtIsoTime(d.bankBookedAt)),
        _KV('银行扣款流水号', d.bankReference),
        _KV('实际付款账户币种', accountCurrencyLabel),
        _KV(
          '银行实际总扣款($accountCurrencyLabel)',
          financeExactMoneyDisplay(d.accountAmountText),
        ),
        _KV(
          '其中银行手续费($accountCurrencyLabel)',
          financeExactMoneyDisplay(d.bankFeeAccountAmountText),
        ),
        _KV(
          cnyReceiptAccount ? '实际总扣款本币' : '银行扣款账面本币',
          financeExactMoneyDisplay(d.accountAmountLocalText),
        ),
        _KV(
          cnyReceiptAccount ? '货款本币' : '货款账面本币',
          financeExactMoneyDisplay(d.amountLocalText),
        ),
        _KV(
          cnyReceiptAccount ? '银行手续费本币' : '银行手续费账面本币',
          financeExactMoneyDisplay(d.bankFeeText),
        ),
        _KV('冲减应付账面本币', financeExactMoneyDisplay(appliedLocal)),
        _KV('汇兑差额本币', financeExactMoneyDisplay(exchangeDiffLocal)),
      ] else
        _KV(
          isPayment ? '付款本币合计' : '合计(本币)',
          financeExactMoneyDisplay(d.amountLocalText),
        ),
      if (d.remark?.isNotEmpty == true) _KV('备注', d.remark),
      _KV(
        '状态',
        null,
        badge: FinanceStatusBadge(status: d.status, closed: d.closed),
      ),
      // C6：费用单总账过账状态（0 未过账/1 待确认/2 已确认）
      if (_cfg.type == FinanceDocType.expense && d.glStatus != null)
        _KV('总账', switch (d.glStatus) {
          1 => '已过账 · 待财务确认',
          2 => '已过账 · 财务已确认',
          _ => '未过账',
        }),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenFormGrid(children: [for (final r in rows) _kvRow(theme, r)]),
      ),
    );
  }

  Widget _kvRow(ThemeData theme, _KV r) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 84,
          child: Text(
            r.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(child: r.badge ?? Text(r.value ?? '—')),
      ],
    );
  }

  /// 明细表下的合计条（全站统一口径）：原币合计（标红）+ 本币合计。
  ///
  /// 钱流明细无单位口径，故不出「合计数量」。原币只在明细币种唯一时合计——
  /// 跨币种的原币金额与跨单位数量同理，**绝不相加**；任一行缺精确文本时
  /// `financeExactSumTexts` 返回 null，该项由合计条整体隐藏（不伪造 0）。
  Widget _totalsBar(FinanceNameService names, List<FinanceDocItem> items) {
    final currencyIds = items
        .map((it) => it.currencyId)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    final originalCurrencyId = currencyIds.length == 1
        ? currencyIds.first
        : (currencyIds.isEmpty ? _detail!.currencyId : null);
    final originalSum = originalCurrencyId == null
        ? null
        : financeExactSumTexts(items.map((it) => it.amountOriginalText));
    final localSum = financeExactSumTexts(
      items.map((it) => it.amountLocalText),
    );
    final originalText = originalSum == null
        ? ''
        : financeExactMoneyDisplay(originalSum);
    return UtenTotalsSummaryBar(
      key: const Key('finance-detail-totals'),
      density: true,
      entries: [
        UtenTotalEntry(
          utenAmountTotalLabel(
            financeCurrencyDisplayLabel(
              name: names.currency(originalCurrencyId),
            ),
          ),
          originalText,
          danger: true,
        ),
        UtenTotalEntry(
          '合计(本币)',
          localSum == null ? '' : financeExactMoneyDisplay(localSum),
          // 无原币口径（分摊/转账）时本币即单据主金额，由它承担标红。
          danger: originalText.isEmpty,
        ),
      ],
    );
  }

  /// 明细区：统一表格样式（MasterDataTableView 嵌入模式，与全站报表/主档同款），
  /// 不再是卡片式拼凑行；核销/分摊/转账三类列口径不变。
  Widget _itemsCard(ThemeData theme, FinanceNameService names) {
    final items = _detail!.items;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
        child: Text(
          _cfg.type == FinanceDocType.payment
              ? '无应付核销明细(直接/预付款)'
              : '无明细(直接${_cfg.shortLabel}，未指定核销/分摊)',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final styleCat = _cfg.type == FinanceDocType.expense ? 'EXPENSE' : 'INCOME';
    final cnyReceiptAccount =
        names.accountIsBaseCurrency(
          _detail!.accountId ?? _detail!.outAccountId,
        ) ==
        true;
    final isVersionedReceipt =
        _cfg.type == FinanceDocType.receipt &&
        (_detail!.settlementAuthorityVersion ?? 0) >= 1;
    final receiptLocalColumnLabel = isVersionedReceipt
        ? '分配折算毛额(人民币)'
        : cnyReceiptAccount
        ? '本批人民币实际入账'
        : '本批本位币折算(人民币)';
    final columns = <MasterColumnDef<FinanceDocItem>>[
      if (_cfg.type == FinanceDocType.receipt) ...[
        MasterColumnDef(
          key: 'bill',
          label: _cfg.isClient ? '应收单号' : '应付单号',
          width: 180,
          value: (it) => it.appliedBillNo,
        ),
        MasterColumnDef(
          key: 'currency',
          label: '应收币种',
          width: 150,
          value: (it) => names.currency(it.currencyId),
        ),
        MasterColumnDef(
          key: 'amountOriginal',
          label: _cfg.isClient ? '本次分配收款(原币)' : '本次付款金额',
          width: _cfg.isClient ? 180 : 130,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.amountOriginalText),
        ),
        MasterColumnDef(
          key: 'exchangeRate',
          label: (_detail!.settlementAuthorityVersion ?? 0) >= 2
              ? '本批汇率报价'
              : '当前批次实际到账汇率',
          width: 190,
          type: 'number',
          value: (it) => it.exchangeRateText,
        ),
        MasterColumnDef(
          key: 'amountLocal',
          label: receiptLocalColumnLabel,
          width: 170,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.amountLocalText),
        ),
        if (!isVersionedReceipt) ...[
          MasterColumnDef(
            key: 'writeOffAmount',
            label: '历史冲销(应收原币)',
            width: 180,
            type: 'money',
            value: (it) => financeExactMoneyDisplay(it.writeOffAmountText),
          ),
          MasterColumnDef(
            key: 'writeOffLocal',
            label: '历史冲销(人民币)',
            width: 150,
            type: 'money',
            value: (it) => financeExactMoneyDisplay(it.writeOffLocalText),
          ),
        ],
        MasterColumnDef(
          key: 'appliedAmountLocal',
          label: '冲减应收账面金额(人民币)',
          width: 200,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.appliedAmountLocalText),
        ),
        MasterColumnDef(
          key: 'exchangeDiff',
          label: '汇兑差额(人民币)',
          width: 160,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.exchangeDiffText),
        ),
        MasterColumnDef(
          key: 'balanceBeforeOriginal',
          label: _cfg.isClient ? '收款前未收' : '付款前未付',
          width: 110,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.balanceBeforeOriginalText),
        ),
        MasterColumnDef(
          key: 'balanceAfterOriginal',
          label: _cfg.isClient ? '收款后未收' : '付款后未付',
          width: 110,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.balanceAfterOriginalText),
        ),
        MasterColumnDef(
          key: 'remark',
          label: '备注',
          width: 160,
          value: (it) => it.remark,
        ),
      ] else if (_cfg.isSettle) ...[
        MasterColumnDef(
          key: 'bill',
          label: '应付单号',
          width: 180,
          value: (it) => it.appliedBillNo,
        ),
        MasterColumnDef(
          key: 'amountOriginal',
          label: '本次付款(原币)',
          width: 110,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.amountOriginalText),
        ),
        MasterColumnDef(
          key: 'amountLocal',
          label: '付款本币',
          width: 110,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.amountLocalText),
        ),
        MasterColumnDef(
          key: 'appliedAmountLocal',
          label: '核销账面本币',
          width: 120,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.appliedAmountLocalText),
        ),
        MasterColumnDef(
          key: 'exchangeDiff',
          label: '汇兑差额',
          width: 110,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.exchangeDiffText),
        ),
      ] else if (_cfg.isAllocate) ...[
        MasterColumnDef(
          key: 'style',
          label: '项目',
          width: 160,
          value: (it) =>
              names.styleName(it.expenseStyleId ?? it.incomeStyleId, styleCat),
        ),
        MasterColumnDef(
          key: 'dept',
          label: '部门',
          width: 140,
          value: (it) => names
              .client(it.departmentId)
              .replaceAll('—', it.departmentId ?? '—'),
        ),
        MasterColumnDef(
          key: 'qty',
          label: '数量',
          width: 90,
          type: 'number',
          value: (it) => it.qtyText,
        ),
        MasterColumnDef(
          key: 'price',
          label: '单价',
          width: 90,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.priceText),
        ),
        MasterColumnDef(
          key: 'amount',
          label: '金额',
          width: 100,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.amountLocalText),
        ),
      ] else if (_cfg.isTransfer) ...[
        MasterColumnDef(
          key: 'inAccount',
          label: '转入账户',
          width: 160,
          value: (it) => names.account(it.inAccountId),
        ),
        MasterColumnDef(
          key: 'occurDate',
          label: '日期',
          width: 110,
          type: 'date',
          value: (it) => (it.occurDate ?? '').length >= 10
              ? it.occurDate!.substring(0, 10)
              : it.occurDate,
        ),
        MasterColumnDef(
          key: 'amount',
          label: '金额',
          width: 110,
          type: 'money',
          value: (it) => financeExactMoneyDisplay(it.amountLocalText),
        ),
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '明细 (${items.length})',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        // primary:true → 表体占满 body 并参与「头部折叠 → 表格内滚」联动；
        // 合计条留在表格下方常驻（不随表体内滚）。
        Expanded(
          child: MasterDataTableView<FinanceDocItem>(
            primary: true,
            columns: columns,
            items: items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            emptyMessage: '(无明细)',
          ),
        ),
        _totalsBar(names, items),
      ],
    );
  }

  Widget _actions(ThemeData theme) {
    final detail = _detail!;
    final children = <Widget>[];

    void addAction(Widget action) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(width: UtenSpacing.s8));
      }
      children.add(action);
    }

    // 「返回列表」只对能进列表页的人渲染（无列表权限的入口 push 进来时按钮
    // 会落到 /access-denied；2026-09-10 审计）；走返回键契约 pop 回来源。
    final listPath = '/finance/${_cfg.type.pathSegment}';
    final canOpenList = locationAllowedFor(
      ref.read(currentPermissionsProvider),
      ref.read(isSuperAdminProvider),
      listPath,
    );
    void addBack() {
      if (!canOpenList) return;
      addAction(
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => popOrBackTo(context, defaultPath: listPath),
          child: const Text('返回列表'),
        ),
      );
    }

    if (detail.status == kFinanceStatusDraft) {
      if (_canDelete) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.delete_outline,
            onPressed: _delete,
            child: const Text('删除'),
          ),
        );
      }
      if (_canEdit) {
        addAction(
          UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.edit_outlined,
            onPressed: () => context.push(
              '/finance/${_cfg.type.pathSegment}/${widget.id}/edit',
            ),
            child: const Text('编辑'),
          ),
        );
      }
      if (_canApprove) {
        addAction(
          UtenButton(
            icon: Icons.check_circle_outline,
            onPressed: _approve,
            child: const Text('审核'),
          ),
        );
      }
      if (children.isEmpty) addBack();
    } else if (detail.status == kFinanceStatusApproved) {
      if (_cfg.type == FinanceDocType.expense &&
          detail.glStatus == 1 &&
          _canConfirmGeneralLedger) {
        addAction(
          UtenButton(
            icon: Icons.fact_check_outlined,
            onPressed: _glConfirm,
            child: const Text('财务确认'),
          ),
        );
      }
      if (_canReverse) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.undo_outlined,
            onPressed: _reverse,
            child: const Text('红冲'),
          ),
        );
      }
      if (children.isEmpty) addBack();
    } else {
      addBack();
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: children,
        ),
      ),
    );
  }
}

class _KV {
  const _KV(this.label, this.value, {this.badge});
  final String label;
  final String? value;
  final Widget? badge;
}
