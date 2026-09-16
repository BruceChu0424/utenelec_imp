// 出货财务审核详情页（财务专用视图，与销售端出货详情分离；2026-09-12 拆分）。
//
// 对齐销售订单财务审核页 V300 / 订货审批审核详情页（ADR-027 §五）范式：
//  - 状态条：单据号 + 待审核 / 已放行 / 已退回；
//  - 客户财务快照卡：货款类型、结账方式、正式应收未收、铺底额、超出铺底额（红字）、
//    可用预收（原币/本币）；客户未完成销售货款分类时阻断放行并给恢复路径；
//  - 商业快照变化卡（上次审核 → 本次修改）：ShipmentFinanceChangeSummary；
//  - 出货信息卡 + 只读明细（MasterDataTableView 嵌入模式）+ 只读附件；
//  - 底部右下悬浮双决策：退回销售（必填原因，红）/ 确认放行；认领机制
//    （SALES_SHIPMENT_FINANCE_AUDIT）贯穿加载与提交，他人认领中禁止决策。
// 本页不出现销售端操作（编辑/删除/销售确认）与仓库作业，职责分离。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../basic_data/models/client_node.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/sales_shipment_finance_count_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/finance_review_claim_notice.dart';
import '../../sales/config/sales_doc_config.dart';
import '../../sales/models/sales_doc.dart';
import '../../sales/providers/master_name_provider.dart';
import '../../sales/repositories/sales_repository.dart';
import '../../sales/widgets/shipment_finance_change_summary.dart';

class FinanceSalesShipmentAuditReviewPage extends ConsumerStatefulWidget {
  const FinanceSalesShipmentAuditReviewPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<FinanceSalesShipmentAuditReviewPage> createState() =>
      _FinanceSalesShipmentAuditReviewPageState();
}

