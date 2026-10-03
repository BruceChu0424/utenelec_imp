import '../../../shared/platform_tables/platform_table_binding.dart';
import '../../../shared/business_columns/business_columns_table.dart';
// 销售报价财务核价详情(/finance/quote-review/:id，ADR-134)。
//
// 「销售不能改价」的落地：报价行单价只来自货品资料标价，财务在这里逐行定成交单价/折扣；
// 低于标价的成交单价一律折成 4 位折扣，只有没有标价(空/0)或高于标价时才由财务直接定价
// (0 = 赠品/0价，须显式选择)；确认后销售才能转订货单，订货单沿用这里核定的单价与折扣且锁定不可改。
//
// 页面结构(对齐销售订单财务审核页 V300 与出货财审专页)：
//   · 认领：服务端 financeActions 里有改价/退回/确认才认领 SALES_QUOTE_FINANCE_REVIEW；
//     认领不成功只读，心跳失败立即暂停决策，每个动作提交前再续租核对同一 claimId。
//     撤销确认(已核价 → 待核价)不认领：服务端只接受待核价报价的认领，撤销成功后整页重载再认领；
//   · 状态条 + 重新提交提醒 + 待定价提醒(可跳货品资料维护标价，按服务端能力位显示，
//     返回后重读本页并保留没保存的修改)；
//   · 报价信息卡(有效期/结账方式/财务备注可改，保存时整体提交)、客户文件附件(只读)、核价记录；
//   · 明细表：成交单价 ↔ 折扣联动预览(与服务端同一取位规则)、勾选多行批量设折扣
//     (勾选行里改折扣 = 对全部勾选行生效)、行菜单 按标价打折/按最新标价刷新/赠品/撤销；
//   · 右下悬浮：保存修改 / 退回销售(原因必填，快捷选项) / 确认报价 / 撤销确认再修改，
//     只按服务端 financeActions 显示；处理中屏幕中央遮罩。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/data_display/uten_revision_table.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../sales/models/sales_doc.dart';
import '../../sales/providers/master_name_provider.dart';
import '../../sales/widgets/sales_quote_status_chip.dart';
import '../models/quote_finance_line_draft.dart';
import '../models/quote_finance_pricing.dart';
import '../models/sales_quote_finance_review.dart';
import '../repositories/sales_quote_finance_review_repository.dart';
import '../widgets/quote_finance_dialogs.dart';
import 'finance_quote_review_list_page.dart';

class FinanceQuoteReviewPage extends ConsumerStatefulWidget {
  const FinanceQuoteReviewPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<FinanceQuoteReviewPage> createState() =>
      _FinanceQuoteReviewPageState();
}

