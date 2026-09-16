// 销售单据详情页（全页路由）：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。操作按 edit 权限。
// 名称解析：客户/仓库/币种/颜色/单位用 SalesMasterNameService；货品按明细 id 批量 lookup。
//
// 审核副作用（前端只调 approve 端点，UI 显示状态）：
//  - 出货财务审核→只放行仓库；仓库确认出库才扣库存、回写已发并立应收
//  - 退货审核→后端自动库存入库+双挂回写+立红字应收+结案
//  - 其它出货审核→仅库存出库
//
// 2026-09-11 折叠头+表内滚改版（对齐采购/货品资料页）：整页 ListView 改
// UtenCollapsingHeaderScrollView——上滑先折叠头部（表头卡/预收汇总/出货卡/附件/退货质检），
// 「明细 (N)」标题顶到页面顶部后再滚明细表内部；合计条常驻表格下方。
//
// 2026-09-12 职责分离改版：出货财务审核从本页退役——财务在专用审核页
// /finance/sales-shipment-audits/:id 办理（认领/放行/退回）；本页对出货单改为
// 顶部状态横幅（正在等待财务审核/财务已放行/财务已退回）+ 销售自己的操作
// （编辑/取消/提交财务）。底栏操作统一右下悬浮（UtenFloatingActionGroup），
// 处理中用全屏 UtenBusyOverlay，不再占用固定底栏。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/currency_display.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/measurement_totals.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/providers/sales_shipment_finance_count_provider.dart';
import '../../../shared/widgets/source_doc_link.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/repositories/task_claim_repository.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/widgets/sales_order_money_summary_card.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../models/sales_return_quality.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';
import '../widgets/sales_return_quality_card.dart';
import '../widgets/sales_status_badge.dart';
import '../widgets/sales_plan_progress_panel.dart';

class SalesDocDetailPage extends ConsumerStatefulWidget {
  const SalesDocDetailPage({
    super.key,
    required this.docType,
    required this.id,
  });
  final SalesDocType docType;
  final String id;

  @override
  ConsumerState<SalesDocDetailPage> createState() => _SalesDocDetailPageState();
}