class _FinanceSalesShipmentAuditReviewPageState
    extends ConsumerState<FinanceSalesShipmentAuditReviewPage> {
  SalesDocDetail? _detail;
  ShipmentFinanceAuditInfo? _info;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  TaskClaimSession? _claim;
  int _loadGeneration = 0;

  bool get _canDecide =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(Perm.financeShipmentAudit);

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

  bool get _paymentTypeClassified {
    final info = _info;
    if (info == null) return false;
    if (info.billingMode == 'FREE') return true;
    return const {
      ClientSalesPaymentType.monthly,
      ClientSalesPaymentType.cash,
      ClientSalesPaymentType.deposit,
    }.contains(info.salesPaymentType?.trim());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    ++_loadGeneration;
    _claim?.removeListener(_claimChanged);
    _claim?.releaseAll().ignore();
    super.dispose();
  }

  void _claimChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() {
      _loading = true;
      _error = null;
      _detail = null;
      _info = null;
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
      final decided =
          detail.financeAudit == 1 || detail.shipmentWorkflow.financeRejected;
      if (_canDecide && !decided) {
        final claim = financeReviewClaim(container)..addListener(_claimChanged);
        _claim = claim;
        await claim.claimAll('SALES_SHIPMENT_FINANCE_AUDIT', [widget.id]);
        if (!mounted || generation != _loadGeneration || !claim.isCurrent) {
          await claim.releaseAll();
          return;
        }
      }
      final info = await repo.financeAuditInfo(widget.id);
      if (!mounted || generation != _loadGeneration) return;

      // 名称字典：客户/仓库/币种 + 明细货品 + 表头人员。
      await ref.read(salesMasterNameServiceProvider).ensureLoaded();
      await ref
          .read(salesMasterNameServiceProvider)
          .loadGoodsNames(
            detail.items.map((e) => e.goodsId).whereType<String>().toSet(),
          );
      // 2026-09-14：快照上线前的老出货单没有 goodsCodeSnapshot，货品列只剩名称；
      // 同表「库位号」列读的也是这份详情缓存（此前恒显示 —）。补一次货品详情。
      await ref
          .read(salesMasterNameServiceProvider)
          .loadGoodsDetails(
            detail.items.map((e) => e.goodsId).whereType<String>().toSet(),
          );
      await ref.read(salesMasterNameServiceProvider).loadEmployeeNames([
        detail.sellerId,
        detail.senderId,
      ]);
      if (!mounted || generation != _loadGeneration) return;

      setState(() {
        _detail = detail;
        _info = info;
        _loading = false;
      });
      // 快照不可读时仍允许查看单据，但决策按钮保持不可用并明示原因。
      if (decided) {
        await _claim?.releaseAll();
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

  Future<void> _leave() async {
    await _claim?.releaseAll();
    if (!mounted) return;
    popOrBackTo(context, defaultPath: RouteName.financeSalesShipmentAudit);
  }

  /// 决策完成后的落点：从工作台 push 进来 → 带 true 返回值 pop，列表刷新；
  /// 深链/路由栈空 → 跳回出货财务审核工作台（勿裸 pop，见 v2026.09.03-1 事故）。
  void _closeAfterDecision() {
    ref.invalidate(salesShipmentFinanceCountProvider);
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
      context.appWarning('尚未取得有效审核占用，请重新认领并核对内容');
      return;
    }
    final generation = _loadGeneration;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('确认放行 ${_detail?.billNo ?? ''}'),
        content: const SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UtenReviewerResponsibilityNotice(
                actionLabel: '出货财务审核',
                description: '确认仅放行仓库作业；正式应收在仓库确认出库后生成。系统将记录当前审核员并承担本次放行责任。',
                compact: true,
              ),
              SizedBox(height: UtenSpacing.s12),
              Text('放行后仓库即可确认出库；出库时才扣库存并生成应收。确认放行？'),
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
          context.appWarning(claim.failureMessage ?? '审核内容或占用已变化，请重新认领并核对');
        }
        return;
      }
      await ref
          .read(salesRepositoryProvider(SalesDocType.shipment))
          .financeAudit(
            widget.id,
            expectedRevision: info.reviewRevision!,
            expectedContentHash: info.contentHash!,
            expectedClaimId: claim.claimIdFor(
              'SALES_SHIPMENT_FINANCE_AUDIT',
              widget.id,
            )!,
          );
      if (!mounted) return;
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
      context.appWarning('尚未取得有效审核占用，请重新认领并核对内容');
      return;
    }
    final generation = _loadGeneration;
    final controller = TextEditingController();
    String? errorText;
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
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
                    info: '写明需要销售修改的内容，如结账方式、货款类型或明细数量。',
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
    Future<void>.delayed(const Duration(milliseconds: 300), controller.dispose);
    if (reason == null || reason.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      if (!await claim.validateForDecision() ||
          !mounted ||
          generation != _loadGeneration ||
          !identical(info, _info)) {
        if (mounted) {
          context.appWarning(claim.failureMessage ?? '审核内容或占用已变化，请重新认领并核对');
        }
        return;
      }
      await ref
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
          );
      if (!mounted) return;
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

  /// 撤回退回可用：被退回 + 未放行 + 仓库未作业（V578）。
  bool get _canRejectReverse {
    final d = _detail;
    if (d == null || !_canDecide || _busy) return false;
    if (d.financeAudit == 1) return false;
    if (!d.shipmentWorkflow.financeRejected) return false;
    return salesShipmentAllowsFinanceAudit(d.warehouseWorkStatus);
  }

  /// 撤回退回（V578）：财务收回退回决定，单据恢复待审——退回原因与出货
  /// 内容无关（如客户货款分类未维护、误退）时无需销售改单来回折腾。
  Future<void> _rejectReverse() async {
    if (_busy) return;
    final billNo = _detail?.billNo ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
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
    ref.listen(sessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      ++_loadGeneration;
      _claim?.removeListener(_claimChanged);
      _claim?.releaseAll().ignore();
      _claim = null;
      if (mounted) {
        setState(() {
          _detail = null;
          _info = null;
          _loading = false;
          _error = '登录身份已变化，请重新加载并认领审核';
        });
      }
    });
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: '出货财务审核',
        leading: UtenBackButton(onPressed: _leave),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading || _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded, size: 20),
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
                        onPressed: _load,
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
                    // 2026-09-15 表格宽度口径二修（用户反馈）：上午收进 narrow(1120) 后两侧
                    // 大留白，弃 narrow 改默认容器（1600 钳制），对齐新建销售订货单页；
                    // 滚动仍为折叠头+表内滚：上滑先收卡片区，明细标题吸顶后在表格内部滚。
                    child: UtenContentContainer(
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
                              if (_canDecide &&
                                  _decisionReady &&
                                  _claim?.isReady != true) ...[
                                FinanceReviewClaimNotice(
                                  claim: _claim,
                                  onRetry: _busy ? null : _load,
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                              ],
                              _statusStrip(theme, _detail!, _info!),
                              const SizedBox(height: UtenSpacing.s12),
                              _clientFinanceCard(theme, _info!),
                              const SizedBox(height: UtenSpacing.s12),
                              _shipmentCard(theme, _detail!),
                              const SizedBox(height: UtenSpacing.s12),
                              ShipmentFinanceChangeSummary(
                                previous: _info!.previousCommercialSnapshot,
                                current: _info!.commercialSnapshot,
                                describe: _describeSnapshotValue,
                              ),
                              const SizedBox(height: UtenSpacing.s12),
                              _attachments(theme, _detail!),
                              if (_detail!
                                  .shipmentWorkflow
                                  .financeRejected) ...[
                                const SizedBox(height: UtenSpacing.s12),
                                _rejectRecordCard(theme, _detail!),
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
    );
  }

  /// 右下悬浮操作组：待审=退回销售(红)+确认放行；已退回=撤回退回；其余状态只留返回。
  /// 客户未完成销售货款分类时放行禁用（服务端同样拒绝；快照卡内有恢复路径）。
  Widget _floatingActions(ThemeData theme) {
    final claimReady = _claim?.isReady == true;
    final classified = _paymentTypeClassified;
    final canDecide = _canDecide && _decisionReady && claimReady && !_busy;
    if (_canRejectReverse) {
      return UtenFloatingActionGroup(
        children: [
          UtenButton(
            key: const Key('finance-shipment-audit-back-secondary'),
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            onPressed: _leave,
            child: const Text('返回'),
          ),
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
    if (!canDecide) {
      return UtenFloatingActionGroup(
        children: [
          UtenButton(
            key: const Key('finance-shipment-audit-back'),
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            icon: Icons.arrow_back_rounded,
            onPressed: _leave,
            child: const Text('返回'),
          ),
        ],
      );
    }
    return UtenFloatingActionGroup(
      children: [
        UtenButton(
          key: const Key('finance-shipment-audit-back-secondary'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: _leave,
          child: const Text('返回'),
        ),
        UtenButton(
          key: const Key('finance-shipment-audit-reject'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: Icons.reply_rounded,
          onPressed: _busy ? null : _reject,
          child: const Text('退回销售'),
        ),
        UtenButton(
          key: const Key('finance-shipment-audit-approve'),
          size: UtenButtonSize.large,
          isLoading: _busy,
          icon: Icons.fact_check_outlined,
          onPressed: _busy || !classified ? null : _approve,
          onDisabledTap: classified
              ? null
              : () => context.appWarning('客户尚未完成销售货款分类（月结/现金/定金），不能放行'),
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
      'colorId' => names.color(id),
      'unitId' => names.unit(id),
      'sellerId' || 'senderId' => '已更换人员（请核对本单人员信息）',
      'settlementMethodId' => '已更换结账方式（请核对本单条款）',
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
    final (color, icon, text) = audited
        ? (
            theme.colorScheme.primary,
            Icons.verified_rounded,
            '财务已放行 · ${d.financeAuditedAt != null ? '${d.financeAuditedAt!.substring(0, 10)} · ' : ''}仓库可以确认出库',
          )
        : rejected
        ? (
            theme.colorScheme.error,
            Icons.undo_rounded,
            '已退回销售 · ${d.shipmentWorkflow.financeRejectionReason ?? '未注明原因'}'
                '${_canRejectReverse ? ' · 可撤回退回恢复审核' : ''}',
          )
        : warehouseStarted
        ? (
            theme.colorScheme.error,
            Icons.block_rounded,
            '仓库已确认出库，不能补做或撤销财务审核；纠错请走销售退货。',
          )
        : !d.shipmentWorkflow.salesConfirmed
        ? (
            theme.colorScheme.tertiary,
            Icons.hourglass_top_rounded,
            '销售尚未确认本单内容；确认提交后才进入财务审核。',
          )
        : (
            theme.colorScheme.tertiary,
            Icons.pending_actions_rounded,
            '待财务审核 · 放行后仓库才能确认出库',
          );
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
                  d.billNo ?? '未编号出货',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  text,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 客户财务快照卡：审核必看的货款分类、应收、铺底与可用预收。
  Widget _clientFinanceCard(ThemeData theme, ShipmentFinanceAuditInfo info) {
    final names = ref.watch(salesMasterNameServiceProvider);
    final overFloor = double.tryParse(info.overFloor ?? '');
    final overFloorDanger = overFloor != null && overFloor > 0;
    final permissions = ref.watch(currentPermissionsProvider);
    final canEditClientMaster =
        ref.watch(isSuperAdminProvider) ||
        (permissions.contains(Perm.clientView) &&
            permissions.contains(Perm.clientEdit));

    Widget metric(String label, String? value, {bool danger = false}) =>
        SizedBox(
          width: 220,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value?.trim().isNotEmpty == true ? value!.trim() : '0',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: danger ? theme.colorScheme.error : null,
                ),
              ),
            ],
          ),
        );

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
                    '客户财务快照 · ${info.clientName ?? names.client(_detail?.clientId)}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s12,
              children: [
                if (info.billingMode != null)
                  metric(
                    '本次发货',
                    info.billingMode == 'FREE' ? '不收费（货款 0）' : '收费',
                  ),
                if (info.directPurpose != null)
                  metric('发货用途', switch (info.directPurpose) {
                    'SAMPLE' => '样品',
                    'GIFT' => '赠送',
                    _ => '其它客户发货',
                  }),
                if (info.freeReason != null) metric('不收费原因', info.freeReason),
                metric('客户货款类别', salesPaymentTypeLabel(info.salesPaymentType)),
                metric('结账方式', info.settlementMethodName ?? '未设置'),
                metric('正式应收未收(本币)', info.outstanding),
                metric('铺底额(本币)', info.creditFloor),
                metric('超出铺底额(本币)', info.overFloor, danger: overFloorDanger),
                metric('可用预收(原币)', info.availablePrepaymentOriginal),
                metric('可用预收(本币)', info.availablePrepaymentLocal),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '货款类别来自客户资料（月结/现金/定金），不是本单填写；“定金”只是客户标签，绝不代表已经到账；可用预收只统计同客户同币种的真实已审核到账，不能自动抵扣其它订单。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (!_paymentTypeClassified) ...[
              const SizedBox(height: UtenSpacing.s12),
              Container(
                key: const Key('finance-audit-classification-block'),
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: UtenRadius.mdAll,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.block_rounded,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        canEditClientMaster
                            ? '客户尚未完成销售货款分类，当前不能放行。请先到“客户资料”选择月结、现金或定金并保存，再返回刷新。'
                            : '客户尚未完成销售货款分类，当前不能放行。请联系有客户资料维护权限的人员选择月结、现金或定金，保存后再刷新。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (canEditClientMaster)
                      TextButton(
                        key: const Key('finance-audit-open-client-master'),
                        onPressed: () async {
                          // 客户资料页被 push 进来，返回即回本单；分类可能已改，
                          // 回来必须重拉（2026-09-10 口径）。
                          await context.push(RouteName.financeCustomers);
                          if (mounted) await _load();
                        },
                        child: const Text('去客户资料'),
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

  /// 出货信息卡：与销售端详情同规则的只读商业事实（币种红色加粗）。
  Widget _shipmentCard(ThemeData theme, SalesDocDetail d) {
    final names = ref.watch(salesMasterNameServiceProvider);
    Widget kv(String label, String? value, {bool highlight = false}) => Row(
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
            value == null || value.isEmpty ? '—' : value,
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

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenFormGrid(
          children: [
            kv('单据号', d.billNo),
            kv('出货日期', d.billDate),
            kv('客户', names.client(d.clientId)),
            kv('仓库', names.warehouse(d.warehouseId)),
            kv('币种', names.currency(d.currencyId), highlight: true),
            if (d.exchangeRate != null) kv('汇率', d.exchangeRate?.toString()),
            kv('业务员', names.employee(d.sellerId)),
            kv('发货人', names.employee(d.senderId)),
            kv('制单员', d.makerName),
            kv('制单时间', utenFmtIsoTime(d.createdAt)),
            if (d.shipmentWorkflow.isDirect)
              kv(
                '销售确认',
                d.shipmentWorkflow.salesConfirmed
                    ? '已确认（修订 ${d.shipmentWorkflow.revision}）'
                    : '待销售确认',
              ),
            if (d.shipmentWorkflow.purpose != null)
              kv('发货用途', switch (d.shipmentWorkflow.purpose) {
                'SAMPLE' => '样品',
                'GIFT' => '赠送',
                _ => '其它客户发货',
              }),
            if (d.shipmentWorkflow.freeReason != null)
              kv('不收费原因', d.shipmentWorkflow.freeReason),
            kv(
              '本次货款',
              d.shipmentWorkflow.isFree
                  ? '不收费（货款 0）'
                  : d.priceMasked
                  ? '***'
                  : '${d.exactDecimals['totalOriginal'] ?? d.totalOriginal ?? '—'}（所选币种）',
            ),
            if ((d.sourceDocNo?.isNotEmpty ?? false)) kv('来源订单', d.sourceDocNo),
            if ((d.logisticsNo?.isNotEmpty ?? false)) kv('物流单号', d.logisticsNo),
            if ((d.shipAddr?.isNotEmpty ?? false)) kv('收货地址', d.shipAddr),
            if (d.parcelCount != null) kv('件数', d.parcelCount?.toString()),
            kv('仓库作业', salesWarehouseWorkStatusLabel(d.warehouseWorkStatus)),
            if (d.remark?.isNotEmpty == true) kv('备注', d.remark),
          ],
        ),
      ),
    );
  }

  /// 出货明细：全局统一表格（嵌入模式），价格脱敏时金额打码。
  Widget _itemsCard(ThemeData theme, SalesDocDetail d) {
    final names = ref.watch(salesMasterNameServiceProvider);
    final masked = d.priceMasked;
    final items = d.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '出货明细(${items.length})',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: MasterDataTableView<SalesDocItem>(
            primary: true,
            bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
            columns: [
              MasterColumnDef(
                key: 'goods',
                // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
                label: '货品名称',
                width: 200,
                value: (it) => salesGoodsNameLabel(it, names.goods(it.goodsId)),
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
                key: 'unitName',
                label: '单位',
                width: 80,
                value: (it) => names.unit(it.unitId),
              ),
              MasterColumnDef(
                key: 'stockPlace',
                label: '库位号',
                width: 90,
                value: (it) => names.goodsInfo(it.goodsId)?.stockPlace ?? '—',
              ),
              MasterColumnDef(
                key: 'qty',
                label: '数量',
                width: 90,
                type: 'number',
                value: (it) => it.qty?.toStringAsFixed(2),
              ),
              MasterColumnDef(
                key: 'price',
                label: '单价',
                width: 120,
                type: 'money',
                value: (it) => masked ? '***' : it.price?.toStringAsFixed(2),
              ),
              MasterColumnDef(
                key: 'amount',
                label: '金额',
                width: 100,
                type: 'money',
                value: (it) => masked
                    ? '***'
                    : ((it.qty ?? 0) * (it.price ?? 0)).toStringAsFixed(2),
              ),
              MasterColumnDef(
                key: 'remark',
                label: '备注',
                width: 160,
                value: (it) =>
                    (it.remark?.isNotEmpty ?? false) ? it.remark : null,
              ),
            ],
            items: items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            emptyMessage: '(无明细)',
          ),
        ),
      ],
    );
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
              (permissions.contains(Perm.financeShipmentAudit) &&
                  (salesConfirmed ||
                      d.shipmentWorkflow.financeRejected ||
                      d.financeAudit == 1 ||
                      d.status == 1))),
      canManage: false,
      readOnlyNote: BusinessAttachmentSection.kReviewReadOnlyAttachmentNote,
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
