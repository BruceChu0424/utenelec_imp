import '../../sales/widgets/sales_shipment_print.dart';
import '../config/finance_requirement_names.dart';
import '../widgets/finance_actual_receipt_context.dart';
import '../../../shared/widgets/sales_order_money_position_view.dart';
import '../../../shared/widgets/shipment_receivable_position_view.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../core/network/data_write_revision.dart';
import '../../../shared/models/customer_actual_receipt_context.dart';
import '../../../core/router/page_resume_provider.dart';
// 出货财务审核详情页（财务专用视图，与销售端出货详情分离；2026-09-12 拆分）。
//
// 对齐销售订单财务审核页 V300 / 订货审批审核详情页（ADR-027 §五）范式：
//  - 状态条：单据号 + 待审核 / 已放行 / 已退回；
//  - 客户财务快照卡：本单结账方式、正式应收未收、铺底额、超出铺底额（红字）、
//    可用预收（原币/本币）；V630 起客户不再有货款分类标签，放行不被分类阻断；
//  - 商业快照逐行对比：旧整行红色划除，下一行绿色展示新内容；
//  - 出货信息卡 + 只读明细（MasterDataTableView 嵌入模式）+ 只读附件；
//  - 底部右下悬浮双决策：退回销售（必填原因，红）/ 确认放行；认领机制
//    （SALES_SHIPMENT_FINANCE_AUDIT）贯穿加载与提交，他人认领中禁止决策。
// 本页不出现销售端操作（编辑/删除/销售确认）与仓库作业，职责分离。
import 'dart:async';

import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_detail_summary_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/permissions.dart';

import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../../shared/business_columns/business_columns_table.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../sales/config/sales_doc_config.dart';
import '../../sales/models/sales_doc.dart';
import '../../sales/providers/master_name_provider.dart';
import '../../sales/repositories/sales_repository.dart';
import '../../sales/widgets/shipment_finance_change_summary.dart';
import '../widgets/finance_party_snapshot_card.dart';
import '../../../shared/drafts/review_task_draft.dart';
import '../../../shared/drafts/review_authority_refresh_mixin.dart';
import '../../../shared/badges/badge_registry.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';

class FinanceSalesShipmentAuditReviewPage extends ConsumerStatefulWidget {
  const FinanceSalesShipmentAuditReviewPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<FinanceSalesShipmentAuditReviewPage> createState() =>
      _FinanceSalesShipmentAuditReviewPageState();
}