class _SalesDocDetailPageState extends ConsumerState<SalesDocDetailPage> {
  SalesDocConfig get _cfg => _detail?.shipmentWorkflow.isDirect == true
      ? SalesDocConfig.customerShipment
      : SalesDocConfig.by(widget.docType);
  SalesDocDetail? _detail;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  List<SalesReturnQualityItem>? _returnQualitySnapshot;
  // 销售订单审核并发认领（SALES_ORDER_APPROVE；page-state 持有，跨 _busy 底栏切换不丢）。
  TaskClaimSession? _approveClaim;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _approveClaim?.releaseAll();
    super.dispose();
  }

  /// 服务端已合并功能权限与负责人范围；不能仅凭前端权限常量开放对象写操作。
  bool get _objectWritable => _detail?.writable ?? false;

  bool _hasPermission(String? code) =>
      code != null && ref.read(currentPermissionsProvider).contains(code);

  bool get _canEdit =>
      widget.docType != SalesDocType.otherShipment &&
      _objectWritable &&
      _hasPermission(_cfg.editPerm);
  bool get _canDelete =>
      widget.docType != SalesDocType.otherShipment &&
      _objectWritable &&
      _hasPermission(_cfg.deletePerm);
  bool get _canApprove =>
      widget.docType != SalesDocType.otherShipment &&
      _objectWritable &&
      _hasPermission(_cfg.approvePerm);
  bool get _canReverse => _objectWritable && _hasPermission(_cfg.reversePerm);
  bool get _approveClaimBlocked => _approveClaim?.blocked ?? false;

  /// 仓库驳回权限（仅出货单）：PMC/销售可在草稿（待备货）态驳回。
  bool get _canReject =>
      widget.docType.isShipment &&
      (_detail?.canReject ?? false) &&
      _hasPermission(Perm.salesShipmentReject);

  /// 报价转换同时需要来源转换权和目标订货新增权。
  bool get _canConvert =>
      widget.docType == SalesDocType.quote &&
      _objectWritable &&
      _hasPermission(Perm.salesQuoteConvert) &&
      _hasPermission(Perm.salesOrderCreate);

  bool get _canChangeQty =>
      _objectWritable && _hasPermission(Perm.salesOrderChangeQty);

  bool get _canStopOrder =>
      _objectWritable && _hasPermission(Perm.salesOrderStop);

  bool get _canChangePlanned => ref
      .read(currentPermissionsProvider)
      .contains(Perm.salesOrderChangePlanned);

  bool _touchesPlanned(SalesDocItem item) =>
      (item.plannedQty ?? 0) > 0 || (item.producedQty ?? 0) > 0;

  bool get _orderHasPlanned => _detail?.items.any(_touchesPlanned) ?? false;

  bool get _orderHasProductionAssociation =>
      salesOrderHasProductionAssociation(_detail?.items ?? const []);

  bool get _orderHasShipped =>
      salesOrderHasShippedQuantity(_detail?.items ?? const []);

  bool get _canChangeAnyOrderQty =>
      // 2026-09-05 用户口径（反转）：财务确认后允许改量——改完自动回到
      // 「待财务确认」，财务按修改清单（以前→现在）复核；驳回单仍走受控修订。
      // 2026-09-09 用户口径：财务确认前改量走「修改订单」入口，不再并列显示
      // 「改量」按钮——两入口只在已确认后并存（改量提供重回待确认的受控通道）。
      _canChangeQty &&
      (_detail?.financeConfirmed ?? false) &&
      (_canChangePlanned ||
          (_detail?.items.any((item) => !_touchesPlanned(item)) ?? false));

  bool get _canCancelOrder =>
      _objectWritable &&
      _hasPermission(Perm.salesOrderCancel) &&
      !_orderHasProductionAssociation &&
      !_orderHasShipped;

  String? get _orderCancelBlockReason {
    if (_orderHasProductionAssociation) {
      return '已有排产、在产或完工关联；请先取消/红冲未开工子计划，已领料先退料，已完工先解除订单预留。';
    }
    if (_orderHasShipped) {
      return '已有发货记录；不能整单取消，请用“改量”把数量改为已发量以取消未发部分。';
    }
    return null;
  }

  bool get _canManageWarehouseWork {
    final d = _detail;
    return widget.docType.isShipment &&
        d != null &&
        d.financeAudit == 1 &&
        d.canManageWarehouseWork &&
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.salesShipmentWarehouseWork);
  }

  bool get _shipmentEditLockedByFinanceAudit =>
      widget.docType.isShipment &&
      salesShipmentLocksDraftEdit(
        documentStatus: _detail?.status,
        financeAudit: _detail?.financeAudit,
        warehouseWorkStatus: _detail?.warehouseWorkStatus,
      );

  bool get _canViewReturnQuality =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.salesReturnQualityView);

  bool get _canCorrectReturnQuality =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.salesReturnQualityCorrect);

  bool get _canDisposeReturnQuality =>
      ref.read(isSuperAdminProvider) ||
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.salesReturnQualityDispose);

  String? get _returnQualityReversalBlockReason {
    if (widget.docType != SalesDocType.returnDoc ||
        _detail?.status != kSalesStatusApproved) {
      return null;
    }
    if (!_canViewReturnQuality) {
      return '当前账号不能核验质检冻结台账，因此不开放退货红冲；请由有“查看销售退货质检冻结”权限的人员处理。';
    }
    final snapshot = _returnQualitySnapshot;
    if (snapshot == null) {
      return '正在核验质检冻结台账，核验完成前不开放退货红冲。';
    }
    if (snapshot.any((item) => item.blocksDirectReturnReversal)) {
      return '该退货已发生质检处置，或质检台账处于未知/不可直接撤销状态，不能直接红冲原退货单。';
    }
    return null;
  }

  bool get _canReverseDocument {
    if (!_canReverse) return false;
    if (widget.docType.isShipment &&
        !salesShipmentAllowsDirectReverse(
          warehouseWorkStatus: _detail?.warehouseWorkStatus,
          handedOverAt: _detail?.handedOverAt,
        )) {
      return false;
    }
    if (_returnQualityReversalBlockReason != null) return false;
    return true;
  }

  void _onReturnQualitySnapshot(List<SalesReturnQualityItem> items) {
    if (!mounted) return;
    setState(() => _returnQualitySnapshot = List.unmodifiable(items));
  }

  void _invalidateReturnQualitySnapshot() {
    if (!mounted || _returnQualitySnapshot == null) return;
    setState(() => _returnQualitySnapshot = null);
  }

  /// 报价转订货：已审报价一键生成订货草稿（行带入+价格留痕），转后跳订货编辑页。
  Future<void> _convertToOrder() async {
    if (_busy) {
      context.appInfo('正在处理，请稍候…');
      return;
    }
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('转订货单'),
        content: const Text(
          '将按报价行生成订货草稿：货品、数量和报价单价带入，其中单价锁定不可修改，'
          '折扣可在订货草稿中调整。确认转入？',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('转入'),
          ),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      final order = await ref
          .read(salesRepositoryProvider(SalesDocType.quote))
          .convertToOrder(widget.id);
      if (!mounted) return;
      context.appSuccess('已生成订货草稿 ${order.billNo ?? ''}');
      // 跨单据类型：转单生成的是订货草稿，bump 订货列表 key（非本报价 key），
      // 用户后续进入订货列表/取消编辑后返回订货列表都能看到这张新草稿。
      bumpListRefresh(ref, SalesDocConfig.by(SalesDocType.order).refreshKey);
      context.push(
        SalesRoutePath.docEdit(SalesDocType.order.pathSegment, order.id),
      );
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('转入失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(salesMasterNameServiceProvider).ensureLoaded();
      final d = await ref
          .read(salesRepositoryProvider(widget.docType))
          .detail(widget.id);
      final goodsIds = d.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(salesMasterNameServiceProvider).loadGoodsNames(goodsIds);
      // 2026-09-14：快照上线前的老单据没有 goodsCodeSnapshot，货品列只剩名称；
      // 同页「库位号」列读的也是这份详情缓存（此前恒显示 —）。补一次货品详情，
      // 让编号与库位都能回落到主档事实。失败不影响正文（名称已加载）。
      await ref.read(salesMasterNameServiceProvider).loadGoodsDetails(goodsIds);
      // 表头人员字段（业务员/发货人/分批确认登记人）按 id 解析为姓名展示。
      await ref.read(salesMasterNameServiceProvider).loadEmployeeNames([
        d.sellerId,
        d.senderId,
        d.partialShipmentConfirmedBy,
      ]);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
      // 销售订单（草稿可审核）认领 SALES_ORDER_APPROVE：他人审核中则禁用审核按钮。
      // 仅 UX/防碰撞层；后端 SalesOrderService.approve 守卫是正确性底线。认领失败 fail-open。
      if (_cfg.type == SalesDocType.order &&
          d.status == kSalesStatusDraft &&
          !d.rejected) {
        _approveClaim = TaskClaimSession(ref.read(taskClaimRepositoryProvider));
        await _approveClaim!.claimAll('SALES_ORDER_APPROVE', [widget.id]);
        if (mounted) setState(() {});
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
        _error = '加载详情失败';
        _loading = false;
      });
    }
  }

  Future<void> _approve() async => _doAction(
    // 销售订单审核只让订单进入库存预留与履约链，不在此形成正式应收；
    // V294 闸门：审核后自动转发财务审核，财务确认通过前计划部不可见、不排产。
    _cfg.type == SalesDocType.order
        ? '审核通过后订单将生效并形成库存预留，随后自动转发财务审核；财务确认通过后计划部才可见并排产。确认审核？'
        : _cfg.type.isShipment && _detail?.financeAudit != 1
        ? '该出货单尚未完成财务审核；所有客户都必须先由财务放行，再由仓库确认出库。确认继续审核？'
        : '审核后将驱动下游(库存/应收)，确认审核？',
    (repo) => repo.approve(widget.id),
    _cfg.type == SalesDocType.order ? '已审核，已转发财务审核' : '已审核',
    reviewerResponsibility: true,
  );
  Future<void> _reverse() async =>
      _doAction('红冲将反向冲销，确认？', (repo) => repo.reverse(widget.id), '已红冲');

  /// 恢复已中止订单：重跑库存检查并重新软预留（中止方向已并入 _cancel，
  /// 后端 toggleStopped(stopped=true) 与 cancel 本就是同一路径）。
  Future<void> _restore() async => _doAction(
    '确认恢复该订单的履约状态？',
    (repo) => repo.setStopped(widget.id, stopped: false),
    '订单已恢复',
  );

  /// 订单取消：仅无发货、无排产/在产/完工关联时开放，避免展示后端必然拒绝的操作。
  Future<void> _cancel() async {
    if (!_canCancelOrder) {
      context.appWarning(_orderCancelBlockReason ?? '当前订单不能整单取消');
      return;
    }
    await _doAction(
      '取消将释放全部库存预留并停止尚未排产的需求，确认取消订单？',
      (repo) => repo.cancel(widget.id),
      '已取消',
    );
  }

  Future<void> _performWarehouseAction(SalesWarehouseWorkAction action) async {
    if (_busy) {
      context.appInfo('正在处理，请稍候…');
      return;
    }
    final message = switch (action) {
      SalesWarehouseWorkAction.confirmShipment =>
        '确认出库将在同一事务里扣减库存、消耗预留、回写订单已发数量并生成应收；'
            '不能通过普通编辑撤回。确认出库？',
    };
    await _doAction(
      message,
      (repo) => repo.transitionWarehouseWork(
        widget.id,
        targetStatus: action.targetStatus,
      ),
      '已确认出库',
    );
  }

  /// 订单改量：弹窗逐行改数量（增量重走预留/减量释放，已排产行需生产部权限）。
  Future<void> _changeQty() async {
    if (_busy) {
      context.appInfo('正在处理，请稍候…');
      return;
    }
    if (_detail == null) return;
    final ctrls = <String, TextEditingController>{};
    for (final it in _detail!.items) {
      if (it.id != null) {
        ctrls[it.id!] = TextEditingController(
          text: it.qty?.toStringAsFixed(2) ?? '',
        );
      }
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('订单改量'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: [
              if (_detail!.financeConfirmed)
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                  child: Text(
                    '本订单已经财务确认：修改数量后将自动重新进入「待财务确认」，'
                    '财务会看到修改清单（以前→现在）并需再次确认后才继续排产。',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (_orderHasPlanned && !_canChangePlanned)
                Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                  child: Text(
                    '已排产/已生产行仅生产确认人员可改，当前为只读。',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              for (final it in _detail!.items)
                if (it.id != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${it.clientModel ?? ''} 现 ${it.qty?.toStringAsFixed(2) ?? '—'}'
                            ' 已发 ${it.shippedQty?.toStringAsFixed(2) ?? '0'}',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(fontWeight: FontWeight.w400),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(
                          width: 100,
                          child: TextField(
                            controller: ctrls[it.id!],
                            enabled: _canChangePlanned || !_touchesPlanned(it),
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              isDense: true,
                              labelText: '新数量',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认改量'),
          ),
        ],
      ),
    );
    if (ok != true) {
      for (final c in ctrls.values) {
        c.dispose();
      }
      return;
    }
    final changes = <Map<String, dynamic>>[];
    for (final it in _detail!.items) {
      if (it.id == null) continue;
      final v = double.tryParse(ctrls[it.id!]!.text);
      ctrls[it.id!]!.dispose();
      if (v == null) {
        if (mounted) context.appError('存在无效数量，请检查');
        return;
      }
      if (v != it.qty) {
        changes.add({'orderItemId': it.id, 'newQty': v});
      }
    }
    if (changes.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(salesRepositoryProvider(widget.docType))
          .changeQty(widget.id, changes);
      if (!mounted) return;
      context.appSuccess('已改量');
      bumpListRefresh(ref, _cfg.refreshKey);
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('改量失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmShipmentSales() async {
    final workflow = _detail?.shipmentWorkflow;
    // V578：被财务退回后允许原样重新提交（无需先改单）。
    if (_busy ||
        workflow == null ||
        (!workflow.canConfirmSales &&
            !workflow.canResubmitAfterFinanceReject)) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(salesRepositoryProvider(widget.docType))
          .confirmShipmentSales(widget.id, workflow.revision);
      if (!mounted) return;
      context.appSuccess('销售已确认，已提交财务审核');
      ref.invalidate(salesShipmentFinanceCountProvider);
      bumpListRefresh(ref, _cfg.refreshKey);
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('提交失败，请刷新后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 仓库驳回：填原因 → 释放预留 + 订单行回退待排产。
  Future<void> _reject() async {
    if (_busy) {
      context.appInfo('正在处理，请稍候…');
      return;
    }
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('驳回出货单'),
        content: TextField(
          controller: reasonCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '驳回原因(如：预留货物损坏 / 找不到)'),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认驳回'),
          ),
        ],
      ),
    );
    final reason = reasonCtrl.text;
    reasonCtrl.dispose();
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(salesRepositoryProvider(widget.docType))
          .reject(widget.id, reason: reason);
      if (!mounted) return;
      context.appSuccess('已驳回，对应订单行已回退待处理');
      bumpListRefresh(ref, _cfg.refreshKey);
      await _load();
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('驳回失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ======================= 行级预留管理（优先级 + 让单）=======================

  bool get _canSetPriority =>
      ref.read(currentPermissionsProvider).contains(Perm.salesOrderPriority);

  bool get _canReallocate =>
      ref.read(currentPermissionsProvider).contains(Perm.salesOrderReallocate);

  /// 点订单明细行 → 弹底部 sheet（设优先级 / 让单），按权限与行可发量显隐段。
  /// 仅订货单；草稿/已红冲/无可操作权限的行只维持表格自带的高亮。
  Future<void> _showLineActions(SalesDocItem item) async {
    if (widget.docType != SalesDocType.order) return;
    if (_detail?.financeRejected ?? false) {
      context.appInfo('订单已被财务驳回，请先使用“修改订单”完成修订并重新审核');
      return;
    }
    if (item.id == null) return;
    final canYield = _canReallocate && (item.reservedQty ?? 0) > 0;
    if (!_canSetPriority && !canYield) {
      context.appInfo('当前行无可执行的管理操作');
      return;
    }
    final names = ref.read(salesMasterNameServiceProvider);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (ctx) => _LineActionSheet(
        item: item,
        canSetPriority: _canSetPriority,
        canYield: canYield,
        goodsLabel:
            '${names.goods(item.goodsId)}(${names.color(item.colorId)})',
        qtyLabel:
            '订货 ${item.qty?.toStringAsFixed(2) ?? '-'} · 已发 ${item.shippedQty?.toStringAsFixed(2) ?? '-'} · 可发 ${item.reservedQty?.toStringAsFixed(2) ?? '-'}',
        onSetPriority: (p, reason) => _setLinePriority(item.id!, p, reason),
        onYield: (qty, reason) => _yieldLine(item.id!, qty, reason),
      ),
    );
  }

  Future<void> _setLinePriority(String itemId, int p, String? reason) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final d = await ref
          .read(salesRepositoryProvider(widget.docType))
          .setLinePriority(itemId, p, reason: reason);
      if (!mounted) return;
      context.appSuccess('已设为 ${priorityLabel(p)}');
      bumpListRefresh(ref, _cfg.refreshKey);
      setState(() => _detail = d);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('设优先级失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _yieldLine(String itemId, double qty, String reason) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final d = await ref
          .read(salesRepositoryProvider(widget.docType))
          .yieldReservation(
            itemId,
            qty: qty,
            reason: reason,
            yielderOrderNo: _detail?.billNo,
          );
      if (!mounted) return;
      context.appSuccess(
        '已让单 ${qty.toStringAsFixed(2)}，释放的库存已回可分配池，该订单行已回到计划需求池',
      );
      bumpListRefresh(ref, _cfg.refreshKey);
      setState(() => _detail = d);
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('让单失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doAction(
    String confirm,
    Future<SalesDocDetail> Function(SalesRepository) fn,
    String ok, {
    bool reviewerResponsibility = false,
  }) async {
    if (_busy) {
      // 上一个操作仍在途（网络慢时最长 10~20s）：明确提示，不再静默吞点击。
      context.appInfo('正在处理，请稍候…');
      return;
    }
    final c = reviewerResponsibility
        ? await showUtenReviewerConfirmDialog(context, message: confirm)
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
      await fn(ref.read(salesRepositoryProvider(widget.docType)));
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
    if (_busy) {
      context.appInfo('正在处理，请稍候…');
      return;
    }
    final isShipment = _cfg.type.isShipment;
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isShipment ? '取消出货单' : '删除单据'),
        content: Text(
          isShipment
              ? '确定取消该出货草稿吗？取消后单据删除且不可恢复；已提交财务审核的需先由财务退回。'
              : '确定删除该草稿单据吗？',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isShipment ? '确认取消' : '删除'),
          ),
        ],
      ),
    );
    if (c != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(salesRepositoryProvider(widget.docType)).delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      backTo(context, defaultPath: SalesRoutePath.list(_cfg.type.pathSegment));
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
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
    final permissions = ref.watch(currentPermissionsProvider);
    final canViewMoneySummary =
        permissions.contains(Perm.financeViewAll) &&
        permissions.contains(Perm.customerPrepaymentView);
    return Scaffold(
      appBar: UtenAppBar(
        title: '${_cfg.label}详情',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: SalesRoutePath.hub),
        ),
        actions: [
          // 整页刷新（2026-09-05 用户口径：右上角刷新=刷新整个页面）。
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded, size: 20),
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // 2026-09-15 宽度口径（用户反馈）：详情页弃 narrow（1120 两侧大留白），
            // 改默认容器对齐新建销售订货单页。
            UtenContentContainer(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : _error != null
                  ? Center(child: Text(_error!))
                  : _detail == null
                  ? const SizedBox.shrink()
                  // 2026-09-11 折叠头+表内滚：头部（表头卡/预收汇总/出货卡/附件/
                  // 退货质检）随上滚收起，明细标题吸顶后表格内部继续滚。
                  : UtenCollapsingHeaderScrollView(
                      collapsingHeader: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 出货财审状态横幅（2026-09-12 拆分改版）：销售一眼
                            // 看清本单正卡在财审哪一步；财审操作本身在财务专页。
                            if (_cfg.type.isShipment) ...[
                              _shipmentFinanceStatusStrip(theme),
                              const SizedBox(height: UtenSpacing.s12),
                            ],
                            // 表头信息卡文字可框选：外层 UtenContentContainer 已默认包局部
                            // SelectionArea（准则 §3.4），无需再单独包。
                            _headerCard(theme, names),
                            if (_cfg.type == SalesDocType.order &&
                                _detail!.financeConfirmed) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              Text(
                                '产品进度与分批发货',
                                style: theme.textTheme.titleMedium,
                              ),
                              SalesPlanProgressPanel(
                                orderId: widget.id,
                                canShip:
                                    _detail!.writable &&
                                    _detail!.status == kSalesStatusApproved &&
                                    !_detail!.closed &&
                                    !_detail!.stopped,
                                onChanged: _load,
                              ),
                            ],
                            if (_cfg.type == SalesDocType.order &&
                                canViewMoneySummary) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              SalesOrderMoneySummaryCard(
                                salesOrderId: widget.id,
                              ),
                            ],
                            if (_cfg.type == SalesDocType.order &&
                                _detail!.shipments.isNotEmpty) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              _shipmentsCard(theme),
                            ],
                            if (_cfg.attachmentOwnerType != null) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              BusinessAttachmentSection(
                                ownerType: _cfg.attachmentOwnerType!,
                                ownerId: _detail!.id,
                                canView:
                                    !_detail!.priceMasked &&
                                    (permissions.contains(_cfg.listPerm) ||
                                        (_cfg.type.isShipment &&
                                            permissions.contains(
                                              Perm.financeShipmentAudit,
                                            ) &&
                                            (_detail!
                                                    .shipmentWorkflow
                                                    .salesConfirmed ||
                                                _detail!.financeRejected ||
                                                _detail!.financeAudit == 1 ||
                                                _detail!.status == 1))),
                                // 详情=审核页：文件一律只读（2026-09-11 用户要求）。
                                // 增删回编辑页做——审核者看到的永远是提交时那一份。
                                canManage: false,
                                readOnlyNote: BusinessAttachmentSection
                                    .kReviewReadOnlyAttachmentNote,
                                categories: const ['合同', '客户确认', '图片', '其他'],
                              ),
                            ],
                            if (_cfg.type == SalesDocType.returnDoc &&
                                _detail!.status == kSalesStatusApproved &&
                                _canViewReturnQuality) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              SalesReturnQualityCard(
                                key: ValueKey('return-quality-${widget.id}'),
                                returnId: widget.id,
                                canCorrect: _canCorrectReturnQuality,
                                canDispose: _canDisposeReturnQuality,
                                onSnapshotChanged: _onReturnQualitySnapshot,
                                onSnapshotInvalidated:
                                    _invalidateReturnQualitySnapshot,
                              ),
                            ],
                          ],
                        ),
                      ),
                      // body：明细标题（钉住）+ 表格占满内滚（primary 拾取联动控制器）。
                      // 2026-09-12 右下悬浮操作组：滚动让位走表格内置 bottomContentPadding
                      // （随行滚动），钉住的合计条只让出按钮高度，不在固定布局里叠 200px。
                      body: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenFloatingActionGroup.controlHeight +
                              UtenSpacing.s32,
                        ),
                        child: _itemsCard(theme, names),
                      ),
                    ),
            ),
            // 处理中屏幕中央加载动画（2026-09-12 口径：跟随网络段；按钮 isLoading
            // 同步转圈，不再用固定底栏占位）。
            if (_busy)
              const Positioned.fill(child: UtenBusyOverlay(title: '正在处理，请稍候')),
          ],
        ),
      ),
      // 2026-09-12 UI 统一口径：底部操作改右下悬浮组（UtenFloatingActionGroup），
      // 不再做固定吸底操作条；重要/危险动作仍为红色按钮。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _detail == null || _busy ? null : _actions(theme),
    );
  }

  /// 出货财审状态横幅：待财审 / 财务退回 / 已放行 / 仓库作业中——只显示状态与
  /// 指引，不放财审操作（财审在 /finance/sales-shipment-audits/:id 办理）。
  Widget _shipmentFinanceStatusStrip(ThemeData theme) {
    final d = _detail!;
    final rejected = d.shipmentWorkflow.financeRejected;
    final audited = d.financeAudit == 1;
    // V582：仓库不再有「作业中」的中间态——要么待出库，要么已出库。
    final (color, icon, text) = d.status == kSalesStatusApproved
        ? (
            theme.colorScheme.primary,
            Icons.local_shipping_outlined,
            '已出库；数量与价款不能再改，真实退货走退货检验。',
          )
        : rejected
        ? (
            theme.colorScheme.error,
            Icons.undo_rounded,
            '财务已退回：${d.shipmentWorkflow.financeRejectionReason ?? '未注明原因'}。'
                '可「编辑」改单后重新提交，或原因与内容无关时直接「重新提交财务审核」。',
          )
        : audited
        ? (
            theme.colorScheme.primary,
            Icons.verified_rounded,
            '财务已放行${d.financeAuditedAt != null ? '（${d.financeAuditedAt!.substring(0, 10)}）' : ''}，'
                '等待仓库确认出库；修改须先由财务反审。',
          )
        : d.shipmentWorkflow.financeReviewPending
        ? (
            theme.colorScheme.tertiary,
            Icons.hourglass_top_rounded,
            '正在等待财务审核；财务放行后仓库才能确认出库。财审认领期间本单锁定编辑。',
          )
        : d.shipmentWorkflow.isDirect
        ? (
            theme.colorScheme.tertiary,
            Icons.edit_outlined,
            '草稿待销售确认；确认并提交财务后进入财审。',
          )
        : (
            theme.colorScheme.tertiary,
            Icons.edit_outlined,
            '出货草稿；按订单发货生成，待进入财务审核。',
          );
    return Container(
      key: const Key('shipment-finance-status-strip'),
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
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerCard(ThemeData theme, SalesMasterNameService names) {
    final d = _detail!;
    final resolvedCurrency = names.currency(d.currencyId);
    final orderCurrency = resolvedCurrency == '—' ? '订单币种' : resolvedCurrency;
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      _KV('制单员', d.makerName),
      _KV('制单时间', utenFmtIsoTime(d.createdAt)),
      _KV('客户', names.client(d.clientId)),
      if (_cfg.hasWarehouse) _KV('仓库', names.warehouse(d.warehouseId)),
      // 币种加粗红色（一眼看清结算币种，避免外币单看错币种族金额）。
      if (_cfg.hasCurrency)
        _KV('币种', names.currency(d.currencyId), highlight: true),
      if (_cfg.hasCurrency && _cfg.hasExchangeRate && d.exchangeRate != null)
        _KV('汇率', d.exchangeRate?.toString()),
      // 业务员/发货人：按 id 经员工字典解析姓名（_load 已预载）。
      if (_cfg.hasSeller) _KV('业务员', names.employee(d.sellerId)),
      if (_cfg.hasSender) _KV('发货人', names.employee(d.senderId)),
      if (_cfg.hasValidUntil) _KV('有效期', d.validUntil),
      if (_cfg.hasDeliverDate) _KV('交货日', d.deliverDate),
      if (_cfg.type == SalesDocType.order)
        _KV('发运策略', salesShipmentPolicyLabel(d.shipmentPolicy)),
      if (_cfg.type == SalesDocType.order &&
          d.shipmentPolicy == SalesShipmentPolicy.customerConfirm)
        _KV(
          '分批确认',
          d.partialShipmentConfirmed
              ? '已确认 · ${utenFmtIsoTime(d.partialShipmentConfirmedAt)}'
              : '待客户确认',
        ),
      // V294 财务确认闸门：已审订单须财务确认后计划部才可见/可排产。
      if (_cfg.type == SalesDocType.order && d.status == kSalesStatusApproved)
        _KV(
          '财务确认',
          d.financeConfirmed
              ? '已确认 · ${utenFmtIsoTime(d.financeConfirmedAt)}'
              : '待财务确认(确认后计划部才可见并排产)',
        ),
      // ADR-052 财务驳回：显示原因；受控修订回草稿并重新销售审核后才回财务确认。
      if (_cfg.type == SalesDocType.order &&
          d.financeRejected &&
          !d.financeConfirmed)
        _KV(
          '财务驳回',
          '${d.financeRejectedReason ?? '未注明原因'}'
              '${(d.financeRejectedByName?.isNotEmpty ?? false) ? '(${d.financeRejectedByName} · ${utenFmtIsoTime(d.financeRejectedAt)})' : ''}',
          highlight: true,
        ),
      if (_cfg.type == SalesDocType.order &&
          d.financeConfirmed &&
          (d.financeConfirmedByName?.isNotEmpty ?? false))
        _KV('财务确认人', d.financeConfirmedByName),
      if (_cfg.type == SalesDocType.order &&
          (d.financeConfirmRemark?.isNotEmpty ?? false))
        _KV('财务确认备注', d.financeConfirmRemark),
      if (_cfg.type == SalesDocType.order &&
          d.partialShipmentConfirmedBy != null)
        _KV('确认登记人', names.employee(d.partialShipmentConfirmedBy)),
      if (_cfg.type == SalesDocType.order &&
          (d.partialShipmentConfirmationReason?.isNotEmpty ?? false))
        _KV('确认依据', d.partialShipmentConfirmationReason),
      if (_cfg.type == SalesDocType.order &&
          d.status == kSalesStatusApproved &&
          !d.stopped &&
          _orderCancelBlockReason != null)
        _KV('取消限制', _orderCancelBlockReason),
      if (_cfg.hasContractInfo && d.contractNo != null)
        _KV('合同号', d.contractNo),
      if (_cfg.hasContractInfo && (d.linkPhone?.isNotEmpty ?? false))
        _KV('联系电话', d.linkPhone),
      if (_cfg.hasContractInfo && (d.signAddr?.isNotEmpty ?? false))
        _KV('签约地点', d.signAddr),
      if ((d.shipAddr?.isNotEmpty ?? false)) _KV('收货地址', d.shipAddr),
      if (_cfg.hasShipInfo && d.parcelCount != null)
        _KV('件数', d.parcelCount?.toString()),
      if (_cfg.hasOutType && (d.outType?.isNotEmpty ?? false))
        _KV('出库类型', d.outType),
      // 价格脱敏（SOP §三8）：无 sales_order:price:view 时价格族渲染 ***
      if (_cfg.type == SalesDocType.order)
        _KV(
          '订单金额($orderCurrency)',
          d.priceMasked ? '***' : d.totalOriginal?.toStringAsFixed(2),
        )
      else if (d.shipmentWorkflow.isDirect)
        _KV(
          '本次货款',
          d.shipmentWorkflow.isFree
              ? '不收费（货款 0）'
              : d.priceMasked
              ? '***'
              : '${d.exactDecimals['totalOriginal'] ?? d.totalOriginal ?? '—'}（所选币种）',
        )
      else
        _KV('合计(本币)', d.priceMasked ? '***' : d.totalLocal?.toStringAsFixed(2)),
      if (d.shipmentWorkflow.isDirect)
        _KV('销售确认', d.shipmentWorkflow.salesConfirmed ? '已确认' : '待销售确认'),
      if (d.shipmentWorkflow.isDirect)
        _KV('发货用途', switch (d.shipmentWorkflow.purpose) {
          'SAMPLE' => '样品',
          'GIFT' => '赠送',
          _ => '其它客户发货',
        }),
      if (d.shipmentWorkflow.freeReason != null)
        _KV('不收费原因', d.shipmentWorkflow.freeReason),
      if (d.shipmentWorkflow.financeRejected)
        _KV('财务退回', d.shipmentWorkflow.financeRejectionReason),
      if (d.remark?.isNotEmpty == true) _KV('备注', d.remark),
      if (_cfg.type == SalesDocType.returnDoc &&
          (d.returnReason?.isNotEmpty ?? false))
        _KV('退货原因', d.returnReason),
      if (_cfg.type == SalesDocType.returnDoc &&
          (d.sourceDocNo?.isNotEmpty ?? false))
        _KV('来源单号', d.sourceDocNo),
      _KV(
        '状态',
        null,
        badge: SalesStatusBadge(
          status: d.status,
          closed: d.closed,
          stopped: d.stopped,
          arPosted: d.arPosted,
        ),
      ),
      if (d.rejected) _KV('驳回原因', d.rejectReason ?? '仓库备货异常'),
      if (_returnQualityReversalBlockReason != null)
        _KV('退货红冲限制', _returnQualityReversalBlockReason),
      // 所有客户均须先财务放行，仓库动作才开放。
      if (_cfg.type.isShipment)
        _KV(
          '财务审核',
          d.financeAudit == 1
              ? '已审发货${d.financeAuditedAt != null ? '(${d.financeAuditedAt!.substring(0, 10)})' : ''}'
              : salesShipmentFinanceAuditLabel(d.financeAudit),
        ),
      if (_cfg.type.isShipment)
        _KV('仓库作业', salesWarehouseWorkStatusLabel(d.warehouseWorkStatus)),
      if (_cfg.type.isShipment)
        _KV(
          '仓库下一步',
          d.warehouseWorkStatus == SalesWarehouseWorkStatus.legacyPending
              ? salesWarehouseWorkStatusHint(d.warehouseWorkStatus)
              : d.financeAudit == 1
              ? salesWarehouseWorkStatusHint(d.warehouseWorkStatus)
              : '等待财务审核放行；放行前仓库不能确认出库。',
        ),
      if (_cfg.type.isShipment && d.warehouseWorkUpdatedAt != null)
        _KV('作业更新时间', utenFmtIsoTime(d.warehouseWorkUpdatedAt)),
      if (_cfg.type.isShipment && d.handedOverAt != null)
        _KV('出库时间', utenFmtIsoTime(d.handedOverAt)),
      if (_cfg.type.isShipment &&
          !salesShipmentAllowsDirectReverse(
            warehouseWorkStatus: d.warehouseWorkStatus,
            handedOverAt: d.handedOverAt,
          ))
        const _KV('红冲限制', '已出库事实不能直接改写。真实退回走退货检验；仅价款有误须财务调整，不能虚做退货。'),
      if (_cfg.type.isShipment &&
          salesShipmentLocksDraftEdit(
            documentStatus: d.status,
            financeAudit: d.financeAudit,
            warehouseWorkStatus: d.warehouseWorkStatus,
          ))
        const _KV('编辑限制', '已确认出库；库存与应收已过账，纠错请走销售退货。'),
      if (_cfg.type.isShipment &&
          (d.warehouseExceptionReason?.isNotEmpty ?? false))
        _KV('仓库异常', d.warehouseExceptionReason),
      // 报价转入回链（SOP §三1）：来源报价可点跳报价详情，行级报价单价见明细
      if (_cfg.type == SalesDocType.order && d.sourceQuoteId != null)
        _KV(
          '来源报价',
          null,
          badge: GestureDetector(
            onTap: () => context.push(
              SalesRoutePath.docDetail(
                SalesDocType.quote.pathSegment,
                d.sourceQuoteId!,
              ),
            ),
            child: Text(
              d.sourceDocNo ?? '查看报价',
              style: TextStyle(
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenFormGrid(
          children: [
            for (final r in rows) _kvRow(theme, r),
            if ((_cfg.type.isShipment ||
                    _cfg.type == SalesDocType.otherShipment) &&
                (d.sourceOrderId != null ||
                    (d.sourceDocNo?.isNotEmpty ?? false)))
              SourceDocLink(
                label: '来源订单',
                billNo: d.sourceDocNo,
                onTap: d.sourceOrderId == null
                    ? null
                    : () => context.push(
                        SalesRoutePath.docDetail(
                          SalesDocType.order.pathSegment,
                          d.sourceOrderId!,
                        ),
                      ),
              ),
            if (_cfg.type == SalesDocType.returnDoc)
              SourceDocLink(
                label: '来源出货单',
                billNo: d.sourceDocNo,
                onTap: d.sourceShipmentId == null
                    ? null
                    : () => context.push(
                        SalesRoutePath.docDetail(
                          SalesDocType.shipment.pathSegment,
                          d.sourceShipmentId!,
                        ),
                      ),
              ),
            if ((_cfg.type.isShipment ||
                    _cfg.type == SalesDocType.otherShipment) &&
                (d.logisticsNo?.isNotEmpty ?? false))
              SourceDocLink(label: '物流单号', billNo: d.logisticsNo),
          ],
        ),
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
        Expanded(
          child:
              r.badge ??
              Text(
                r.value ?? '—',
                style: r.highlight
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

  /// 明细区：统一表格样式（MasterDataTableView 嵌入模式，与全站报表/主档同款）。
  /// 订单的出货与物流聚合（SOP §三.7：分批部分发货会产生多张出货单，
  /// 订单详情聚合展示全部出货单与各自物流单号，不能只存一个）。
  Widget _shipmentsCard(ThemeData theme) {
    final shipments = _detail!.shipments;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '出货与物流(${shipments.length})',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            for (final s in shipments)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
                child: Row(
                  children: [
                    InkWell(
                      onTap: () => context.push(
                        SalesRoutePath.docDetail(
                          SalesDocType.shipment.pathSegment,
                          s.id,
                        ),
                      ),
                      borderRadius: BorderRadius.circular(4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            s.billNo ?? s.id,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s4),
                          Icon(
                            Icons.open_in_new,
                            size: 14,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        [
                          if (s.billDate?.isNotEmpty == true) s.billDate!,
                          s.statusLabel ?? '',
                          salesWarehouseWorkStatusLabel(s.warehouseWorkStatus),
                          if (s.logisticsNo?.isNotEmpty == true)
                            '物流 ${s.logisticsNo}',
                        ].where((t) => t.isNotEmpty).join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
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

  /// 口径保留：价格脱敏（无权限订单单价/金额 = ***）；报价来源行「单价（报价 X）」对比；
  /// 订单行含可发/已排/已产；链路状态并入货品列文本。
  /// 2026-09-11 起是折叠容器的 body：标题行钉住、表格 primary:true 内滚；
  /// 2026-09-14 合计条收进表格 summaryBar 槽位；2026-09-15 改随表体滚动
  ///（summaryBarInline：表内脚注，跟在最后一行数据之下）。
  Widget _itemsCard(ThemeData theme, SalesMasterNameService names) {
    final items = _detail!.items;
    final isOrder = _cfg.type == SalesDocType.order;
    // 出货单后端同样下发 priceMasked（无 sales_order:price:view 时商业字段置 null）。
    final masked = _detail!.priceMasked && (isOrder || _cfg.type.isShipment);
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
        Expanded(
          child: MasterDataTableView<SalesDocItem>(
            primary: true,
            columns: [
              // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列，
              // 不再拼成「编号 · 名称(颜色 · 单位)」一长串。单位与链路状态各自
              // 单独成列，列窄时不会先把编号吃掉。
              MasterColumnDef(
                key: 'goods',
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
              if (isOrder)
                MasterColumnDef(
                  key: 'chainStatus',
                  label: '业务链',
                  width: 130,
                  value: (it) => it.chainStatus == null || it.chainStatus == 0
                      ? '—'
                      : chainStatusLabel(
                          it.chainStatus,
                          plannedQty: it.plannedQty,
                          qty: it.qty,
                        ),
                ),
              MasterColumnDef(
                key: 'qty',
                label: '数量',
                width: 90,
                type: 'number',
                value: (it) => it.qty?.toStringAsFixed(2),
              ),
              // 实际重量列已下线（2026-09-04：单位已表达重量，编辑页不再录入）。
              // 实物出入库单据（出货/其它出货/退货）：库位号（主档带出，拣货/上架指引）。
              if (_cfg.hasWarehouse)
                MasterColumnDef(
                  key: 'stockPlace',
                  label: '库位号',
                  width: 90,
                  value: (it) => names.goodsInfo(it.goodsId)?.stockPlace ?? '—',
                ),
              MasterColumnDef(
                key: 'price',
                label: '单价',
                width: 120,
                type: 'money',
                value: (it) {
                  if (masked) return '***';
                  final p = it.price?.toStringAsFixed(2);
                  return (isOrder && it.quotePrice != null)
                      ? '$p(报价 ${it.quotePrice!.toStringAsFixed(2)})'
                      : p;
                },
              ),
              MasterColumnDef(
                key: 'amount',
                label: isOrder ? '金额(订单币种)' : '金额',
                width: 100,
                type: 'money',
                value: (it) => masked
                    ? '***'
                    : (isOrder
                              ? it.amountOriginal
                              : (it.qty ?? 0) * (it.price ?? 0))
                          ?.toStringAsFixed(2),
              ),
              if (_cfg.showShipped)
                MasterColumnDef(
                  key: 'shipped',
                  label: '已发',
                  width: 90,
                  type: 'number',
                  value: (it) => it.shippedQty?.toStringAsFixed(2),
                ),
              if (_cfg.showReturned)
                MasterColumnDef(
                  key: 'returned',
                  label: '已退',
                  width: 90,
                  type: 'number',
                  value: (it) => it.returnedQty?.toStringAsFixed(2),
                ),
              if (isOrder) ...[
                MasterColumnDef(
                  key: 'reserved',
                  label: '可发',
                  width: 90,
                  type: 'number',
                  value: (it) => it.reservedQty?.toStringAsFixed(2),
                ),
                MasterColumnDef(
                  key: 'planned',
                  label: '已排',
                  width: 90,
                  type: 'number',
                  value: (it) => it.plannedQty?.toStringAsFixed(2),
                ),
                MasterColumnDef(
                  key: 'produced',
                  label: '已产',
                  width: 90,
                  type: 'number',
                  value: (it) => it.producedQty?.toStringAsFixed(2),
                ),
                MasterColumnDef(
                  key: 'priority',
                  label: '优先级',
                  width: 80,
                  value: (it) => priorityLabel(it.priority),
                ),
              ],
              if (_cfg.type == SalesDocType.returnDoc) ...[
                MasterColumnDef(
                  key: 'solution',
                  label: '处理方案',
                  width: 110,
                  value: (it) =>
                      (it.solution?.isNotEmpty ?? false) ? it.solution : null,
                ),
                MasterColumnDef(
                  key: 'responsible',
                  label: '责任单位',
                  width: 100,
                  value: (it) => (it.responsible?.isNotEmpty ?? false)
                      ? it.responsible
                      : null,
                ),
              ],
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
            onRowTap: (it) => _showLineActions(it),
            // 右下悬浮操作组让位：末行（含随表滚动的合计条）可滚出按钮区。
            bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
            emptyMessage: '(无明细)',
            // 明细下合计条（summaryBarInline 随表体滚动）：数量按单位分组；
            // 价格脱敏时不出金额项。
            summaryBar: items.isNotEmpty
                ? UtenTotalsSummaryBar(
                    key: const Key('sales-detail-totals'),
                    density: true,
                    compact: true,
                    entries: [
                      utenQuantityTotalEntry(
                        items.map(
                          (it) => MeasuredAmount(
                            value: it.qty ?? 0,
                            unitId: it.unitId,
                            unitName: names.unit(it.unitId),
                          ),
                        ),
                      ),
                      if (!masked) ...[
                        UtenTotalEntry(
                          utenAmountTotalLabel(
                            _cfg.hasCurrency
                                ? financeCurrencyDisplayLabel(
                                    name: names.currency(_detail!.currencyId),
                                  )
                                : null,
                          ),
                          (_detail!.totalOriginal ??
                                  items.fold<double>(
                                    0,
                                    (sum, it) =>
                                        sum +
                                        (it.amountOriginal ??
                                            it.amountLocal ??
                                            0),
                                  ))
                              .toStringAsFixed(2),
                          danger: true,
                        ),
                        // 销售订单阶段本币事实按设计为空（不落 totalLocal）；订单表头卡
                        // 也只出「订单金额(订单币种)」。历史脏数据带 totalLocal 的订单
                        // 会把本币合计漏出来，故显式按单据类型门控（非订单单据照常出
                        // 本币合计）。
                        if (!isOrder)
                          UtenTotalEntry(
                            '合计(本币)',
                            _detail!.totalLocal?.toStringAsFixed(2) ?? '',
                          ),
                      ],
                    ],
                  )
                : null,
            // 2026-09-15 用户口径：合计条属于表格那一块——渲染进表体滚动内容末尾
            //（最后一行数据之下），不钉在区块底部/按钮上方。
            summaryBarInline: true,
          ),
        ),
      ],
    );
  }

  Widget _actions(ThemeData theme) {
    final s = _detail!.status;
    final rejected = _detail!.rejected;
    final children = <Widget>[];

    void add(Widget child) => children.add(child);
    if (s == kSalesStatusDraft && !rejected) {
      if (_detail!.shipmentWorkflow.canConfirmSales &&
          _hasPermission(_cfg.approvePerm)) {
        add(
          UtenButton(
            key: const ValueKey('shipment-confirm-sales'),
            size: UtenButtonSize.large,
            icon: Icons.send_outlined,
            onPressed: _busy ? null : _confirmShipmentSales,
            child: const Text('销售确认并提交财务'),
          ),
        );
      }
      // V578：被财务退回后，销售可原样重新提交（退回原因与内容无关时），
      // 也可走「编辑」改单再提交——两条路都通。
      if (_detail!.shipmentWorkflow.canResubmitAfterFinanceReject &&
          _hasPermission(_cfg.approvePerm)) {
        add(
          UtenButton(
            key: const ValueKey('shipment-resubmit-finance'),
            size: UtenButtonSize.large,
            icon: Icons.replay_rounded,
            onPressed: _busy ? null : _confirmShipmentSales,
            child: const Text('重新提交财务审核'),
          ),
        );
      }
      // 2026-09-12 职责分离：出货财务审核入口从本页退役——财务在专用审核页
      // /finance/sales-shipment-audits/:id 认领/放行/退回；本页只展示状态横幅。
      if (_canDelete) {
        add(
          UtenButton(
            key: const ValueKey('sales-doc-delete'),
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: _cfg.type.isShipment
                ? Icons.cancel_outlined
                : Icons.delete_outline,
            onPressed: _delete,
            child: Text(_cfg.type.isShipment ? '取消' : '删除'),
          ),
        );
      }
      if (_canEdit && !_shipmentEditLockedByFinanceAudit) {
        add(
          UtenButton(
            key: const ValueKey('sales-doc-edit'),
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            icon: Icons.edit_outlined,
            onPressed: () => context.push(
              SalesRoutePath.docEdit(_cfg.type.pathSegment, widget.id),
            ),
            child: const Text('编辑'),
          ),
        );
      }
      // 所有销售出货都必须走财务放行 + 仓库交接；历史直接审核入口同样失败关闭。
      if (_canApprove && !_cfg.type.isShipment) {
        add(
          UtenButton(
            size: UtenButtonSize.large,
            icon: Icons.check_circle_outline,
            onPressed: _approveClaimBlocked ? null : _approve,
            child: Text(_approveClaimBlocked ? '他人审核中' : '审核'),
          ),
        );
      }
      if (_canManageWarehouseWork) {
        for (final action in salesWarehouseWorkActionsFor(
          _detail!.warehouseWorkStatus,
        )) {
          final icon = switch (action) {
            SalesWarehouseWorkAction.confirmShipment =>
              Icons.local_shipping_outlined,
          };
          add(
            UtenButton(
              key: ValueKey('warehouse-work-${action.name}'),
              size: UtenButtonSize.large,
              icon: icon,
              onPressed: () => _performWarehouseAction(action),
              child: Text(action.label),
            ),
          );
        }
      }
      if (_canReject) {
        if (children.isNotEmpty) {
          children.add(const SizedBox(width: UtenSpacing.s8));
        }
        children.add(
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.block_outlined,
            onPressed: _reject,
            child: const Text('驳回'),
          ),
        );
      }
      if (children.isEmpty) {
        children.add(
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => backTo(
              context,
              defaultPath: SalesRoutePath.list(_cfg.type.pathSegment),
            ),
            child: const Text('返回列表'),
          ),
        );
      }
    } else if (s == kSalesStatusDraft && rejected) {
      // 已驳回（草稿终态）：只可删除重开
      if (_canDelete) {
        children
          ..add(
            UtenButton(
              type: UtenButtonType.danger,
              size: UtenButtonSize.large,
              icon: Icons.delete_outline,
              onPressed: _delete,
              child: const Text('删除重开'),
            ),
          )
          ..add(const SizedBox(width: UtenSpacing.s8));
      }
      children.add(
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: () => backTo(
            context,
            defaultPath: SalesRoutePath.list(_cfg.type.pathSegment),
          ),
          child: const Text('返回列表'),
        ),
      );
    } else if (s == kSalesStatusApproved) {
      // 报价转订货（SOP §三1）：已审报价一键生成订货草稿
      if (_cfg.type == SalesDocType.quote && _canConvert) {
        children
          ..add(
            UtenButton(
              size: UtenButtonSize.large,
              icon: Icons.transform_outlined,
              onPressed: _convertToOrder,
              child: const Text('转订货单'),
            ),
          )
          ..add(const SizedBox(width: UtenSpacing.s8));
      }
      if (_cfg.type == SalesDocType.order && !_detail!.stopped) {
        if (!_detail!.closed && _canEdit) {
          children
            ..add(
              UtenButton(
                key: const ValueKey('sales-order-finance-rejected-edit'),
                size: UtenButtonSize.large,
                icon: Icons.edit_outlined,
                onPressed: () => context.push(
                  SalesRoutePath.docEdit(_cfg.type.pathSegment, widget.id),
                ),
                child: const Text('修改订单'),
              ),
            )
            ..add(const SizedBox(width: UtenSpacing.s8));
        }
        if (_canChangeAnyOrderQty) {
          children
            ..add(
              UtenButton(
                type: UtenButtonType.secondary,
                size: UtenButtonSize.large,
                icon: Icons.edit_note_outlined,
                onPressed: _changeQty,
                child: const Text('改量'),
              ),
            )
            ..add(const SizedBox(width: UtenSpacing.s8));
        }
        children
          // 进度追踪：进入订单进度详情整页（2026-08-19 起替代排产进度底表弹窗），
          // 含产品进度（每行 已排/已产 + 计划溯源）与快递式履约时间线（带责任人）。
          // 财务确认前也可进入：产品进度区按 V300 口径隐藏，时间线仍展示审核轨迹。
          ..addAll([
            UtenButton(
              type: UtenButtonType.secondary,
              size: UtenButtonSize.large,
              icon: Icons.local_shipping_outlined,
              onPressed: () =>
                  context.push(RoutePath.salesOrderProgressDetail(widget.id)),
              child: const Text('进度追踪'),
            ),
          ])
          ..add(const SizedBox(width: UtenSpacing.s8));
        if (_canCancelOrder) {
          children
            ..add(
              UtenButton(
                type: UtenButtonType.danger,
                size: UtenButtonSize.large,
                icon: Icons.cancel_outlined,
                onPressed: _cancel,
                child: const Text('取消订单'),
              ),
            )
            ..add(const SizedBox(width: UtenSpacing.s8));
        }
        // 审核完成后不再展示"登记客户同意分批"（问题 #16/#18）：分批发货已不要求
        // 先登记客户同意依据，员工选的发运策略直接生效，这颗按钮没有意义了。
      }
      // 中止入口已并入「取消订单」：后端 toggleStopped(stopped=true) 对已审订单
      // 就是 cancel，两颗按钮效果完全相同；此处仅保留已中止订单的恢复能力。
      if (_cfg.type == SalesDocType.order &&
          _detail!.stopped &&
          _canStopOrder) {
        add(
          UtenButton(
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            icon: Icons.play_circle_outline,
            onPressed: _restore,
            child: const Text('恢复订单'),
          ),
        );
      }
      if (_canReverseDocument) {
        children.add(
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.undo_outlined,
            onPressed: _reverse,
            child: const Text('红冲'),
          ),
        );
      }
    } else {
      children.add(
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: () => backTo(
            context,
            defaultPath: SalesRoutePath.list(_cfg.type.pathSegment),
          ),
          child: const Text('返回列表'),
        ),
      );
    }
    if (children.isEmpty) {
      children.add(
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: () => backTo(
            context,
            defaultPath: SalesRoutePath.list(_cfg.type.pathSegment),
          ),
          child: const Text('返回列表'),
        ),
      );
    }
    return UtenFloatingActionGroup(
      children: children.where((child) => child is! SizedBox).toList(),
    );
  }
}

class _KV {
  const _KV(this.label, this.value, {this.badge, this.highlight = false});
  final String label;
  final String? value;
  final Widget? badge;

  /// 关键值强调（加粗 + 主题 error 红）：币种、财务驳回等需要一眼看清的字段。
  final bool highlight;
}

/// 行级管理底部 sheet：设优先级（急单须原因）+ 让单（释放现货预留）。
/// 纯输入收集——校验通过后回调父页执行（父页负责 _busy/网络/刷新），避免本组件持异步态。
class _LineActionSheet extends StatefulWidget {
  const _LineActionSheet({
    required this.item,
    required this.canSetPriority,
    required this.canYield,
    required this.goodsLabel,
    required this.qtyLabel,
    required this.onSetPriority,
    required this.onYield,
  });
  final SalesDocItem item;
  final bool canSetPriority;
  final bool canYield;
  final String goodsLabel;
  final String qtyLabel;
  final void Function(int priority, String? reason) onSetPriority;
  final void Function(double qty, String reason) onYield;

  @override
  State<_LineActionSheet> createState() => _LineActionSheetState();
}

class _LineActionSheetState extends State<_LineActionSheet> {
  late int _priority;
  late final TextEditingController _priorityReason;
  late final TextEditingController _yieldQty;
  late final TextEditingController _yieldReason;

  @override
  void initState() {
    super.initState();
    _priority = widget.item.priority ?? 3;
    _priorityReason = TextEditingController();
    _yieldQty = TextEditingController(
      text: (widget.item.reservedQty ?? 0).toStringAsFixed(2),
    );
    _yieldReason = TextEditingController();
  }

  @override
  void dispose() {
    _priorityReason.dispose();
    _yieldQty.dispose();
    _yieldReason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reserved = widget.item.reservedQty ?? 0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s8,
        UtenSpacing.s16,
        MediaQuery.of(context).viewInsets.bottom + UtenSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.goodsLabel, style: theme.textTheme.titleMedium),
            const SizedBox(height: UtenSpacing.s4),
            Text(widget.qtyLabel, style: theme.textTheme.bodySmall),
            const SizedBox(height: UtenSpacing.s16),
            if (widget.canSetPriority) ...[
              _sectionLabel(theme, '优先级'),
              const SizedBox(height: UtenSpacing.s8),
              Wrap(
                spacing: UtenSpacing.s8,
                children: [
                  for (final e in const [(1, '急单'), (2, '普通'), (3, '现货')])
                    ChoiceChip(
                      label: Text(e.$2),
                      selected: _priority == e.$1,
                      onSelected: (_) => setState(() => _priority = e.$1),
                    ),
                ],
              ),
              if (_priority == 1) ...[
                const SizedBox(height: UtenSpacing.s8),
                TextField(
                  controller: _priorityReason,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '急单原因(必填)'),
                ),
              ],
              const SizedBox(height: UtenSpacing.s12),
              FilledButton.icon(
                onPressed: _applyPriority,
                icon: const Icon(Icons.flag_outlined),
                label: const Text('应用优先级'),
              ),
              if (widget.canYield) const Divider(height: UtenSpacing.s32),
            ],
            if (widget.canYield) ...[
              _sectionLabel(theme, '让单(释放现货预留，回池供急单占用)'),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                controller: _yieldQty,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  hintText: '让单数量(0 < 数量 ≤ 可发 $reserved)',
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                controller: _yieldReason,
                decoration: const InputDecoration(hintText: '让单原因(必填)'),
              ),
              const SizedBox(height: UtenSpacing.s12),
              OutlinedButton.icon(
                onPressed: _doYield,
                icon: const Icon(Icons.swap_horiz_outlined),
                label: const Text('确认让单'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) => Align(
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  void _applyPriority() {
    final reason = _priorityReason.text.trim();
    if (_priority == 1 && reason.isEmpty) {
      context.appWarning('急单须填原因');
      return;
    }
    widget.onSetPriority(_priority, _priority == 1 ? reason : null);
    Navigator.of(context).pop();
  }

  void _doYield() {
    final qty = double.tryParse(_yieldQty.text.trim());
    final reserved = widget.item.reservedQty ?? 0;
    if (qty == null || qty <= 0 || qty > reserved) {
      context.appWarning('让单数量须 > 0 且 ≤ 可发 $reserved');
      return;
    }
    final reason = _yieldReason.text.trim();
    if (reason.isEmpty) {
      context.appWarning('让单须填原因');
      return;
    }
    widget.onYield(qty, reason);
    Navigator.of(context).pop();
  }
}