class _FinanceQuoteReviewPageState
    extends ConsumerState<FinanceQuoteReviewPage> {
  SalesQuoteFinanceReview? _review;
  bool _loading = true;
  bool _busy = false;
  String? _busyTitle;
  String? _error;

  TaskClaimSession? _claim;
  int _loadGeneration = 0;

  final Map<String, QuoteFinanceLineDraft> _drafts = {};
  final Set<String> _selected = <String>{};

  DateTime? _validUntil;
  String? _settlementId;
  final _financeRemark = TextEditingController();
  List<UtenDropdownItem> _settlementItems = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant FinanceQuoteReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) _load();
  }

  @override
  void dispose() {
    ++_loadGeneration;
    _claim?.removeListener(_claimChanged);
    _claim?.releaseAll().ignore();
    _disposeDrafts();
    _financeRemark.dispose();
    super.dispose();
  }

  void _claimChanged() {
    if (mounted) setState(() {});
  }

  void _disposeDrafts() {
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    _drafts.clear();
  }

  SalesQuoteFinanceReviewRepository get _repo =>
      ref.read(salesQuoteFinanceReviewRepositoryProvider);

  bool get _claimReady => _claim?.isReady == true;

  bool _allows(SalesQuoteFinanceAction action) =>
      _review?.allows(action) ?? false;

  /// 能改价：服务端允许 + 本人认领有效。
  bool get _editable => _allows(SalesQuoteFinanceAction.edit) && _claimReady;

  bool get _headerDirty {
    final review = _review;
    if (review == null) return false;
    return _dateText(_validUntil) != review.validUntil ||
        _settlementId != review.settlementMethodId ||
        _financeRemark.text.trim() != (review.financeRemark ?? '');
  }

  bool get _dirty => _headerDirty || _drafts.values.any((d) => d.dirty);

  // ---------------------------------------------------------------- load

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final container = ProviderScope.containerOf(context, listen: false);
    final identity = container.read(sessionProvider);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _claim?.removeListener(_claimChanged);
      await _claim?.releaseAll();
      _claim = null;
      if (!mounted || generation != _loadGeneration) return;
      var review = await _repo.review(widget.id);
      if (!mounted || generation != _loadGeneration) return;
      // 只有能改价/退回/确认时才占用；撤销确认、已办结或无权的都不占认领
      // (已核价的报价服务端拒绝认领，撤销确认本身也不要求认领)。
      if (review.needsClaim) {
        final claim = financeReviewClaim(container)..addListener(_claimChanged);
        _claim = claim;
        await claim.claimAll(kSalesQuoteFinanceClaimType, [widget.id]);
        if (!mounted || generation != _loadGeneration || !claim.isCurrent) {
          await claim.releaseAll();
          return;
        }
        if (claim.isReady) {
          // 占用之后重读：页面展示的是占用生效后的内容，之后别人改不动它。
          review = await _repo.review(widget.id);
          if (!mounted || generation != _loadGeneration) return;
        }
      }
      if (!identical(container.read(sessionProvider), identity)) return;
      _applyReview(review);
      setState(() => _loading = false);
      unawaited(_loadSettlementMethods(generation));
    } on ApiException catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = AppLocalizations.of(context).quoteFinanceLoadDetailFailed;
        _loading = false;
      });
    }
  }

  /// 用服务端最新详情重建编辑状态(保存/撤销确认后也走这里)。
  void _applyReview(SalesQuoteFinanceReview review) {
    _disposeDrafts();
    for (final line in review.lines) {
      _drafts[line.itemId] = QuoteFinanceLineDraft(line);
    }
    _selected.removeWhere((id) => !_drafts.containsKey(id));
    _applyHeader(review);
    _review = review;
  }

  void _applyHeader(SalesQuoteFinanceReview review) {
    _validUntil = DateTime.tryParse(review.validUntil ?? '');
    _settlementId = review.settlementMethodId;
    _financeRemark.text = review.financeRemark ?? '';
  }

  /// 从货品资料页回来后重读(标价可能刚维护过)：没改的行按最新内容重建，
  /// 改过的行与表头保留页面上的修改，不悄悄丢掉；版本变了(别人动过)才整页重建。
  Future<void> _reloadKeepingEdits() async {
    final generation = _loadGeneration;
    final SalesQuoteFinanceReview latest;
    try {
      latest = await _repo.review(widget.id);
    } catch (_) {
      return; // 重读失败保持原样，页面仍可保存/确认(服务端再按最新状态核对)。
    }
    if (!mounted || generation != _loadGeneration) return;
    final current = _review;
    setState(() {
      if (current == null || current.reviewRevision != latest.reviewRevision) {
        _applyReview(latest);
        return;
      }
      final kept = <String, QuoteFinanceLineDraft>{};
      for (final entry in _drafts.entries) {
        if (entry.value.dirty) {
          kept[entry.key] = entry.value;
        } else {
          entry.value.dispose();
        }
      }
      _drafts.clear();
      for (final line in latest.lines) {
        _drafts[line.itemId] =
            kept.remove(line.itemId) ?? QuoteFinanceLineDraft(line);
      }
      for (final orphan in kept.values) {
        orphan.dispose();
      }
      _selected.removeWhere((id) => !_drafts.containsKey(id));
      if (!_headerDirty) _applyHeader(latest);
      _review = latest;
    });
  }

  Future<void> _loadSettlementMethods(int generation) async {
    try {
      final rows = await ref
          .read(salesMasterNameServiceProvider)
          .dictionaries
          .load(ApiEndpoints.settlementMethods);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _settlementItems = [
          for (final row in rows)
            if (row['id'] != null)
              UtenDropdownItem(
                value: row['id'].toString(),
                label: row['name']?.toString() ?? '—',
              ),
        ];
      });
    } catch (_) {
      // 字典取不到时只显示当前结账方式名称，不阻断核价。
    }
  }

  // ------------------------------------------------------------- actions

  Future<bool> _ensureClaim(AppLocalizations l10n) async {
    final claim = _claim;
    if (claim == null || !claim.isReady) {
      context.appWarning(
        claim?.failureMessage ?? l10n.quoteFinanceClaimNotReady,
      );
      return false;
    }
    final ok = await claim.validateForDecision();
    if (!ok && mounted) {
      context.appWarning(
        claim.failureMessage ?? l10n.quoteFinanceClaimNotReady,
      );
    }
    return ok && mounted;
  }

  String? _claimId() =>
      _claim?.claimIdFor(kSalesQuoteFinanceClaimType, widget.id);

  void _setBusy(bool value, [String? title]) {
    if (!mounted) return;
    setState(() {
      _busy = value;
      _busyTitle = value ? title : null;
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final review = _review;
    if (review == null || _busy) return;
    if (_drafts.values.isNotEmpty &&
        _drafts.values.every((line) => line.removed)) {
      context.appWarning('报价至少保留一条明细；无法成交请退回销售取消报价');
      return;
    }
    // 填错的行(dirty 含 error)先挡住：保存别的行时不能悄悄丢掉它。
    final invalid = _drafts.values.where((d) => d.dirty && !d.valid).length;
    if (invalid > 0) {
      context.appWarning(l10n.quoteFinanceFixErrors(invalid));
      return;
    }
    final lines = [for (final draft in _drafts.values) ?draft.toEdit()];
    if (lines.isEmpty && !_headerDirty) {
      context.appInfo(l10n.quoteFinanceNothingToSave);
      return;
    }
    if (!await _ensureClaim(l10n)) return;
    _setBusy(true, l10n.quoteFinanceSaving);
    try {
      final updated = await _repo.saveEdits(
        widget.id,
        expectedRevision: review.reviewRevision,
        expectedClaimId: _claimId()!,
        // 表头是整体状态：总是带上页面当前值(空 = 清空)，只改行时也不会冲掉有效期/结账方式/备注。
        header: SalesQuoteFinanceHeader(
          validUntil: _dateText(_validUntil),
          settlementMethodId: _settlementId,
          financeRemark: _financeRemark.text,
        ),
        lines: lines,
      );
      if (!mounted) return;
      setState(() => _applyReview(updated));
      context.appSuccess(l10n.quoteFinanceSaved);
    } on ApiException catch (e) {
      if (mounted) context.appApiError(e);
    } catch (_) {
      if (mounted) context.appError(l10n.quoteFinanceActionFailed);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _confirm() async {
    final l10n = AppLocalizations.of(context);
    final review = _review;
    if (review == null || _busy) return;
    if (_dirty) {
      context.appWarning(l10n.quoteFinanceSaveFirst);
      return;
    }
    final blocked = review.lines.where((l) => l.needsFinancePrice).length;
    if (blocked > 0) {
      context.appWarning(l10n.quoteFinanceConfirmBlocked(blocked));
      return;
    }
    final claim = _claim;
    if (claim == null || !claim.isReady) {
      context.appWarning(l10n.quoteFinanceClaimNotReady);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.quoteFinanceConfirmTitle(review.billNo)),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UtenReviewerResponsibilityNotice(
                actionLabel: l10n.quoteFinanceConfirmResponsibility,
                description: l10n.quoteFinanceConfirmResponsibilityDesc,
                compact: true,
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(l10n.quoteFinanceConfirmBody),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                l10n.quoteFinanceConfirmTotal(_money(review.totalOriginal)),
                key: const Key('quote-finance-confirm-total'),
                style: Theme.of(dialogContext).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Theme.of(dialogContext).colorScheme.error,
                ),
              ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.quoteFinanceCancel),
          ),
          FinanceReviewClaimButton(
            key: const Key('quote-finance-confirm-submit'),
            claim: claim,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.quoteFinanceActionConfirm),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _decide(
      l10n,
      success: l10n.quoteFinanceConfirmedDone,
      call: (claimId) => _repo.confirm(
        widget.id,
        expectedRevision: review.reviewRevision,
        expectedClaimId: claimId,
      ),
    );
  }

  Future<void> _returnToSales() async {
    final l10n = AppLocalizations.of(context);
    final review = _review;
    final claim = _claim;
    if (review == null || _busy) return;
    if (claim == null || !claim.isReady) {
      context.appWarning(l10n.quoteFinanceClaimNotReady);
      return;
    }
    final reason = await showQuoteFinanceReturnDialog(
      context,
      billNo: review.billNo,
      claim: claim,
    );
    if (reason == null || !mounted) return;
    await _decide(
      l10n,
      success: l10n.quoteFinanceReturnedDone,
      call: (claimId) => _repo.returnToSales(
        widget.id,
        expectedRevision: review.reviewRevision,
        expectedClaimId: claimId,
        reason: reason,
      ),
    );
  }

  /// 确认 / 退回：提交前续租核对，成功后刷新徽章与队列并带 true 返回。
  Future<void> _decide(
    AppLocalizations l10n, {
    required String success,
    required Future<void> Function(String claimId) call,
  }) async {
    if (!await _ensureClaim(l10n)) return;
    _setBusy(true, l10n.quoteFinanceBusy);
    try {
      await call(_claimId()!);
      if (!mounted) return;
      context.appSuccess(success);
      refreshBadges(ref);
      bumpListRefresh(ref, kQuoteFinanceListRefreshKey);
      await _claim?.releaseAll();
      _setBusy(false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      _close(true);
    } on ApiException catch (e) {
      if (mounted) context.appApiError(e);
    } catch (_) {
      if (mounted) context.appError(l10n.quoteFinanceActionFailed);
    } finally {
      _setBusy(false);
    }
  }

  /// 撤销确认再修改(已核价 → 待核价)：SPEC §6.2 不要求认领，只带看到的版本号；
  /// 成功后整页重载——报价回到待核价，重载时按常规认领后才能改价。
  Future<void> _reopen() async {
    final l10n = AppLocalizations.of(context);
    final review = _review;
    if (review == null || _busy) return;
    final ok = await UtenDialog.show(
      context,
      title: l10n.quoteFinanceReopenTitle,
      content: Text(l10n.quoteFinanceReopenBody),
      confirmLabel: l10n.quoteFinanceActionReopen,
      cancelLabel: l10n.quoteFinanceCancel,
    );
    if (ok != true || !mounted) return;
    _setBusy(true, l10n.quoteFinanceBusy);
    var reopened = false;
    try {
      await _repo.reopen(widget.id, expectedRevision: review.reviewRevision);
      reopened = true;
      if (!mounted) return;
      refreshBadges(ref);
      bumpListRefresh(ref, kQuoteFinanceListRefreshKey);
      context.appSuccess(l10n.quoteFinanceReopenedDone);
    } on ApiException catch (e) {
      if (mounted) context.appApiError(e);
    } catch (_) {
      if (mounted) context.appError(l10n.quoteFinanceActionFailed);
    } finally {
      _setBusy(false);
    }
    if (reopened && mounted) await _load();
  }

  Future<void> _leave() async {
    final l10n = AppLocalizations.of(context);
    if (_dirty) {
      final ok = await UtenDialog.show(
        context,
        title: l10n.quoteFinanceUnsavedTitle,
        content: Text(l10n.quoteFinanceUnsavedBody),
        confirmLabel: l10n.quoteFinanceLeave,
        cancelLabel: l10n.quoteFinanceStay,
        danger: true,
      );
      if (ok != true || !mounted) return;
    }
    await _claim?.releaseAll();
    if (!mounted) return;
    _close(false);
  }

  void _close(bool changed) {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop(changed);
    } else {
      context.go(RouteName.financeQuoteReview);
    }
  }

  // --------------------------------------------------------- line editing

  void _onDealChanged(QuoteFinanceLineDraft draft, String text) {
    setState(() {
      draft.onDealChanged(text);
      if (draft.error == null) draft.price.text = draft.effectivePrice ?? '';
    });
  }

  /// 改折扣：本行已勾选且还勾了别的行 → 一并改全部勾选行(可按标价打折的行)。
  void _onDiscountChanged(QuoteFinanceLineDraft draft, String text) {
    setState(() {
      draft.onDiscountChanged(text);
      if (_selected.contains(draft.itemId) && _selected.length > 1) {
        for (final id in _selected) {
          final other = _drafts[id];
          if (other == null || identical(other, draft)) continue;
          if (!other.discountEditable) continue;
          other.discount.text = text;
          other.onDiscountChanged(text);
        }
      }
    });
  }

  Future<void> _batchDiscount() async {
    final l10n = AppLocalizations.of(context);
    if (_selected.isEmpty) {
      context.appWarning(l10n.quoteFinanceBatchNeedSelection);
      return;
    }
    final discount = await showQuoteFinanceBatchDiscountDialog(
      context,
      count: _selected.length,
    );
    if (discount == null || !mounted) return;
    var applied = 0;
    var skipped = 0;
    setState(() {
      for (final id in _selected) {
        final draft = _drafts[id];
        if (draft == null || !draft.discountEditable) {
          skipped++;
          continue;
        }
        draft.discount.text = financeTrim(discount);
        draft.onDiscountChanged(draft.discount.text);
        applied++;
      }
    });
    context.appSuccess(l10n.quoteFinanceBatchApplied(applied));
    if (skipped > 0) context.appInfo(l10n.quoteFinanceBatchSkipped(skipped));
  }

  /// 去货品资料维护标价；回来后重读，最新标价才能在行菜单「按最新标价刷新」里用上。
  Future<void> _openGoods(String goodsId) async {
    await context.push(RoutePath.basicinfoGoodsDetail(goodsId));
    if (!mounted) return;
    await _reloadKeepingEdits();
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    ref.listen(sessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      ++_loadGeneration;
      _claim?.removeListener(_claimChanged);
      _claim?.releaseAll().ignore();
      _claim = null;
      if (mounted) {
        setState(() {
          _review = null;
          _loading = false;
          _error = l10n.quoteFinanceSessionChanged;
        });
      }
    });
    final review = _review;
    return PopScope(
      canPop: !_dirty && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _leave();
      },
      child: Scaffold(
        appBar: UtenAppBar(
          title: l10n.quoteFinanceReviewTitle,
          leading: UtenBackButton(onPressed: _busy ? null : _leave),
        ),
        body: SafeArea(
          child: Stack(
            children: [
              if (_loading)
                const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              else if (_error != null || review == null)
                _errorView(l10n)
              else
                UtenContentContainer(
                  child: UtenCollapsingHeaderScrollView(
                    collapsingHeader: Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      child: _header(context, l10n, review),
                    ),
                    body: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        UtenSpacing.s12,
                        0,
                        UtenSpacing.s12,
                        UtenFloatingActionGroup.controlHeight + UtenSpacing.s32,
                      ),
                      child: _linesTable(context, l10n, review),
                    ),
                  ),
                ),
              if (_busy)
                Positioned.fill(
                  child: UtenBusyOverlay(
                    title: _busyTitle ?? l10n.quoteFinanceBusy,
                  ),
                ),
            ],
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: review == null || _loading
            ? null
            : _floatingActions(l10n, review),
      ),
    );
  }

  Widget _errorView(AppLocalizations l10n) => Center(
    child: Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error ?? l10n.quoteFinanceLoadDetailFailed,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.refresh_rounded,
            onPressed: _load,
            child: Text(l10n.quoteFinanceRetry),
          ),
        ],
      ),
    ),
  );

  Widget _header(
    BuildContext context,
    AppLocalizations l10n,
    SalesQuoteFinanceReview review,
  ) {
    final theme = Theme.of(context);
    final needPrice = review.lines.where((l) => l.needsFinancePrice).toList();
    // 「标黄的行」提醒只在有上次确认折扣可对照时出现(退回后重新提交没有可对照的折扣)。
    final resubmitted = review.lines.any(
      (l) => l.lastFinanceConfirmedDiscount != null,
    );
    final permissions = ref.watch(currentPermissionsProvider);
    final compact = MediaQuery.sizeOf(context).width < 700;
    final maintainPrice =
        needPrice.isNotEmpty &&
            review.canMaintainGoodsPrice &&
            needPrice.first.goodsId != null
        ? TextButton.icon(
            key: const Key('quote-finance-maintain-price'),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(l10n.quoteFinanceGoMaintainPrice),
            onPressed: () => _openGoods(needPrice.first.goodsId!),
          )
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (review.needsClaim && !_claimReady) ...[
          FinanceReviewClaimNotice(
            claim: _claim,
            onRetry: _busy ? null : _load,
          ),
          const SizedBox(height: UtenSpacing.s12),
        ],
        _statusStrip(theme, l10n, review),
        const SizedBox(height: UtenSpacing.s12),
        if (!review.hasFinanceActions) ...[
          UtenInlineNotice(message: l10n.quoteFinanceReadOnlyNotice),
          const SizedBox(height: UtenSpacing.s12),
        ],
        if (resubmitted && review.allows(SalesQuoteFinanceAction.edit)) ...[
          UtenInlineNotice(
            key: const Key('quote-finance-resubmit-notice'),
            level: UtenInlineNoticeLevel.warning,
            message: l10n.quoteFinanceResubmitNotice,
          ),
          const SizedBox(height: UtenSpacing.s12),
        ],
        if (needPrice.isNotEmpty &&
            review.allows(SalesQuoteFinanceAction.edit)) ...[
          UtenInlineNotice(
            key: const Key('quote-finance-need-price-notice'),
            level: UtenInlineNoticeLevel.error,
            message: l10n.quoteFinanceNeedPriceNotice(needPrice.length),
            trailing: compact ? null : maintainPrice,
          ),
          // 窄屏把「去货品资料维护标价」放到提示下面, 不把提示文字挤成一条窄列。
          if (compact && maintainPrice != null) ...[
            const SizedBox(height: UtenSpacing.s4),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: maintainPrice,
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
        ],
        _infoCard(theme, l10n, review),
        const SizedBox(height: UtenSpacing.s12),
        // 客户文件(销售随报价上传的报价单/形式发票)只读预览，服务端按财务读范围放行。
        BusinessAttachmentSection(
          ownerType: 'SALES_QUOTE',
          ownerId: review.quoteId,
          canView: permissions.contains(Perm.attachmentView),
          canManage: false,
          title: l10n.quoteFinanceAttachmentsTitle,
        ),
        if (review.revisions.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s12),
          SalesQuoteRevisionTimeline(
            revisions: review.revisions,
            title: l10n.quoteFinanceRevisionTitle,
          ),
        ],
        const SizedBox(height: UtenSpacing.s12),
      ],
    );
  }

  Widget _statusStrip(
    ThemeData theme,
    AppLocalizations l10n,
    SalesQuoteFinanceReview review,
  ) {
    final stage = salesQuoteStageFor(
      status: review.status,
      statusBucket: review.statusBucket,
      financeReturnReason: review.financeReturnReason,
    );
    final (color, icon, text) = switch (stage) {
      SalesQuoteStage.approved when review.convertedOrderNo != null => (
        theme.colorScheme.primary,
        Icons.verified_rounded,
        l10n.quoteFinanceStripConverted(review.convertedOrderNo!),
      ),
      SalesQuoteStage.approved => (
        theme.colorScheme.primary,
        Icons.verified_rounded,
        l10n.quoteFinanceStripConfirmed(
          review.financeConfirmedByName ?? '—',
          utenFmtIsoTime(review.financeConfirmedAt),
        ),
      ),
      SalesQuoteStage.financeRejected => (
        theme.colorScheme.error,
        Icons.undo_rounded,
        l10n.quoteFinanceStripReturned(review.financeReturnReason ?? '—'),
      ),
      SalesQuoteStage.draft => (
        theme.colorScheme.onSurfaceVariant,
        Icons.edit_note_rounded,
        l10n.quoteFinanceStripDraft,
      ),
      SalesQuoteStage.reversed => (
        theme.colorScheme.onSurfaceVariant,
        Icons.block_rounded,
        l10n.quoteFinanceStripReversed,
      ),
      _ => (
        theme.colorScheme.tertiary,
        Icons.pending_actions_rounded,
        l10n.quoteFinanceStripPending,
      ),
    };
    return Container(
      key: const Key('quote-finance-status-strip'),
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
                  review.billNo,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s2),
                Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          UtenStatusBadge(
            label: l10n.quoteFinanceRevisionBadge(review.reviewRevision),
            type: UtenStatusBadgeType.neutral,
          ),
        ],
      ),
    );
  }

  Widget _infoCard(
    ThemeData theme,
    AppLocalizations l10n,
    SalesQuoteFinanceReview review,
  ) {
    Widget kv(String label, String? value) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(child: Text((value?.isNotEmpty ?? false) ? value! : '—')),
      ],
    );
    final editable = _editable;
    final settlementItems = [
      ..._settlementItems,
      if (review.settlementMethodId != null &&
          !_settlementItems.any((i) => i.value == review.settlementMethodId))
        UtenDropdownItem(
          value: review.settlementMethodId,
          label: review.settlementMethodName ?? '—',
        ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.quoteFinanceInfoTitle,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            UtenFormGrid(
              children: [
                kv(
                  l10n.quoteFinanceFieldClient,
                  review.clientCode == null
                      ? review.clientName
                      : '${review.clientName ?? '—'}(${review.clientCode})',
                ),
                kv(l10n.quoteFinanceFieldSeller, review.sellerName),
                kv(l10n.quoteFinanceFieldMaker, review.makerName),
                kv(l10n.quoteFinanceFieldBillDate, review.billDate),
                kv(
                  l10n.quoteFinanceFieldSubmittedAt,
                  review.submittedAt == null
                      ? null
                      : utenFmtIsoTime(review.submittedAt),
                ),
                kv(l10n.quoteFinanceFieldDeliverDate, review.deliverDate),
                kv(l10n.quoteFinanceFieldContractNo, review.contractNo),
                kv(l10n.quoteFinanceFieldCurrency, review.currencyName),
                if (review.clientFileCurrency != null)
                  kv(
                    l10n.quoteFinanceFieldFileCurrency,
                    review.financeRateMissing
                        ? l10n.quoteFinanceFileRateMissing(
                            review.clientFileCurrency!,
                          )
                        : review.financeRate == null
                        ? review.clientFileCurrency
                        : l10n.quoteFinanceFileRateHint(
                            review.clientFileCurrency!,
                            financeExactTrimmed(review.financeRate) ??
                                review.financeRate!,
                          ),
                  ),
                kv(l10n.quoteFinanceFieldRemark, review.remark),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenFormGrid(
              children: [
                UtenDateField(
                  key: const Key('quote-finance-valid-until'),
                  label: l10n.quoteFinanceFieldValidUntil,
                  value: _validUntil,
                  enabled: editable,
                  onChanged: (value) => setState(() => _validUntil = value),
                ),
                UtenDropdownField(
                  key: const Key('quote-finance-settlement'),
                  label: l10n.quoteFinanceFieldSettlement,
                  value: _settlementId,
                  items: settlementItems,
                  enabled: editable,
                  hintText: l10n.quoteFinanceSettlementNone,
                  onChanged: (value) => setState(() => _settlementId = value),
                ),
                TextField(
                  key: const Key('quote-finance-remark'),
                  controller: _financeRemark,
                  enabled: editable,
                  maxLength: 500,
                  onChanged: (_) => setState(() {}),
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: l10n.quoteFinanceFieldFinanceRemark,
                      hintText: l10n.quoteFinanceFinanceRemarkHint,
                      counterText: '',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _linesTable(
    BuildContext context,
    AppLocalizations l10n,
    SalesQuoteFinanceReview review,
  ) {
    final theme = Theme.of(context);
    final editable = _editable;
    final hasFile = review.lines.any(
      (l) =>
          l.clientPrice != null ||
          l.clientModel != null ||
          l.clientGoodsName != null,
    );
    final hasLastConfirmed = review.lines.any(
      (l) => l.lastFinanceConfirmedDiscount != null,
    );
    final items = review.lines;
    final tableBinding =
        PlatformTableCatalogScope.resolve(
          context,
          PlatformTableDescriptor<SalesQuoteFinanceLine>(
            kind: 'master',
            tableKey: 'sales.quote.items',
            columnKeys: const [],
            rows: items,
          ),
        )?.copyWith(
          factValuesOf: (line) {
            final draft = _drafts[line.itemId];
            return {
              'qty': draft?.removed == true ? '0' : draft?.qty.text ?? line.qty,
              'price': draft == null ? line.storedPrice : draft.effectivePrice,
              'discount': draft == null
                  ? line.discount
                  : draft.effectiveDiscount,
              'amount': draft == null ? line.amount : draft.amountPreview,
            };
          },
          factListenablesOf: (line) {
            final draft = _drafts[line.itemId];
            return draft == null
                ? const <Listenable>[]
                : [draft.deal, draft.discount, draft.qty, draft.price];
          },
        );

    return MasterDataTableView<SalesQuoteFinanceLine>(
      tableKey: 'sales.quote.items',
      platformBinding: tableBinding,
      key: const Key('quote-finance-lines'),
      primary: true,
      bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
      selectable: editable,
      idOf: (line) => line.itemId,
      selectedIds: _selected,
      onSelectedIdsChanged: (next) => setState(() {
        _selected
          ..clear()
          ..addAll(next);
      }),
      batchActionsBuilder: editable ? (_, _) => const <Widget>[] : null,
      toolbarActions: editable
          ? [
              UtenButton(
                key: const Key('quote-finance-batch-discount'),
                type: UtenButtonType.secondary,
                icon: Icons.percent_rounded,
                onPressed: _selected.isEmpty ? null : _batchDiscount,
                onDisabledTap: () =>
                    context.appInfo(l10n.quoteFinanceBatchNeedSelection),
                child: Text(
                  _selected.isEmpty
                      ? l10n.quoteFinanceBatchDiscount
                      : l10n.quoteFinanceBatchDiscountCount(_selected.length),
                ),
              ),
            ]
          : null,
      rowColor: (line) => _rowColor(theme, line),
      rowDecorationBuilder: (context, line, child) =>
          _drafts[line.itemId]?.removed == true
          ? UtenRevisionStrike(color: theme.colorScheme.error, child: child)
          : child,
      rowMenuBuilder: editable || review.canMaintainGoodsPrice
          ? (line) => _rowMenu(l10n, review, line, editable)
          : null,
      columns: [
        // 名称用全站货品身份格(正文色), 不落成表格默认的次要灰字: 名称是核价时最先要看的一列。
        MasterColumnDef(
          key: 'goods',
          label: l10n.quoteFinanceColGoods,
          width: 200,
          value: (line) => line.goodsName ?? line.goodsCode ?? '—',
          cellBuilderHandlesSemantics: true,
          cellBuilder: (_, line) =>
              UtenGoodsIdentityCell(name: line.goodsName ?? line.goodsCode),
        ),
        MasterColumnDef<SalesQuoteFinanceLine>(
          key: 'nameEn',
          label: '英文名称',
          width: 180,
          value: (line) => line.goodsNameEn,
        ),
        MasterColumnDef(
          key: 'goodsCode',
          label: l10n.quoteFinanceColCode,
          width: 130,
          value: (line) => UtenGoodsAttributeCell.text(line.goodsCode),
          cellBuilder: (_, line) => UtenGoodsAttributeCell(line.goodsCode),
        ),
        MasterColumnDef(
          key: 'colorName',
          label: l10n.quoteFinanceColColor,
          width: 96,
          value: (line) => UtenGoodsAttributeCell.text(line.colorName),
          cellBuilder: (_, line) => UtenGoodsAttributeCell(line.colorName),
        ),
        MasterColumnDef(
          key: 'qty',
          label: l10n.quoteFinanceColQty,
          width: 90,
          type: 'number',
          value: (line) =>
              financeExactTrimmed(_drafts[line.itemId]?.qty.text ?? line.qty),
          cellBuilderHandlesSemantics: true,
          cellBuilder: (_, line) =>
              _commercialCell(line, quantity: true, editable: editable),
        ),
        MasterColumnDef(
          key: 'unitName',
          label: l10n.quoteFinanceColUnit,
          width: 80,
          value: (line) => UtenGoodsAttributeCell.text(line.unitName),
          cellBuilder: (_, line) => UtenGoodsAttributeCell(line.unitName),
        ),
        MasterColumnDef(
          key: 'price',
          label: '报价单价',
          width: 140,
          type: 'money',
          info: '仅修改本次报价单价，不更新货品资料。折扣另行填写。',
          value: (line) => _drafts[line.itemId]?.price.text ?? line.storedPrice,
          cellBuilderHandlesSemantics: true,
          cellBuilder: (_, line) =>
              _commercialCell(line, quantity: false, editable: editable),
        ),
        MasterColumnDef(
          key: 'listPrice',
          label: l10n.quoteFinanceColListPrice,
          width: 110,
          type: 'money',
          info: l10n.quoteFinanceColListPriceInfo,
          value: (line) => !line.hasListPrice
              ? l10n.quoteFinanceNoListPrice
              : line.canRefreshFromMaster
              ? l10n.quoteFinanceListPriceLatest(
                  financeExactTrimmed(line.listPrice)!,
                  financeExactTrimmed(line.currentMasterPrice)!,
                )
              : financeExactTrimmed(line.listPrice),
          cellColor: (context, line) => line.hasListPrice
              ? null
              : theme.colorScheme.errorContainer.withValues(alpha: 0.5),
        ),
        if (hasFile) ...[
          MasterColumnDef(
            key: 'clientPrice',
            label: review.clientFileCurrency == null
                ? l10n.quoteFinanceColFilePrice
                : '${l10n.quoteFinanceColFilePrice} ${review.clientFileCurrency}',
            width: 130,
            type: 'money',
            value: (line) => financeExactTrimmed(line.clientPrice),
          ),
          MasterColumnDef(
            key: 'clientPriceLocal',
            label: l10n.quoteFinanceColFilePriceLocal,
            width: 110,
            type: 'money',
            value: (line) => financeExactTrimmed(line.clientPriceLocal),
          ),
        ],
        MasterColumnDef(
          key: 'dealPrice',
          label: l10n.quoteFinanceColDealPrice,
          width: 170,
          type: 'money',
          info: l10n.quoteFinanceColDealPriceInfo,
          value: (line) => _drafts[line.itemId]?.deal.text,
          cellBuilderHandlesSemantics: true,
          cellBuilder: (context, line) =>
              _dealCell(context, l10n, line, editable),
        ),
        MasterColumnDef(
          key: 'discount',
          label: l10n.quoteFinanceColDiscount,
          width: 130,
          type: 'number',
          info: l10n.quoteFinanceColDiscountInfo,
          value: (line) => _drafts[line.itemId]?.discount.text,
          cellBuilderHandlesSemantics: true,
          cellBuilder: (context, line) =>
              _discountCell(context, l10n, line, editable),
        ),
        MasterColumnDef(
          key: 'amount',
          label: l10n.quoteFinanceColLineAmount,
          width: 130,
          type: 'money',
          value: (line) {
            // 没改的行即服务端金额，改过的行为预览(填错时为空)。
            final draft = _drafts[line.itemId];
            final amount = draft == null ? line.amount : draft.amountPreview;
            return amount == null ? '—' : _money(amount);
          },
        ),
        if (hasFile)
          MasterColumnDef(
            key: 'fileDiff',
            label: l10n.quoteFinanceColFileDiff,
            width: 130,
            type: 'money',
            info: l10n.quoteFinanceColFileDiffInfo,
            value: (line) => _fileDiffText(l10n, line),
            cellColor: (context, line) {
              final diff = _drafts[line.itemId]?.fileDifference;
              if (diff == null || isZeroDecimal(diff)) return null;
              return theme.brightness == Brightness.dark
                  ? UtenColors.warning.withValues(alpha: 0.18)
                  : UtenColors.warningBg;
            },
          ),
        if (hasLastConfirmed)
          MasterColumnDef(
            key: 'lastConfirmed',
            label: l10n.quoteFinanceColLastConfirmed,
            width: 120,
            type: 'number',
            value: (line) =>
                financeExactTrimmed(line.lastFinanceConfirmedDiscount),
          ),
        MasterColumnDef(
          key: 'salesProposed',
          label: l10n.quoteFinanceColSalesProposed,
          width: 120,
          type: 'number',
          value: (line) => financeExactTrimmed(line.salesProposedDiscount),
        ),
        if (hasFile) ...[
          MasterColumnDef(
            key: 'clientModel',
            label: l10n.quoteFinanceColFileModel,
            width: 130,
            value: (line) => line.clientModel,
          ),
          MasterColumnDef(
            key: 'clientGoodsName',
            label: l10n.quoteFinanceColFileName,
            width: 200,
            value: (line) => line.clientGoodsName,
          ),
        ],
        MasterColumnDef(
          key: 'remark',
          label: l10n.quoteFinanceColRemark,
          width: 160,
          value: (line) => line.remark,
        ),
        ...businessReadOnlyColumns<SalesQuoteFinanceLine>(
          items,
          columnsOf: (line) => line.extraColumns,
        ),
      ],
      items: items,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      emptyMessage: '—',
      summaryBar: items.isEmpty ? null : _summary(l10n, review),
      summaryBarInline: true,
    );
  }

  Color? _rowColor(ThemeData theme, SalesQuoteFinanceLine line) {
    final draft = _drafts[line.itemId];
    if (draft?.error != null) {
      return theme.colorScheme.errorContainer.withValues(alpha: 0.35);
    }
    if (draft?.differsFromLastConfirmed ?? false) {
      return theme.brightness == Brightness.dark
          ? UtenColors.warning.withValues(alpha: 0.18)
          : UtenColors.warningBg;
    }
    if (draft?.unpriced ?? line.needsFinancePrice) {
      return theme.colorScheme.errorContainer.withValues(alpha: 0.2);
    }
    return null;
  }

  /// 行菜单。没有「财务直接定成交单价」：SPEC §6.2 只允许没有标价或高于标价时财务定价，
  /// 这两种情况填成交单价时自动转为财务定价；低于标价一律折成折扣。
  List<UtenContextMenuEntry> _rowMenu(
    AppLocalizations l10n,
    SalesQuoteFinanceReview review,
    SalesQuoteFinanceLine line,
    bool editable,
  ) {
    final draft = _drafts[line.itemId];
    return [
      if (editable && draft != null) ...[
        UtenMenuItem(
          label: draft.removed ? '恢复此行' : '删除此行',
          icon: draft.removed ? Icons.undo_rounded : Icons.delete_outline,
          onTap: () => setState(() => draft.removed = !draft.removed),
        ),
        if (draft.priceEditable && draft.hasListPrice && !draft.isMaster)
          UtenMenuItem(
            label: l10n.quoteFinanceMenuMasterMode,
            icon: Icons.percent_rounded,
            onTap: () => setState(draft.useMasterPricing),
          ),
        if (line.canRefreshFromMaster && !draft.refreshing)
          UtenMenuItem(
            label: l10n.quoteFinanceMenuRefreshMaster,
            icon: Icons.sync_rounded,
            onTap: () => setState(draft.refreshFromMaster),
          ),
        if (!draft.isGiveaway)
          UtenMenuItem(
            label: l10n.quoteFinanceMenuGiveaway,
            icon: Icons.card_giftcard_rounded,
            onTap: () => setState(draft.markGiveaway),
          ),
        if (draft.dirty)
          UtenMenuItem(
            label: l10n.quoteFinanceMenuRestore,
            icon: Icons.undo_rounded,
            onTap: () => setState(draft.restore),
          ),
      ],
      if (review.canMaintainGoodsPrice && line.goodsId != null)
        UtenMenuItem(
          label: l10n.quoteFinanceGoMaintainPrice,
          icon: Icons.open_in_new_rounded,
          onTap: () => _openGoods(line.goodsId!),
        ),
    ];
  }

  String? _errorText(AppLocalizations l10n, QuoteFinanceLineError? error) =>
      switch (error) {
        QuoteFinanceLineError.dealPrice => l10n.quoteFinanceErrorDealPrice,
        QuoteFinanceLineError.financePrice =>
          l10n.quoteFinanceErrorFinancePrice,
        QuoteFinanceLineError.discount => l10n.quoteFinanceErrorDiscount,
        QuoteFinanceLineError.needPrice => l10n.quoteFinanceErrorNeedPrice,
        QuoteFinanceLineError.extraAmount => l10n.businessColumnInvalid,
        QuoteFinanceLineError.quantity => '数量须大于 0',
        null => null,
      };

  static final _decimalInput = FilteringTextInputFormatter.allow(
    RegExp(r'^\d*\.?\d*$'),
  );

  Widget _commercialCell(
    SalesQuoteFinanceLine line, {
    required bool quantity,
    required bool editable,
  }) {
    final draft = _drafts[line.itemId];
    if (draft == null) return const Text('—');
    final controller = quantity ? draft.qty : draft.price;
    if (!editable || draft.removed || (!quantity && !draft.priceEditable)) {
      return Text(controller.text, textAlign: TextAlign.right);
    }
    return TextField(
      key: ValueKey(
        'quote-finance-${quantity ? 'qty' : 'price'}-${line.itemId}',
      ),
      controller: controller,
      textAlign: TextAlign.right,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [_decimalInput],
      onChanged: (text) => setState(() {
        if (!quantity) draft.onPriceChanged(text);
      }),
      decoration: UtenInputDecoration(
        InputDecoration(
          isDense: true,
          error: quantity && draft.error == QuoteFinanceLineError.quantity
              ? const UtenFieldMessage.error('数量须大于 0')
              : !quantity &&
                    draft.directPricing &&
                    !isValidFinancePrice(controller.text)
              ? const UtenFieldMessage.error('单价须为非负数')
              : null,
        ),
      ),
    );
  }

  Widget _dealCell(
    BuildContext context,
    AppLocalizations l10n,
    SalesQuoteFinanceLine line,
    bool editable,
  ) {
    final draft = _drafts[line.itemId];
    if (draft == null) return const Text('—');
    final theme = Theme.of(context);
    // 定价方式标记(图标 + 悬停说明)：赠品 / 按最新标价刷新 / 高于标价转财务定价 / 财务定价。
    final (String? chip, IconData chipIcon) = draft.isGiveaway
        ? (l10n.quoteFinanceGiveawayChip, Icons.card_giftcard_rounded)
        : draft.refreshing
        ? (
            l10n.quoteFinanceRefreshMasterChip(
              financeExactTrimmed(line.currentMasterPrice) ?? '—',
            ),
            Icons.sync_rounded,
          )
        : draft.aboveList
        ? (l10n.quoteFinanceAboveListHint, Icons.trending_up_rounded)
        : draft.source == QuotePriceSource.finance
        ? (l10n.quoteFinanceFinancePriceChip, Icons.edit_rounded)
        : (null, Icons.edit_rounded);
    final field = editable && draft.priceEditable
        ? TextField(
            key: ValueKey('quote-finance-deal-${line.itemId}'),
            controller: draft.deal,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [_decimalInput],
            onChanged: (text) => _onDealChanged(draft, text),
            decoration: UtenInputDecoration(
              InputDecoration(
                isDense: true,
                hintText: draft.unpriced ? l10n.quoteFinanceNoListPrice : null,
                error: utenFieldError(
                  draft.error == QuoteFinanceLineError.discount
                      ? null
                      : _errorText(l10n, draft.error),
                ),
              ),
            ),
          )
        : Text(
            draft.deal.text.isEmpty
                ? l10n.quoteFinanceNoListPrice
                : _money(draft.deal.text),
            textAlign: TextAlign.right,
          );
    return Semantics(
      textField: editable,
      label:
          '${line.goodsName ?? line.goodsCode ?? ''} '
          '${l10n.quoteFinanceColDealPrice}',
      child: Row(
        children: [
          Expanded(child: field),
          if (chip != null) ...[
            const SizedBox(width: UtenSpacing.s4),
            Tooltip(
              message: chip,
              child: Icon(
                chipIcon,
                size: 16,
                semanticLabel: chip,
                color: theme.colorScheme.tertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _discountCell(
    BuildContext context,
    AppLocalizations l10n,
    SalesQuoteFinanceLine line,
    bool editable,
  ) {
    final draft = _drafts[line.itemId];
    if (draft == null) return const Text('—');
    if (!editable || !draft.discountEditable) {
      return Text(
        draft.isMaster || draft.directPricing
            ? financeTrim(draft.discount.text)
            : '1',
        textAlign: TextAlign.right,
      );
    }
    final batchCount = _selected.contains(line.itemId) && _selected.length > 1
        ? _selected.length
        : 0;
    final field = TextField(
      key: ValueKey('quote-finance-discount-${line.itemId}'),
      controller: draft.discount,
      textAlign: TextAlign.right,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [_decimalInput],
      onChanged: (text) => _onDiscountChanged(draft, text),
      decoration: UtenInputDecoration(
        InputDecoration(
          isDense: true,
          error: utenFieldError(
            draft.error == QuoteFinanceLineError.discount
                ? l10n.quoteFinanceErrorDiscount
                : null,
          ),
        ),
      ),
    );
    return Semantics(
      textField: true,
      label:
          '${line.goodsName ?? line.goodsCode ?? ''} '
          '${l10n.quoteFinanceColDiscount}',
      child: batchCount > 0
          ? Tooltip(
              message: l10n.quoteFinanceCheckedEditHint(batchCount),
              child: field,
            )
          : field,
    );
  }

  String? _fileDiffText(AppLocalizations l10n, SalesQuoteFinanceLine line) {
    final diff = _drafts[line.itemId]?.fileDifference;
    if (diff == null) return null;
    if (isZeroDecimal(diff)) return l10n.quoteFinanceFileMatch;
    return diff.startsWith('-') ? _money(diff) : '+${_money(diff)}';
  }

  Widget _summary(AppLocalizations l10n, SalesQuoteFinanceReview review) {
    final dirtyLines = _drafts.values.any((d) => d.dirty);
    return UtenTotalsSummaryBar(
      density: true,
      rowCount: review.lines.length,
      entries: [
        UtenTotalEntry(
          l10n.quoteFinanceTotalQty,
          measurementTotalsText(
            review.lines.map(
              (line) => MeasuredAmount(
                value: _drafts[line.itemId]?.removed == true
                    ? 0
                    : double.tryParse(
                            _drafts[line.itemId]?.qty.text ?? line.qty ?? '',
                          ) ??
                          0,
                unitId: line.unitKey,
                unitName: line.unitName,
              ),
            ),
          ),
        ),
        UtenTotalEntry(
          l10n.quoteFinanceTotalAmount,
          _money(review.totalOriginal),
          danger: true,
        ),
        if (dirtyLines)
          UtenTotalEntry(
            l10n.quoteFinanceTotalPreview,
            _money(_previewTotal(review)),
          ),
      ],
    );
  }

  /// 未保存时的合计预览：没改的行用服务端金额，改过的行用预览金额。
  String _previewTotal(SalesQuoteFinanceReview review) => exactAmountSumText([
    for (final line in review.lines)
      switch (_drafts[line.itemId]) {
        final draft? => draft.amountPreview,
        null => line.amount,
      },
  ]);

  Widget _floatingActions(
    AppLocalizations l10n,
    SalesQuoteFinanceReview review,
  ) {
    final ready = _claimReady && !_busy;
    void notReady() => context.appWarning(
      _claim?.failureMessage ?? l10n.quoteFinanceClaimNotReady,
    );
    final children = <Widget>[
      if (review.allows(SalesQuoteFinanceAction.returnToSales))
        UtenButton(
          key: const Key('quote-finance-return'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: Icons.undo_rounded,
          onPressed: ready ? _returnToSales : null,
          onDisabledTap: _claimReady ? null : notReady,
          child: Text(l10n.quoteFinanceActionReturn),
        ),
      // 撤销确认不需要认领(SPEC §6.2)，只看服务端是否允许。
      if (review.allows(SalesQuoteFinanceAction.reopen))
        UtenButton(
          key: const Key('quote-finance-reopen'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          icon: Icons.lock_open_rounded,
          onPressed: _busy ? null : _reopen,
          child: Text(l10n.quoteFinanceActionReopen),
        ),
      if (review.allows(SalesQuoteFinanceAction.edit))
        UtenButton(
          key: const Key('quote-finance-save'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          icon: Icons.save_outlined,
          onPressed: ready && _dirty ? _save : null,
          onDisabledTap: _claimReady
              ? () => context.appInfo(l10n.quoteFinanceNothingToSave)
              : notReady,
          child: Text(l10n.quoteFinanceActionSave),
        ),
      if (review.allows(SalesQuoteFinanceAction.confirm))
        UtenButton(
          key: const Key('quote-finance-confirm'),
          size: UtenButtonSize.large,
          icon: Icons.fact_check_outlined,
          onPressed: ready ? _confirm : null,
          onDisabledTap: _claimReady ? null : notReady,
          child: Text(l10n.quoteFinanceActionConfirm),
        ),
    ];
    if (children.isEmpty) {
      children.add(
        UtenButton(
          key: const Key('quote-finance-back'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          icon: Icons.arrow_back_rounded,
          onPressed: _leave,
          child: Text(l10n.quoteFinanceActionBack),
        ),
      );
    }
    return UtenFloatingActionGroup(children: children);
  }

  /// 金额按服务端十进制原文显示(ADR-112)：至少 2 位小数、不四舍五入。
  String _money(String? raw) {
    if (raw == null || raw.isEmpty) return '—';
    return financeExactDecimal(raw) == null
        ? raw
        : financeExactMoneyDisplay(raw);
  }

  static String? _dateText(DateTime? value) {
    if (value == null) return null;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)}';
  }
}