class _FinanceSalesShipmentAuditReviewPageState
    extends ConsumerState<FinanceSalesShipmentAuditReviewPage>
    with
        FormDraftMixin<FinanceSalesShipmentAuditReviewPage>,
        ReviewTaskDraftMixin<FinanceSalesShipmentAuditReviewPage>,
        ReviewAuthorityRefreshMixin<FinanceSalesShipmentAuditReviewPage> {
  SalesDocDetail? _detail;
  ShipmentFinanceAuditInfo? _info;
  ShipmentReceivablePosition? _currentMoney;
  int _moneyGeneration = 0;
  bool _loading = true;
  bool _referencesExpanded = false;
  int _referenceScrollRequest = 0;
  bool _busy = false;
  bool _authorityStale = false;
  @override
  Set<String> get reviewAuthorityPermissionCodes => const {
    Perm.salesShipmentFinanceView,
    Perm.salesShipmentFinanceApprove,
    Perm.salesShipmentFinanceReject,
    Perm.salesShipmentFinanceReverse,
  };
  @override
  bool get reviewAuthorityRefreshBlocked =>
      _loading ||
      _busy ||
      formDraftHasUnknownSubmission ||
      formDraftRestorationBlocked;
  @override
  Future<void> refreshReviewAuthority() => _load(authorityOnly: true);

  bool _hasReviewPermission(String code) =>
      ref.read(isSuperAdminProvider) ||
      (ref
              .read(currentPermissionsProvider)
              .contains(Perm.salesShipmentFinanceView) &&
          ref.read(currentPermissionsProvider).contains(code));
  String? _error;

  /// 明细行勾选集（2026-10-10 审核页防看岔行口径：纯阅读辅助）。
  final Set<String> _selectedItemIds = <String>{};

  /// V632：放行时确认的记账汇率(本位币/1 原币)。预填服务端建议值(已冻结的 > 本位币 1 >
  /// 币种主档参考汇率)，财务可按放行当日汇率修改；放行即冻结到本单，仓库确认出库按它立应收。
  final _rateController = TextEditingController();
  final _rejectReason = TextEditingController();
  @override
  bool get formDraftBusy => _busy;
  @override
  FormDraftDescriptor get reviewDraftDescriptor =>
      FormDraftCatalog.financeShipmentReview;
  @override
  String get reviewDraftRoute =>
      '/finance/sales-shipment-audits/${Uri.encodeComponent(widget.id)}';
  @override
  Map<String, dynamic> get reviewDraftSource => {
    'subjectId': widget.id,
    'version': _info?.reviewRevision,
    'contentHash': _info?.contentHash,
    'lineIds':
        (_detail?.items.map((line) => line.id).whereType<String>().toList() ??
              <String>[])
          ..sort(),
  };
  @override
  bool get reviewDraftEditable => _decisionReady && _canDecide;
  @override
  bool canDispatchReviewCommand(String action) =>
      !_authorityStale &&
      _decisionReady &&
      _claim?.isReady == true &&
      _info?.allows(action == 'reject' ? 'REJECT' : 'APPROVE') == true &&
      _hasReviewPermission(
        action == 'reject'
            ? Perm.salesShipmentFinanceReject
            : Perm.salesShipmentFinanceApprove,
      );
  @override
  Iterable<Listenable> get formDraftListenables => [
    _rateController,
    _rejectReason,
  ];
  @override
  Map<String, dynamic> captureReviewInputs() => {
    'rate': _rateController.text,
    'rejectReason': _rejectReason.text,
  };
  @override
  void restoreReviewInputs(Map<String, dynamic> inputs) {
    _rateController.text = inputs['rate'] as String? ?? '';
    _rejectReason.text = inputs['rejectReason'] as String? ?? '';
  }

  @override
  Future<void> reloadReviewSource() async {
    await _load();
    if (_error != null || _detail == null || _info == null) {
      throw StateError(_error ?? '出货审核结果尚未读取');
    }
  }

  @override
  Future<bool> recoverReviewCommand(Map<String, dynamic> command) async {
    final source = command['source'];
    if (source is! Map || source['subjectId'] != widget.id) return false;
    final repo = ref.read(salesRepositoryProvider(SalesDocType.shipment));
    final current = await repo.detail(widget.id);
    if (current.id != widget.id) return false;
    final review = await repo.financeAuditInfo(widget.id);
    if (review.shipmentId != widget.id ||
        review.reviewRevision != source['version'] ||
        review.contentHash != source['contentHash']) {
      return false;
    }
    return switch (command['action']) {
      'approve' =>
        current.financeAudit == 1 &&
            ((command['request'] as Map?)?['exchangeRate'] == null
                ? review.shipmentExchangeRate == null
                : financeRateUnits(review.shipmentExchangeRate) != null &&
                      financeRateUnits(review.shipmentExchangeRate) ==
                          financeRateUnits(
                            (command['request'] as Map?)?['exchangeRate']
                                as String?,
                          )),
      'reject' =>
        current.shipmentWorkflow.financeRejected &&
            current.shipmentWorkflow.financeRejectionReason ==
                (command['request'] as Map?)?['reason'],
      _ => false,
    };
  }

  @override
  void closeRecoveredReview() => _closeAfterDecision();
  String? _rateError;
  final Map<String, String> _settlementNames = {};

  TaskClaimSession? _claim;
  int _loadGeneration = 0;

  /// 出货财审按动作分权(permissions-09)，按钮只按服务端下发的 allowedActions 显隐
  /// (permissions-15)：动作码、对象范围、单据状态都由服务端一次算好，页面不再本地拼权限。
  bool get _canApprove =>
      !_authorityStale &&
      _hasReviewPermission(Perm.salesShipmentFinanceApprove) &&
      (_info?.allows('APPROVE') ?? false);
  bool get _canReject =>
      !_authorityStale &&
      _hasReviewPermission(Perm.salesShipmentFinanceReject) &&
      (_info?.allows('REJECT') ?? false);
  bool get _canReverse =>
      !_authorityStale &&
      _hasReviewPermission(Perm.salesShipmentFinanceReverse) &&
      (_info?.allows('REVERSE') ?? false);
  bool get _canDecide => _canApprove || _canReject;

  /// 免费发货不立应收，不需要记账汇率。
  bool get _isFreeShipment => _info?.billingMode == 'FREE';

  /// 本位币汇率固定为 1，汇率框锁定。
  bool get _rateLocked => _info?.baseCurrency == true;

  /// 币种主档参考汇率没维护(V631 口径 ≤0)：V632 起不挡放行，改由财务在放行时填写。
  bool get _masterRateMissing => _info?.financeRateReady == false;

  /// 服务端是否给了汇率信息(V632 之前的载荷三个键都没有：不在客户端拦，交服务端按主档决定)。
  bool get _rateInfoKnown {
    final info = _info;
    return info != null &&
        (info.financeRateReady != null ||
            info.baseCurrency != null ||
            info.suggestedExchangeRate != null);
  }

  /// 校验并返回要提交的记账汇率文本；免费发货或服务端未给汇率信息时返回 null(不提交)。
  String? _validatedExchangeRate() {
    if (_isFreeShipment || !_rateInfoKnown) return null;
    if (_rateLocked) return '1';
    final text = _rateController.text.trim();
    if (text.isEmpty) {
      throw const FormatException('请填写记账汇率(本位币/1 原币)，放行后仓库出库按它立应收');
    }
    final units = financeExactDecimalUnits(text, scale: 6);
    if (units == null || units <= BigInt.zero) {
      throw const FormatException('记账汇率必须大于 0，最多保留 6 位小数');
    }
    // 去掉小数尾零(7.200000 → 7.2)，服务端按 BigDecimal 比较，只是让请求与回显一致。
    var normalized = financeExactDecimalFromUnits(units, scale: 6);
    if (normalized.contains('.')) {
      normalized = normalized.replaceFirst(RegExp(r'0+$'), '');
      if (normalized.endsWith('.')) {
        normalized = normalized.substring(0, normalized.length - 1);
      }
    }
    return normalized;
  }

  /// 按当前汇率框折合本币的参考值(仅预览，权威值由服务端在出库立账时计算)。
  String? _localAmountPreview() {
    final detail = _detail;
    if (detail == null) return null;
    final rate = financeRateUnits(_rateController.text);
    if (rate == null || rate <= BigInt.zero) return null;
    final exact = financeExactMultiplyTexts([
      detail.exactDecimals['totalOriginal'] ?? detail.totalOriginal?.toString(),
      _rateController.text.trim(),
    ]);
    return exact == null ? null : financeMoneyText(exact);
  }

  /// 决策可用：待审 + 已销售确认 + 未退回 + 快照完整 + 认领就绪。
  bool get _decisionReady {
    final d = _detail;
    final info = _info;
    if (d == null || info == null) return false;
    if (d.financeAudit == 1) return false;
    if (d.shipmentWorkflow.financeRejected) return false;
    if (!salesShipmentAllowsFinanceAudit(d.warehouseWorkStatus)) return false;
    if (!d.shipmentWorkflow.salesConfirmed) return false;
    return info.reviewRevision != null && info.contentHash != null;
  }

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
    _claim?.removeListener(_claimChanged);
    _claim?.releaseAll().ignore();
    _rateController.dispose();
    _rejectReason.dispose();
    super.dispose();
  }

  void _claimChanged() {
    if (mounted) setState(() {});
  }

  /// Cash changes must not replace the commercial review, its frozen evidence,
  /// claims or typed review inputs. Only the current shipment debt is adopted.
  Future<void> _refreshCurrentMoney() async {
    if (!formDraftIdentityIsCurrent ||
        !_hasReviewPermission(Perm.salesShipmentFinanceView)) {
      return;
    }
    final owner = captureReadOwner(ref);
    final request = ++_moneyGeneration, load = _loadGeneration;
    final writeRevision = ref.read(dataWriteRevisionProvider);
    try {
      final repository = ref.read(
        salesRepositoryProvider(SalesDocType.shipment),
      );
      final scope = await captureFormDraftRequestScope();
      final info = await scope.run(
        () => repository.financeAuditInfo(widget.id),
      );
      if (!mounted ||
          !owner() ||
          !formDraftIdentityIsCurrent ||
          request != _moneyGeneration ||
          load != _loadGeneration ||
          writeRevision != ref.read(dataWriteRevisionProvider)) {
        return;
      }
      if (info.shipmentId != widget.id) {
        throw const FormatException('本批金额来源已变化');
      }
      setState(
        () => _currentMoney =
            info.receivablePosition ??
            const ShipmentReceivablePosition(warnings: ['本批金额尚未读取完成，请刷新核对']),
      );
    } catch (_) {
      if (mounted &&
          owner() &&
          formDraftIdentityIsCurrent &&
          request == _moneyGeneration &&
          load == _loadGeneration &&
          writeRevision == ref.read(dataWriteRevisionProvider)) {
        setState(
          () => _currentMoney = const ShipmentReceivablePosition(
            warnings: ['本批金额读取未完成，原审核输入已保留，请刷新核对'],
          ),
        );
      }
    }
  }

  Future<CustomerActualReceiptContext?> _readCustomerReceiptReference() async {
    if (!formDraftIdentityIsCurrent ||
        !_hasReviewPermission(Perm.salesShipmentFinanceView)) {
      throw StateError('当前无权读取客户到账参考');
    }
    final owner = captureReadOwner(ref);
    final load = _loadGeneration;
    final sourceRevision = _info?.reviewRevision;
    final sourceHash = _info?.contentHash;
    final writeRevision = ref.read(dataWriteRevisionProvider);
    final repository = ref.read(salesRepositoryProvider(SalesDocType.shipment));
    final scope = await captureFormDraftRequestScope();
    final info = await scope.run(() => repository.financeAuditInfo(widget.id));
    if (!mounted ||
        !owner() ||
        !formDraftIdentityIsCurrent ||
        !_hasReviewPermission(Perm.salesShipmentFinanceView) ||
        load != _loadGeneration ||
        writeRevision != ref.read(dataWriteRevisionProvider) ||
        info.shipmentId != widget.id ||
        info.reviewRevision != sourceRevision ||
        info.contentHash != sourceHash) {
      throw StateError('客户到账参考来源已变化，请重新读取');
    }
    return info.actualReceiptContext;
  }

  Future<void> _reloadFromButton() => UtenBusyOverlay.run(
    context,
    title: '正在刷新出货资料',
    action: () => _load(authorityOnly: true),
  );

  Future<void> _load({bool authorityOnly = false}) async {
    final previousInfo = _info;
    final preserveInputs = authorityOnly && previousInfo != null;
    if (preserveInputs && reviewAuthorityRefreshBlocked) return;
    if (!preserveInputs) await prepareReviewReload();
    if (!mounted || !formDraftIdentityIsCurrent) return;
    final generation = ++_loadGeneration;
    final moneyGeneration = _moneyGeneration;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() {
      _loading = true;
      _error = null;
      if (!preserveInputs) {
        _detail = null;
        _info = null;
        _currentMoney = null;
        _settlementNames.clear();
        _authorityStale = false;
      }
    });
    try {
      _claim?.removeListener(_claimChanged);
      await _claim?.releaseAll();
      if (!mounted || generation != _loadGeneration) return;
      _claim = null;

      final repo = ref.read(salesRepositoryProvider(SalesDocType.shipment));
      // 先取详情判断状态，再决定是否认领（已办结单据不占认领）。
      final detail = await repo.detail(widget.id);
      if (!mounted || generation != _loadGeneration) return;
      // 核对信息里带着本人此刻能做的动作；只有能放行或退回时才认领(已办结 / 无权的不占认领)。
      final info = await repo.financeAuditInfo(widget.id);
      if (!mounted || generation != _loadGeneration) return;
      if (preserveInputs &&
          (info.shipmentId != previousInfo.shipmentId ||
              info.reviewRevision != previousInfo.reviewRevision ||
              info.contentHash != previousInfo.contentHash ||
              info.financeAudit != previousInfo.financeAudit)) {
        setState(() {
          _authorityStale = true;
          _loading = false;
          _error = AppLocalizations.of(context).financeReviewAuthorityChanged;
        });
        return;
      }
      if ((info.allows('APPROVE') &&
              _hasReviewPermission(Perm.salesShipmentFinanceApprove)) ||
          (info.allows('REJECT') &&
              _hasReviewPermission(Perm.salesShipmentFinanceReject))) {
        final claim = financeReviewClaim(
          container,
          localizations: AppLocalizations.of(context),
        )..addListener(_claimChanged);
        _claim = claim;
        await claim.claimAll('SALES_SHIPMENT_FINANCE_AUDIT', [widget.id]);
        if (!mounted || generation != _loadGeneration || !claim.isCurrent) {
          await claim.releaseAll();
          return;
        }
      }

      if (!mounted ||
          !formDraftIdentityIsCurrent ||
          generation != _loadGeneration) {
        return;
      }

      setState(() {
        _detail = detail;
        _info = info;
        if (moneyGeneration == _moneyGeneration) {
          _currentMoney = info.receivablePosition ?? detail.receivablePosition;
        }
        _authorityStale = false;
        _loading = false;
        // 预填记账汇率：已冻结的 > 本位币 1 > 主档参考汇率 > 空(主档没维护，要财务填)。
        if (!preserveInputs) {
          _rateController.text = info.suggestedExchangeRate ?? '';
          _rateError = null;
          _rejectReason.clear();
        }
      });
      unawaited(_resolveDisplayNames(detail, info, generation));
      await bindReviewDraft();
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

  Future<void> _resolveDisplayNames(
    SalesDocDetail detail,
    ShipmentFinanceAuditInfo info,
    int generation,
  ) async {
    final names = ref.read(salesMasterNameServiceProvider);
    final ownerCurrent = captureReadOwner(ref);
    final goods = {
      ...detail.items.map((item) => item.goodsId).whereType<String>(),
      ...shipmentReviewSnapshotIds(info.previousCommercialSnapshot, 'goodsId'),
      ...shipmentReviewSnapshotIds(info.commercialSnapshot, 'goodsId'),
    };
    final settlementNames = <String, String>{};
    try {
      await Future.wait([
        names.ensureLoaded(),
        names.loadClientNames({
          ...[detail.clientId].whereType<String>(),
          ...shipmentReviewSnapshotIds(
            info.previousCommercialSnapshot,
            'clientId',
          ),
          ...shipmentReviewSnapshotIds(info.commercialSnapshot, 'clientId'),
        }),
        names.loadGoodsNamesWithCodes(goods),
        names.loadEmployeeNames([
          detail.sellerId,
          detail.senderId,
          ...shipmentReviewSnapshotIds(
            info.previousCommercialSnapshot,
            'sellerId',
          ),
          ...shipmentReviewSnapshotIds(
            info.previousCommercialSnapshot,
            'senderId',
          ),
        ]),
        if (info.previousCommercialSnapshot?.isNotEmpty == true)
          names.dictionaries.load(ApiEndpoints.settlementMethods).then((rows) {
            settlementNames.addEntries(
              rows.map(
                (row) => MapEntry(
                  row['id'].toString(),
                  row['name']?.toString() ?? '—',
                ),
              ),
            );
          }),
      ]);
      if (!ownerCurrent() ||
          !formDraftIdentityIsCurrent ||
          generation != _loadGeneration ||
          !identical(_detail, detail) ||
          !identical(_info, info)) {
        return;
      }
      setState(() => _settlementNames.addAll(settlementNames));
    } catch (_) {
      // Optional display enrichment never replaces the editable financial facts.
    }
  }

  Future<void> _leave() async {
    if (!await confirmFormDraftExit() || !mounted) return;
    await _claim?.releaseAll();
    if (!mounted) return;
    popOrBackTo(context, defaultPath: RouteName.financeSalesShipmentAudit);
  }

  /// 决策完成后的落点：从工作台 push 进来 → 带 true 返回值 pop，列表刷新；
  /// 深链/路由栈空 → 跳回出货财务审核工作台（勿裸 pop，见 v2026.09.03-1 事故）。
  void _closeAfterDecision() {
    refreshBadges(ref);
    bumpListRefresh(ref, SalesDocConfig.by(SalesDocType.shipment).refreshKey);
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(true);
    } else {
      context.go(RouteName.financeSalesShipmentAudit);
    }
  }

  Future<void> _approve() async {
    final claim = _claim;
    final info = _info;
    if (info == null ||
        !_decisionReady ||
        claim == null ||
        !claim.isReady ||
        _busy) {
      context.appWarning('审核认领还没有生效，请重新认领并核对内容');
      return;
    }
    final String? exchangeRate;
    try {
      exchangeRate = _validatedExchangeRate();
    } on FormatException catch (e) {
      setState(() {
        _rateError = e.message;
        _referencesExpanded = true;
        ++_referenceScrollRequest;
      });
      context.appWarning(e.message);
      return;
    }
    final localPreview = _localAmountPreview();
    final rateLine = exchangeRate == null
        ? null
        : '记账汇率 $exchangeRate(1 ${financeCurrencyText(name: info.currencyName)} = $exchangeRate 本币)'
              '${localPreview == null ? '' : '，本单折合本币约 $localPreview'}；'
              '仓库确认出库时按此汇率折算本币立应收。';
    final generation = _loadGeneration;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => UtenAlertDialog(
        title: Text('确认放行 ${_detail?.billNo ?? ''}'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const UtenReviewerResponsibilityNotice(
                actionLabel: FinanceRequirementNames.customerShipmentReview,
                description: '确认仅放行仓库作业；正式应收在仓库确认出库后生成。系统将记录当前审核员并承担本次放行责任。',
                compact: true,
              ),
              const SizedBox(height: UtenSpacing.s12),
              const Text('放行后仓库即可确认出库；出库时才扣库存并生成应收。确认放行？'),
              if (rateLine != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  rateLine,
                  key: const Key('finance-shipment-audit-confirm-rate'),
                  style: Theme.of(
                    dialogCtx,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
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
            key: const Key('finance-shipment-audit-confirm'),
            claim: claim,
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('确认放行'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      if (!await claim.validateForDecision() ||
          !mounted ||
          generation != _loadGeneration ||
          !identical(info, _info)) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '审核内容或认领已变化，请重新认领并核对');
        }
        return;
      }
      await submitReviewCommand(
        'approve',
        () => ref
            .read(salesRepositoryProvider(SalesDocType.shipment))
            .financeAudit(
              widget.id,
              expectedRevision: info.reviewRevision!,
              expectedContentHash: info.contentHash!,
              expectedClaimId: claim.claimIdFor(
                'SALES_SHIPMENT_FINANCE_AUDIT',
                widget.id,
              )!,
              exchangeRate: exchangeRate,
            ),
        request: {'exchangeRate': exchangeRate},
      );
      if (!mounted) return;
      await finishReviewDraft();
      if (!mounted || !formDraftIdentityIsCurrent) return;
      context.appSuccess('财务已确认，仓库可以出库');
      _closeAfterDecision();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('财务审核失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    final claim = _claim;
    final info = _info;
    if (info == null ||
        !_decisionReady ||
        claim == null ||
        !claim.isReady ||
        _busy) {
      context.appWarning('审核认领还没有生效，请重新认领并核对内容');
      return;
    }
    final generation = _loadGeneration;
    final controller = _rejectReason;
    String? errorText;
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => UtenAlertDialog(
          title: Text('退回销售 ${_detail?.billNo ?? ''}'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const UtenReviewerResponsibilityNotice(
                  actionLabel: '出货财务退回',
                  description: '退回后销售可修改再确认；系统将记录退回人、原因和时间。',
                  compact: true,
                ),
                const SizedBox(height: UtenSpacing.s12),
                const Text('退回原因将通知销售修改；确认后本单回到「待销售确认」。'),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  key: const Key('finance-shipment-audit-reject-reason'),
                  controller: controller,
                  autofocus: true,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: '退回原因(必填)',
                      border: const OutlineInputBorder(),
                      error: utenFieldError(errorText),
                    ),
                    info: '写明需要销售修改的内容，如结账方式或明细数量。',
                  ),
                ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('取消'),
            ),
            FinanceReviewClaimButton(
              key: const Key('finance-shipment-audit-reject-submit'),
              claim: claim,
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogCtx).colorScheme.error,
                foregroundColor: Theme.of(dialogCtx).colorScheme.onError,
              ),
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  setDialogState(() => errorText = '请填写退回原因');
                  return;
                }
                Navigator.pop(dialogCtx, value);
              },
              child: const Text('确认退回'),
            ),
          ],
        ),
      ),
    );
    // 弹窗退场动画仍在用 controller（~150ms）：延迟释放，避免 used-after-dispose。
    if (reason == null || reason.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      if (!await claim.validateForDecision() ||
          !mounted ||
          generation != _loadGeneration ||
          !identical(info, _info)) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '审核内容或认领已变化，请重新认领并核对');
        }
        return;
      }
      await submitReviewCommand(
        'reject',
        () => ref
            .read(salesRepositoryProvider(SalesDocType.shipment))
            .rejectShipmentFinance(
              widget.id,
              expectedRevision: info.reviewRevision!,
              expectedContentHash: info.contentHash!,
              expectedClaimId: claim.claimIdFor(
                'SALES_SHIPMENT_FINANCE_AUDIT',
                widget.id,
              )!,
              reason: reason,
            ),
        request: {'reason': reason.trim()},
      );
      if (!mounted) return;
      await finishReviewDraft();
      if (!mounted || !formDraftIdentityIsCurrent) return;
      context.appSuccess('已退回销售修改');
      _closeAfterDecision();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('退回失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 撤回退回可用：被退回 + 未放行(仓库未作业与反审权限已由服务端 REVERSE 动作判定，V578)。
  bool get _canRejectReverse {
    final d = _detail;
    if (d == null || !_canReverse || _busy) return false;
    return d.financeAudit != 1 && d.shipmentWorkflow.financeRejected;
  }

  /// 撤回退回（V578）：财务收回退回决定，单据恢复待审——退回原因与出货
  /// 内容无关（如客户货款分类未维护、误退）时无需销售改单来回折腾。
  Future<void> _rejectReverse() async {
    if (_busy) return;
    final billNo = _detail?.billNo ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => UtenAlertDialog(
        title: Text('撤回退回 $billNo'),
        content: const SizedBox(
          width: 440,
          child: Text('撤回后本单恢复「待财务审核」，销售无需重新确认；可直接重新核对并放行。确认撤回？'),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('finance-shipment-audit-reject-reverse'),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('撤回退回'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(salesRepositoryProvider(SalesDocType.shipment))
          .financeRejectReverse(widget.id);
      if (!mounted) return;
      context.appSuccess('已撤回退回，本单恢复待财务审核');
      _closeAfterDecision();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('撤回退回失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.onPageResume(
      currentLocationOr(context, '/finance/sales-shipment-audits/${widget.id}'),
      _refreshCurrentMoney,
      refreshKeys: const ['sales:shipment', 'sales:customerShipment'],
    );
    scheduleReviewAuthorityRefresh();
    ref.listen(sessionProvider, (previous, next) {
      // 只有真实换身份才清空（换号/登出/模拟切换/业务重置）；token 静默刷新、
      // 同身份授权变化由独立监听刷新动作与认领，保留原审核输入。
      if (previous?.isSameIdentity(next) ?? false) return;
      ++_loadGeneration;
      ++_moneyGeneration;
      _claim?.removeListener(_claimChanged);
      _claim?.releaseAll().ignore();
      _claim = null;
      if (mounted) {
        setState(() {
          _detail = null;
          _info = null;
          _currentMoney = null;
          _loading = false;
          _error = '登录身份已变化，请重新加载并认领审核';
        });
      }
    });
    final theme = Theme.of(context);
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: FinanceRequirementNames.customerShipmentReview,
          leading: UtenBackButton(onPressed: _leave),
          actions: [
            if (_detail?.financeAudit == 1 && (_detail?.status ?? -1) >= 0)
              UtenButton(
                icon: Icons.print_outlined,
                onPressed: _busy
                    ? null
                    : () async {
                        try {
                          await showSalesShipmentPrint(context, ref, widget.id);
                        } catch (error) {
                          if (context.mounted) {
                            context.appApiError(error, fallback: '打印预览未读取完成');
                          }
                        }
                      },
                child: const Text('预览打印'),
              ),
            UtenRefreshButton(
              enabled: !_busy,
              busy: _loading,
              onRefresh: _reloadFromButton,
            ),
          ],
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
                          onPressed: _reloadFromButton,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              : _detail == null || _info == null
              ? const SizedBox.shrink()
              : Stack(
                  children: [
                    AbsorbPointer(
                      absorbing: _busy,
                      // 默认容器不设固定最大宽度，正文随导航收起和窗口加宽扩展；
                      // 滚动仍为折叠头+表内滚：上滑先收卡片区，明细标题吸顶后在表格内部滚。
                      child: UtenContentContainer(
                        child: UtenCollapsingHeaderScrollView(
                          collapsingHeader: UtenPageEdgePadding(
                            padding: const EdgeInsets.fromLTRB(
                              UtenSpacing.s12,
                              UtenSpacing.s12,
                              UtenSpacing.s12,
                              UtenSpacing.s12,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (_canDecide &&
                                    _decisionReady &&
                                    _claim?.isReady != true) ...[
                                  FinanceReviewClaimNotice(
                                    claim: _claim,
                                    onRetry: _busy ? null : _reloadFromButton,
                                  ),
                                  const SizedBox(height: UtenSpacing.s12),
                                ],
                                _shipmentCard(theme, _detail!),
                                // 2026-09-25 用户口径：纯计数标题「出货明细(N)」退役；
                                // 修订对比态标题保留（表体看不出这是对比视图）。
                                if (_itemsTitle(_detail!)
                                    case final itemsTitle?) ...[
                                  const SizedBox(height: UtenSpacing.s12),
                                  Text(
                                    itemsTitle,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          body: UtenPageEdgePadding(
                            padding: const EdgeInsets.fromLTRB(
                              UtenSpacing.s12,
                              UtenSpacing.s12,
                              UtenSpacing.s12,
                              UtenFloatingActionGroup.controlHeight +
                                  UtenSpacing.s32,
                            ),
                            child: _itemsCard(theme, _detail!),
                          ),
                        ),
                      ),
                    ),
                    // 2026-09-12 口径：点按钮等一段必须屏幕中央加载动画（跟随网络段）。
                    if (_busy)
                      const Positioned.fill(
                        child: UtenBusyOverlay(title: '正在提交审核决定'),
                      ),
                  ],
                ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: _detail == null || _info == null
            ? null
            : _floatingActions(theme),
      ),
    );
  }

  /// 右下悬浮操作组：待审=退回销售(红)+确认放行；已退回=撤回退回；其余状态只留返回。
  Widget? _floatingActions(ThemeData theme) {
    final claimReady = _claim?.isReady == true;
    final canDecide = _canDecide && _decisionReady && claimReady && !_busy;
    if (_canRejectReverse) {
      return UtenFloatingActionGroup(
        children: [
          UtenButton(
            key: const Key('finance-shipment-audit-reject-reverse-btn'),
            size: UtenButtonSize.large,
            icon: Icons.settings_backup_restore_rounded,
            isLoading: _busy,
            onPressed: _rejectReverse,
            child: const Text('撤回退回'),
          ),
        ],
      );
    }
    if (!canDecide) return null;
    return UtenFloatingActionGroup(
      children: [
        if (_canReject)
          UtenButton(
            key: const Key('finance-shipment-audit-reject'),
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.reply_rounded,
            onPressed: _busy ? null : _reject,
            child: const Text('退回销售'),
          ),
        if (_canApprove)
          UtenButton(
            key: const Key('finance-shipment-audit-approve'),
            size: UtenButtonSize.large,
            isLoading: _busy,
            icon: Icons.fact_check_outlined,
            onPressed: _busy ? null : _approve,
            child: const Text('确认放行'),
          ),
      ],
    );
  }

  String _describeSnapshotValue(String key, Object? value) {
    final names = ref.read(salesMasterNameServiceProvider);
    final id = value?.toString();
    return switch (key) {
      'clientId' => names.client(id),
      'warehouseId' => names.warehouse(id),
      'currencyId' => names.currency(id),
      'goodsId' => names.goods(id),
      'goodsCode' => names.goodsInfo(id ?? '')?.code ?? '—',
      'orderItemId' =>
        _detail?.items
                .where((item) => item.orderItemId == id)
                .map((item) => item.sourceDocNo)
                .whereType<String>()
                .firstOrNull ??
            _detail?.sourceDocNo ??
            '已关联订单',
      'colorId' => names.color(id),
      'unitId' => names.unit(id),
      'sellerId' || 'senderId' => names.employee(id),
      'settlementMethodId' =>
        _settlementNames[id] ??
            (id == _detail?.settlementMethodId
                ? _info?.settlementMethodName ?? '—'
                : id ?? '—'),
      _ => value?.toString() ?? '未填写',
    };
  }

  /// 顶部状态条：单据号 + 财审状态（待审核/已放行/已退回/不可审）。
  Widget _statusStrip(
    ThemeData theme,
    SalesDocDetail d,
    ShipmentFinanceAuditInfo info,
  ) {
    final rejected = d.shipmentWorkflow.financeRejected;
    final audited = d.financeAudit == 1;
    final warehouseStarted = !salesShipmentAllowsFinanceAudit(
      d.warehouseWorkStatus,
    );
    final (type, icon, text) = audited
        ? (UtenStatusBadgeType.success, Icons.verified_rounded, '财务已放行')
        : rejected
        ? (UtenStatusBadgeType.danger, Icons.undo_rounded, '已退回销售')
        : warehouseStarted
        ? (UtenStatusBadgeType.danger, Icons.block_rounded, '仓库已出库')
        : !d.shipmentWorkflow.salesConfirmed
        ? (UtenStatusBadgeType.warning, Icons.hourglass_top_rounded, '待销售确认')
        : (UtenStatusBadgeType.warning, Icons.pending_actions_rounded, '待财务审核');
    return Wrap(
      spacing: UtenSpacing.s4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        UtenStatusBadge(label: text, type: type, icon: icon),
        if (warehouseStarted)
          const UtenFieldHintIcon(
            key: ValueKey('shipment-outbound-review-hint'),
            errorMessage: '仓库已确认出库，不能补做或撤销财务审核；纠错请走销售退货。',
          ),
      ],
    );
  }

  /// 客户财务快照卡：审核必看的本单结账方式、应收、铺底与可用预收。
  /// ADR-128：应收与可用预收按本单币种显示(财务共用 FinancePartySnapshotCard)；
  /// 铺底额只和全部币种正式应收(折本币，不扣预收)比，超出时标红。
  Widget _clientFinanceCard(ThemeData theme, ShipmentFinanceAuditInfo info) =>
      FinancePartySnapshotCard(
        embedded: true,
        showTitle: false,
        showLeading: false,
        title: '客户资金（辅助）',
        balance: info.clientBalance,
        limitLabel: '铺底额',
      );

  void _openAuditReferences() {
    setState(() {
      _referencesExpanded = true;
      ++_referenceScrollRequest;
    });
  }

  Widget _auditReferences(ThemeData theme, SalesDocDetail d) {
    if (!_hasReviewPermission(Perm.salesShipmentFinanceView)) {
      return const SizedBox.shrink();
    }
    final info = _info!;
    final frozen = info.frozenReceivablePosition;
    Widget groupTitle(String title, String hint) => Padding(
      padding: const EdgeInsets.only(
        top: UtenSpacing.s16,
        bottom: UtenSpacing.s8,
      ),
      child: Row(
        children: [
          Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
          UtenFieldHintIcon(info: hint),
        ],
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: UtenCollapsibleSection(
          key: const ValueKey('shipment-audit-reference-section'),
          title: '审核资料与参考',
          expanded: _referencesExpanded,
          initiallyExpanded: false,
          onExpandedChanged: (next) =>
              setState(() => _referencesExpanded = next),
          titleTrailing: const UtenFieldHintIcon(
            info:
                '审核记录、客户累计与订单资金仅供核对。当前本批货款、已收、还欠以上方主板为准。展开此区不会自动读取客户到账参考。${BusinessAttachmentSection.kReviewReadOnlyAttachmentNote}',
          ),
          child: !_referencesExpanded
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_isFreeShipment)
                      UtenSummaryField(
                        label:
                            '主档参考汇率${info.currencyName == null ? '' : '(${financeCurrencyText(name: info.currencyName)})'}',
                        value: _rateLocked
                            ? '1(本位币)'
                            : info.financeRateReady == false
                            ? '未维护'
                            : info.financeRate ?? '—',
                        info: '主档仅作预填参考；本次审核按下方记账汇率核对，已放行单据保留审核时汇率。',
                      ),
                    if (!_isFreeShipment) _exchangeRateSection(theme, info),
                    const SizedBox(height: UtenSpacing.s12),
                    UtenSummaryFacts(
                      inline: true,
                      children: [
                        if (frozen != null)
                          UtenSummaryField(
                            label: '当时审核记录',
                            value: frozen.ready
                                ? shipmentDebtLabel(frozen)
                                : frozen.unavailableLabel,
                            info: '财务放行当时冻结的本批依据；后续收款不改历史，当前还欠看上方主板。',
                          ),
                        if (d.financeAuditedAt != null)
                          UtenSummaryField(
                            label: '审核时间',
                            value: d.financeAuditedAt,
                          ),
                        if (d.financeAudit == 1)
                          UtenSummaryField(
                            label: '审核人',
                            value: d.financeAuditorName?.isNotEmpty == true
                                ? d.financeAuditorName
                                : '历史未留姓名快照',
                          ),
                        UtenSummaryField(
                          label: '仓库',
                          value: ref
                              .read(salesMasterNameServiceProvider)
                              .warehouse(d.warehouseId),
                        ),
                        UtenSummaryField(label: '制单员', value: d.makerName),
                        if (d.createdAt != null)
                          UtenSummaryField(
                            label: '制单时间',
                            value: utenFmtIsoTime(d.createdAt),
                          ),
                        if (d.logisticsNo?.isNotEmpty == true)
                          UtenSummaryField(label: '物流单号', value: d.logisticsNo),
                        if (d.shipAddr?.isNotEmpty == true)
                          UtenSummaryField(label: '收货地址', value: d.shipAddr),
                        if (d.remark?.isNotEmpty == true)
                          UtenSummaryField(label: '备注', value: d.remark),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    _attachments(theme, d),
                    ShipmentFinanceChangeSummary(
                      previous: info.previousCommercialSnapshot,
                      current: info.commercialSnapshot,
                      describe: _describeSnapshotValue,
                    ),
                    if (info.clientBalance != null) ...[
                      groupTitle(
                        '客户资金（辅助）',
                        '结款方式来自本单。客户应收与预收按本单币种原币核对，可用预收只算已审核到账的预收；客户累计不能冒充本批已收或还欠。',
                      ),
                      _clientFinanceCard(theme, info),
                    ],
                    if (info.orderMoneyPositions.isNotEmpty) ...[
                      groupTitle('订单参考（辅助）', '订单含未发货计划与未抵定金，不能当作本批已收或催收依据。'),
                      for (final position in info.orderMoneyPositions.values)
                        SalesOrderMoneyPositionView(
                          value: position,
                          frozen: info.financeAudit == 1,
                        ),
                    ],
                    if (!_isFreeShipment &&
                        _hasReviewPermission(
                          Perm.salesShipmentFinanceView,
                        )) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      FinanceActualReceiptContext(
                        key: ValueKey(
                          'customer-receipt-reference-$_loadGeneration',
                        ),
                        onRead: _readCustomerReceiptReference,
                      ),
                    ],
                    if (d.shipmentWorkflow.financeRejected)
                      _rejectRecordCard(theme, d),
                  ],
                ),
        ),
      ),
    );
  }

  /// V632 记账汇率区：待审时可填(预填主档参考汇率/本位币锁 1)，已决策时只读展示冻结值。
  Widget _exchangeRateSection(ThemeData theme, ShipmentFinanceAuditInfo info) {
    final currency = financeCurrencyText(name: info.currencyName);
    final decided =
        (_detail?.financeAudit ?? info.financeAudit) == 1 ||
        _detail?.shipmentWorkflow.financeRejected == true;
    if (decided) {
      final frozen = info.shipmentExchangeRate?.trim();
      return UtenSummaryField(
        key: const Key('finance-audit-rate-frozen'),
        label: '审核时汇率',
        value: frozen == null || frozen.isEmpty ? '未冻结' : frozen,
        info: frozen == null || frozen.isEmpty
            ? '原放行记录未冻结汇率，后续业务按原记录及记账依据核对，不在这里补造审时值。'
            : '已冻结记账汇率 $frozen：1 $currency = $frozen 本币；仓库确认出库按此汇率折算本币立应收。',
      );
    }
    final hint = _rateLocked
        ? '本位币汇率固定为 1，无需填写。'
        : _masterRateMissing
        ? '币种主档没有参考汇率，请按放行当日汇率填写；到 基础资料→币种 维护参考汇率后，以后会自动预填。'
        : '已按币种主档参考汇率预填，可按放行当日汇率修改；放行即冻结到本单，仓库确认出库按它折算本币立应收。';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenFormGrid(
          children: [
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _rateController,
              builder: (context, value, _) {
                final preview = _localAmountPreview();
                return TextField(
                  key: const Key('finance-audit-exchange-rate'),
                  controller: _rateController,
                  readOnly: _rateLocked,
                  enabled: !_busy,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) {
                    if (_rateError != null) setState(() => _rateError = null);
                  },
                  // 说明文案走 UtenInputDecoration 的 info(裸 helperText 被
                  // uten_field_message_source_contract_test 禁止)。
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: '记账汇率(1 $currency = ? 本币)',
                      error: utenFieldError(_rateError, maxLines: 2),
                    ),
                    info: preview == null
                        ? hint
                        : '本单折合本币约 $preview(参考值)。$hint',
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  /// 出货信息卡：与销售端详情同规则的只读商业事实（币种红色加粗）。
  Widget _shipmentCard(ThemeData theme, SalesDocDetail d) {
    final names = ref.watch(salesMasterNameServiceProvider);
    final info = _info!;
    final revised =
        readableShipmentReviewSnapshot(info.previousCommercialSnapshot) &&
        readableShipmentReviewSnapshot(info.commercialSnapshot);
    return UtenDetailSummaryCard(
      key: const ValueKey('shipment-document-main-panel'),
      heading: Wrap(
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (revised) const Text('出货单修改'),
          Text(d.billNo ?? '未编号出货'),
          Text(
            info.clientName ?? names.client(d.clientId),
            style: theme.textTheme.titleSmall,
          ),
        ],
      ),
      status: Wrap(
        spacing: UtenSpacing.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _statusStrip(theme, d, info),
          TextButton.icon(
            key: const ValueKey('detail-summary-toggle'),
            onPressed: _openAuditReferences,
            icon: const Icon(Icons.more_horiz_rounded, size: 18),
            label: const Text('更多资料'),
          ),
        ],
      ),
      primary: [
        if (_currentMoney == null)
          UtenSummaryField(
            label: '货款',
            value: d.shipmentWorkflow.isFree
                ? '不收费'
                : d.priceMasked
                ? '***'
                : financeMoneyWithUnitSuffix(
                    d.exactDecimals['totalOriginal'] ??
                        d.totalOriginal?.toString(),
                    currencyName: names.currency(d.currencyId),
                    fullCurrencyName: true,
                  ),
          ),
      ],
      facts: [
        UtenSummaryField(label: '出货日期', value: d.billDate),
        UtenSummaryField(
          label: '结款方式',
          value: info.settlementMethodName ?? '未设置',
        ),
        UtenSummaryField(
          label: '仓库作业',
          value: salesWarehouseWorkStatusLabel(d.warehouseWorkStatus),
        ),
        if (d.sourceDocNo?.isNotEmpty == true)
          UtenSummaryField(label: '来源订单', value: d.sourceDocNo),
        if (info.billingMode != null)
          UtenSummaryField(
            label: '本次发货',
            value: info.billingMode == 'FREE' ? '不收费' : '收费',
          ),
      ],
      sections: [
        if (_hasReviewPermission(Perm.salesShipmentFinanceView))
          if (_currentMoney case final position?)
            ShipmentReceivablePositionView(value: position),
      ],
    );
  }

  /// 出货明细：全局统一表格（嵌入模式），价格脱敏时金额打码。
  Widget _itemsCard(ThemeData theme, SalesDocDetail d) {
    final names = ref.watch(salesMasterNameServiceProvider);
    final masked = d.priceMasked;
    final items = d.items;
    final before = _info?.previousCommercialSnapshot;
    final after = _info?.commercialSnapshot;
    final hasComparison =
        readableShipmentReviewSnapshot(before) &&
        readableShipmentReviewSnapshot(after);
    // 2026-09-24：明细标题已上移折叠头（见 _itemsTitle），body 只剩表格。
    return hasComparison
        ? ShipmentFinanceChangeTable(
            previous: before!,
            current: after!,
            describe: _describeSnapshotValue,
            embedded: false,
            primary: true,
            priceMasked: masked,
            bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
            summaryBar: _auditReferences(theme, d),
            scrollToEndRequest: _referenceScrollRequest,
          )
        : MasterDataTableView<SalesDocItem>(
            summaryBar: _auditReferences(theme, d),
            summaryBarInline: d.items.isNotEmpty,
            scrollToEndRequest: _referenceScrollRequest,
            expensiveRowMounts: false,
            tableKey:
                'features.finance.pages.finance_sales_shipment_audit_review_page.FinanceSalesShipmentAuditReviewPageState._itemsCard.1',
            primary: true,
            bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
            // 行勾选（2026-10-10 审核页防看岔行口径）：纯阅读辅助，单选互斥
            // （点其他行自动换选、再点取消），无行级批量动作，整单决策仍走底部
            // 退回/放行；选中态由行高亮表达，不画勾选框列也不驻「已选」胶囊。
            selectable: true,
            showSelectionColumn: false,
            singleSelection: true,
            showSelectionSummary: false,
            idOf: (it) => (it.id == null || it.id!.isEmpty) ? null : it.id,
            selectedIds: _selectedItemIds,
            onSelectedIdsChanged: (next) => setState(() {
              _selectedItemIds
                ..clear()
                ..addAll(next);
            }),
            columns: [
              MasterColumnDef(
                key: 'goods',
                // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
                label: '货品名称',
                width: 200,
                value: (it) => salesGoodsNameLabel(it, names.goods(it.goodsId)),
              ),
              MasterColumnDef<SalesDocItem>(
                key: 'nameEn',
                label: '英文名称',
                width: 180,
                value: (item) => item.goodsNameEn,
              ),
              MasterColumnDef(
                key: 'goodsCode',
                label: '编号',
                width: 130,
                value: (it) => UtenGoodsAttributeCell.text(
                  salesGoodsCodeLabel(
                    it,
                    fallbackCode: names.goodsInfo(it.goodsId)?.code,
                  ),
                ),
                cellBuilder: (_, it) => UtenGoodsAttributeCell(
                  salesGoodsCodeLabel(
                    it,
                    fallbackCode: names.goodsInfo(it.goodsId)?.code,
                  ),
                ),
              ),
              MasterColumnDef(
                key: 'colorName',
                label: '颜色',
                width: 96,
                value: (it) => names.color(it.colorId),
              ),
              MasterColumnDef(
                key: 'stockPlace',
                label: '库位号',
                width: 90,
                value: (it) => names.goodsInfo(it.goodsId)?.stockPlace ?? '—',
              ),
              // 2026-10-10「数量+单位」全站口径：单位内联在数字后（12 PCS），
              // 独立「单位」列退役。
              MasterColumnDef(
                key: 'qty',
                label: '数量',
                width: 125,
                type: 'number',
                value: (it) => formatExactQtyWithUnit(
                  it.exactDecimals['qty'] ?? it.qty?.toString(),
                  names.unit(it.unitId),
                ),
              ),
              // 金额自动带订单币种后缀（2026-10-10 口径）；价格脱敏时金额打码。
              MasterColumnDef(
                key: 'price',
                label: '单价',
                width: 140,
                type: 'money',
                value: (it) => masked
                    ? '***'
                    : financeMoneyWithUnitSuffix(
                        it.exactDecimals['price'] ?? it.price?.toString(),
                        currencyName: names.currency(d.currencyId),
                      ),
              ),
              MasterColumnDef(
                key: 'amount',
                label: '总金额',
                width: 140,
                type: 'money',
                value: (it) => masked
                    ? '***'
                    : financeMoneyWithUnitSuffix(
                        it.exactDecimals['amountOriginal'] ??
                            it.amountOriginal?.toString(),
                        currencyName: names.currency(d.currencyId),
                      ),
              ),
              MasterColumnDef(
                key: 'currency',
                label: '币种',
                width: 90,
                value: (_) => names.currency(d.currencyId),
              ),
              MasterColumnDef(
                key: 'remark',
                label: '备注',
                width: 160,
                value: (it) =>
                    (it.remark?.isNotEmpty ?? false) ? it.remark : null,
              ),
              ...businessReadOnlyColumns<SalesDocItem>(
                items,
                columnsOf: (item) => item.extraColumns,
              ),
            ],
            items: items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            emptyMessage: '(无明细)',
          );
  }

  /// 明细标题——2026-09-25 起纯计数「出货明细(N)」退役，仅修订对比态返回标题。
  String? _itemsTitle(SalesDocDetail d) {
    final before = _info?.previousCommercialSnapshot;
    final after = _info?.commercialSnapshot;
    final hasComparison =
        readableShipmentReviewSnapshot(before) &&
        readableShipmentReviewSnapshot(after);
    return hasComparison ? '出货明细 · 修改对比' : null;
  }

  Widget _attachments(ThemeData theme, SalesDocDetail d) {
    final permissions = ref.watch(currentPermissionsProvider);
    final salesConfirmed = d.shipmentWorkflow.salesConfirmed;
    return BusinessAttachmentSection(
      ownerType: 'SALES_SHIPMENT',
      ownerId: d.id,
      // 审核页一律只读（2026-09-11 口径）：文件以提交时那一份为准。
      canView:
          !d.priceMasked &&
          (permissions.contains(Perm.salesShipmentView) ||
              (permissions.contains(Perm.salesShipmentFinanceView) &&
                  (salesConfirmed ||
                      d.shipmentWorkflow.financeRejected ||
                      d.financeAudit == 1 ||
                      d.status == 1))),
      canManage: false,
      showBusyOverlay: true,
      categories: const ['合同', '客户确认', '图片', '其他'],
    );
  }

  /// 退回记录卡：原因 + 时间（与订单审核页同款）。
  Widget _rejectRecordCard(ThemeData theme, SalesDocDetail d) {
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
                    '退回记录',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(d.shipmentWorkflow.financeRejectionReason ?? '未注明原因'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
