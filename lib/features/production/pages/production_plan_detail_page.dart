// 生产计划单详情页（全页路由）：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。编辑/删除/审核/红冲分别按对应动作权限控制。
// is_closed（CheckFulfill4 派生：所有明细 qty-iqty≤0）/ is_stopped / is_canceled 经徽章副标体现。
// 关联销售订单：明细 salesOrderNo（文本占位，销售模块上线后挂真 FK）。
// 名称解析：货品/颜色/单位经 MasterNameService（跨 feature 复用 purchase 的 provider）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/responsive/dialog_size.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/document_scope_write_notice.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/production_execution_planning.dart';
import '../models/production_material_analysis.dart';
import '../models/production_plan.dart';
import '../repositories/production_repository.dart';
import '../widgets/production_execution_card_print_preview.dart';
import '../widgets/production_execution_segments_card.dart';
import '../widgets/production_status_badge.dart';
import '../widgets/progress_ring.dart';
import '../widgets/production_material_settlement_sheet.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../core/router/nav_helpers.dart';

class ProductionPlanDetailPage extends ConsumerStatefulWidget {
  const ProductionPlanDetailPage({
    super.key,
    required this.id,
    this.initialExecutionSegmentId,
  });
  final String id;
  final String? initialExecutionSegmentId;

  @override
  ConsumerState<ProductionPlanDetailPage> createState() =>
      _ProductionPlanDetailPageState();
}

class _ProductionPlanDetailPageState
    extends ConsumerState<ProductionPlanDetailPage> {
  ProductionPlanDetail? _detail;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  List<MrpSubplanRef>? _subplans;
  bool _executionBusy = false;
  String? _subplanError;
  String? _focusedExecutionSegmentId;
  int _executionSegmentsRevision = 0;

  @override
  void initState() {
    super.initState();
    _focusedExecutionSegmentId = widget.initialExecutionSegmentId;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant ProductionPlanDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _detail = null;
      _error = null;
      _subplans = null;
      _subplanError = null;
      _focusedExecutionSegmentId = widget.initialExecutionSegmentId;
      _executionSegmentsRevision = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
      return;
    }
    if (oldWidget.initialExecutionSegmentId !=
        widget.initialExecutionSegmentId) {
      setState(
        () => _focusedExecutionSegmentId = widget.initialExecutionSegmentId,
      );
    }
  }

  bool get _ordinaryWritable => documentOwnerCanWrite(
    ref.read(documentScopeCapabilityProvider(DocumentDataScope.productionPlan)),
    _detail?.makerId,
  );

  bool get _canEdit =>
      _ordinaryWritable &&
      ref.read(currentPermissionsProvider).contains(Perm.productionPlanEdit) &&
      _serverAllowsPlanAction('EDIT');

  bool get _canDelete =>
      _ordinaryWritable &&
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.productionPlanDelete) &&
      _serverAllowsPlanAction('DELETE');

  bool get _canReverse =>
      _ordinaryWritable &&
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.productionPlanReverse) &&
      _serverAllowsPlanAction('REVERSE');

  bool get _canApprove =>
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.productionPlanApprove) &&
      _serverAllowsPlanAction('APPROVE');

  bool get _canViewMaterialAnalysis => ref
      .read(currentPermissionsProvider)
      .contains(Perm.productionMaterialAnalysisView);

  bool get _canReturnToMaterialAnalysis =>
      _canViewMaterialAnalysis &&
      _serverAllowsPlanAction('RETURN_TO_MATERIAL_ANALYSIS');

  bool get _isMaterialAnalysisPlan =>
      _detail?.materialAnalysisId?.isNotEmpty == true ||
      (_detail?.allowedActions.contains('RETURN_TO_MATERIAL_ANALYSIS') ??
          false);

  bool _serverAllowsPlanAction(String action) {
    final actions = _detail?.allowedActions ?? const <String>[];
    return actions.contains(action);
  }

  bool get _commandBusy => _busy || _executionBusy;

  bool _hasPermission(String code) =>
      ref.read(currentPermissionsProvider).contains(code);

  bool get _canCancelPlanningPackage =>
      _hasPermission(Perm.productionPlanningPackageCancel);
  bool get _canReversePlanningPackage =>
      _hasPermission(Perm.productionPlanningPackageReverse);
  bool get _canSettleMaterials => _hasPermission(Perm.productionMaterialSettle);
  bool get _canReverseMaterialSettlement =>
      _hasPermission(Perm.productionMaterialReverse);
  bool get _canCloseProductionTask =>
      _hasPermission(Perm.productionMaterialClose);
  bool get _canManageProductionMaterials =>
      _canSettleMaterials ||
      _canReverseMaterialSettlement ||
      _canCloseProductionTask;
  bool get _canAssignExecution =>
      _hasPermission(Perm.productionExecutionAssign);
  bool get _canReleaseExecutionDefer =>
      _hasPermission(Perm.productionExecutionReleaseDefer);
  bool get _canDispatchExecution =>
      _hasPermission(Perm.productionExecutionDispatch);
  bool get _canStartExecution => _hasPermission(Perm.productionExecutionStart);

  bool get _canReport {
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.productionDailyReportView) &&
        permissions.contains(Perm.productionDailyReportCreate);
  }

  Future<void> _openLinkedPage(String path, {Object? extra}) async {
    if (_commandBusy) {
      context.appWarning('生产计划操作正在处理，请稍候', force: true);
      return;
    }
    try {
      await context.push(path, extra: extra);
    } catch (_) {
      if (mounted) context.appError('无法打开关联页面，请刷新后重试', force: true);
      return;
    }
    if (!mounted) return;
    setState(() => _executionSegmentsRevision++);
    await _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final planId = widget.id;
    ref.invalidate(
      documentScopeCapabilityProvider(DocumentDataScope.productionPlan),
    );
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      final d = await ref.read(productionPlanRepositoryProvider).detail(planId);
      final goodsIds = d.items
          .map((e) => e.goodsId)
          .whereType<String>()
          .toSet();
      await ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds);
      await ref.read(masterNameServiceProvider).loadEmployeeNames([
        d.sellerId,
        d.workerId,
      ]);
      if (!mounted || widget.id != planId) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
      await _loadSubplans(planId: planId);
    } on ApiException catch (e) {
      if (!mounted || widget.id != planId) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || widget.id != planId) return;
      setState(() {
        _error = '加载详情失败';
        _loading = false;
      });
    }
  }

  Future<void> _approve() async {
    const confirm =
        '审核会按关联物料分析重新校验本计划的子层级物料：有子层级时，只有整套齐全才会形成执行子计划与领料单；'
        '无下层物料时按直接自制下达，不生成生产领料单。审核与执行下达在同一事务完成，'
        '任一步失败都会整体回滚。确认继续？';
    await _doAction(
      confirm,
      (repo) => repo.approve(widget.id),
      '已审核',
      reviewerResponsibility: true,
      afterSuccess: _showLatestPlanningResultAfterApproval,
    );
  }

  Future<void> _reverse() async {
    if (!_canReverse) {
      context.appWarning('当前账号没有生产计划红冲权限', force: true);
      return;
    }
    await _doAction(
      '红冲将反向冲销，单据保留不可删，确认？',
      (repo) => repo.reverse(widget.id),
      '已红冲',
    );
  }

  Future<void> _doAction(
    String confirm,
    Future<void> Function(ProductionPlanRepository) fn,
    String ok, {
    bool reviewerResponsibility = false,
    Future<void> Function(ProductionPlanRepository)? afterSuccess,
  }) async {
    if (_commandBusy) {
      context.appWarning('已有生产计划操作正在处理，请稍候', force: true);
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
      await fn(ref.read(productionPlanRepositoryProvider));
      if (!mounted) return;
      context.appSuccess(ok);
      await _load();
      if (afterSuccess != null) {
        await afterSuccess(ref.read(productionPlanRepositoryProvider));
      }
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('操作失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadSubplans({String? planId}) async {
    if (!mounted) return;
    final requestedPlanId = planId ?? widget.id;
    try {
      final subplans = await ref
          .read(productionPlanRepositoryProvider)
          .mrpSubplans(requestedPlanId);
      if (!mounted || widget.id != requestedPlanId) return;
      setState(() {
        _subplans = subplans;
        _subplanError = null;
      });
    } catch (error) {
      if (!mounted || widget.id != requestedPlanId) return;
      setState(() {
        _subplans = null;
        _subplanError = productionErrorMessage(error, fallback: '子计划列表加载失败');
      });
    }
  }

  Future<void> _openLatestPlanningResult() async {
    if (_commandBusy) {
      context.appWarning('已有生产计划操作正在处理，请稍候', force: true);
      return;
    }
    setState(() => _executionBusy = true);
    try {
      final result = await ref
          .read(productionPlanRepositoryProvider)
          .latestPlanningPackageResult(widget.id);
      if (!mounted) return;
      setState(() => _executionBusy = false);
      await _presentPlanningResult(result);
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'NOT_FOUND') {
        context.appWarning(
          '当前计划没有可回查的执行单据。请从“物料分析准备”生成并审核计划，或联系系统管理员核对计划来源。',
          force: true,
        );
      } else {
        context.appError(error.message, force: true);
      }
    } catch (_) {
      if (mounted) context.appError('已生成单据加载失败，请稍后重试', force: true);
    } finally {
      if (mounted) setState(() => _executionBusy = false);
    }
  }

  Future<void> _openProductionWorkCards(String packageId) {
    return showProductionExecutionCardPrintPreview(
      context,
      loader: () => ref
          .read(productionPlanRepositoryProvider)
          .productionWorkCards(widget.id, packageId),
    );
  }

  Future<void> _showLatestPlanningResultAfterApproval(
    ProductionPlanRepository repo,
  ) async {
    try {
      final result = await repo.latestPlanningPackageResult(widget.id);
      if (!mounted) return;
      await _presentPlanningResult(result);
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'NOT_FOUND') {
        context.appWarning(
          '计划已审核，但未读取到执行单据。请回到“物料分析准备”核对来源，或联系系统管理员。',
          force: true,
        );
      } else {
        context.appWarning('计划已审核，但下达结果读取失败：${error.message}', force: true);
      }
    } catch (_) {
      if (mounted) {
        context.appWarning('计划已审核，但下达结果暂时无法读取', force: true);
      }
    }
  }

  Future<void> _presentPlanningResult(
    ProductionPlanningConfirmResult result,
  ) async {
    final selection = await _showPlanningPackageResult(result);
    if (!mounted) return;
    if (selection?.lifecycleAction != null) {
      await _changePlanningPackageLifecycle(
        result,
        selection!.lifecycleAction!,
      );
      return;
    }
    if (selection?.printWorkCards == true) {
      await _openProductionWorkCards(result.packageId);
    }
    if (!mounted) return;
    if (selection?.route != null) {
      try {
        await context.push(selection!.route!);
      } catch (_) {
        if (mounted) context.appError('无法打开关联单据，请刷新后重试', force: true);
      }
    }
    if (!mounted) return;
    setState(() {
      if (selection?.executionSegmentId != null) {
        _focusedExecutionSegmentId = selection!.executionSegmentId;
      }
      _executionSegmentsRevision++;
    });
    await _loadSubplans();
  }

  Future<void> _changePlanningPackageLifecycle(
    ProductionPlanningConfirmResult result,
    ProductionPlanningPackageLifecycleAction action,
  ) async {
    final isCancel = action == ProductionPlanningPackageLifecycleAction.cancel;
    final verb = isCancel ? '取消' : '冲销';
    final reasonController = TextEditingController();
    String? validationError;
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('$verb生产计划包'),
          content: SizedBox(
            width: utenDialogWidth(dialogContext, 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  isCancel
                      ? '仅未开工且没有执行事实的计划包可取消。系统会原子释放占用并关闭可撤销的下游草稿。'
                      : '仅未开工且没有执行事实的计划包可冲销。系统会保留审计历史并回退可逆事实。',
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: reasonController,
                  maxLength: 500,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: '$verb原因',
                    hintText: '请填写具体业务原因',
                    error: utenFieldError(validationError),
                  ),
                ),
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('返回核对'),
            ),
            UtenButton(
              type: UtenButtonType.danger,
              onPressed: () {
                final value = reasonController.text.trim();
                if (value.isEmpty) {
                  setDialogState(() => validationError = '必须填写原因');
                  return;
                }
                Navigator.pop(dialogContext, value);
              },
              child: Text('确认$verb'),
            ),
          ],
        ),
      ),
    );
    reasonController.dispose();
    if (reason == null || !mounted) return;

    setState(() => _executionBusy = true);
    try {
      await ref
          .read(productionPlanRepositoryProvider)
          .changePlanningPackageLifecycle(
            widget.id,
            result.packageId,
            action,
            idempotencyKey: businessIdempotencyKey(
              'production-planning-package-${action.pathSegment}',
              '${widget.id}|${result.packageId}|$reason',
            ),
            reason: reason,
          );
      if (!mounted) return;
      context.appSuccess('生产计划包已$verb');
      setState(() => _executionSegmentsRevision++);
      await _load();
    } on ApiException catch (error) {
      if (mounted) context.appError(error.message, force: true);
    } catch (_) {
      if (mounted) context.appError('生产计划包$verb失败，请刷新后重试', force: true);
    } finally {
      if (mounted) setState(() => _executionBusy = false);
    }
  }

  Future<_PlanningResultSelection?> _showPlanningPackageResult(
    ProductionPlanningConfirmResult result,
  ) {
    return showDialog<_PlanningResultSelection>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: utenDialogInsetPadding(ctx),
        title: const Text('生产下达结果'),
        content: SizedBox(
          width: utenDialogWidth(ctx, 720),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.68,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.inventory_2_outlined, size: 20),
                  title: Text('计划包 ${result.packageId}'),
                  subtitle: Text(
                    '状态 ${result.status} · '
                    '自制子计划 ${result.subplans.length} 张 · '
                    '执行分段 ${result.executionSegments.length} 个',
                  ),
                ),
                for (final subplan in result.subplans)
                  ListTile(
                    dense: true,
                    onTap: () => Navigator.pop(
                      ctx,
                      _PlanningResultSelection.route(
                        RoutePath.productionPlanDetail(subplan.planId),
                      ),
                    ),
                    leading: const Icon(Icons.account_tree_outlined, size: 20),
                    title: Text('自制件子计划 ${subplan.billNo ?? subplan.planId}'),
                    subtitle: Text(
                      '${subplan.lineCount} 行 · '
                      '${subplan.workshopName ?? '车间待分配'} · 点击打开计划单',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                  ),
                if (result.replayed)
                  const ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.replay_circle_filled_outlined,
                      size: 20,
                    ),
                    title: Text('已加载现有计划包结果，未重复锁料或开单'),
                  ),
                if (result.purchaseRequest != null)
                  ListTile(
                    dense: true,
                    onTap: () => Navigator.pop(
                      ctx,
                      _PlanningResultSelection.route(
                        RoutePath.purchaseDocDetail(
                          'requests',
                          result.purchaseRequest!.requestId,
                        ),
                      ),
                    ),
                    leading: const Icon(Icons.shopping_cart_outlined, size: 20),
                    title: Text(
                      '采购申请 ${result.purchaseRequest!.requestBillNo}',
                    ),
                    subtitle: Text(
                      '${result.purchaseRequest!.lineCount} 行缺料 · 已挂接待料执行段',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                  ),
                if (result.subcontractApplication != null)
                  ListTile(
                    dense: true,
                    onTap: () => Navigator.pop(
                      ctx,
                      _PlanningResultSelection.route(
                        RoutePath.subcontractDocDetail(
                          'applications',
                          result.subcontractApplication!.requestId,
                        ),
                      ),
                    ),
                    leading: const Icon(
                      Icons.precision_manufacturing_outlined,
                      size: 20,
                    ),
                    title: Text(
                      '委外申请 ${result.subcontractApplication!.requestBillNo}',
                    ),
                    subtitle: Text(
                      '${result.subcontractApplication!.lineCount} 行委外缺口 · 已按执行段精确挂接',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                  ),
                for (final document in <ProductionGeneratedDocument>[
                  ...result.drawDocuments,
                  if (result.drawDocuments.isEmpty &&
                      result.drawDocument != null)
                    result.drawDocument!,
                ])
                  ListTile(
                    dense: true,
                    onTap: () => Navigator.pop(
                      ctx,
                      _PlanningResultSelection.route(
                        RoutePath.stockDocDetail('DRAW', document.requestId),
                      ),
                    ),
                    leading: const Icon(Icons.outbound_outlined, size: 20),
                    title: Text('领料单 ${document.requestBillNo}'),
                    subtitle: Text('${document.lineCount} 行 · 点击打开领料单'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                  ),
                for (final segment in result.executionSegments)
                  ListTile(
                    dense: true,
                    onTap: () => Navigator.pop(
                      ctx,
                      _PlanningResultSelection.executionSegment(
                        segment.segmentId,
                      ),
                    ),
                    leading: Icon(
                      segment.status == 'READY'
                          ? Icons.play_circle_outline
                          : Icons.hourglass_bottom_rounded,
                      size: 20,
                      color: segment.status == 'READY'
                          ? Colors.green
                          : Theme.of(ctx).colorScheme.error,
                    ),
                    title: Text(
                      '${segment.segmentCode} · 数量 '
                      '${formatProductionPlanningQuantity(segment.plannedQty)}',
                    ),
                    subtitle: Text(
                      segment.status == 'READY'
                          ? '已齐套待派工/发料 · 已按该执行段锁料 · 点击查看详情'
                          : '待料或人工暂缓 · 当前零锁料 · 点击查看详情',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                  ),
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          if (result.executionSegments.isNotEmpty)
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(
                ctx,
                const _PlanningResultSelection.printWorkCards(),
              ),
              icon: const Icon(Icons.print_outlined, size: 18),
              label: const Text('预览 / 打印生产执行工卡'),
            ),
          if (result.status == 'CONFIRMED' && _canCancelPlanningPackage)
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(
                ctx,
                const _PlanningResultSelection.lifecycle(
                  ProductionPlanningPackageLifecycleAction.cancel,
                ),
              ),
              icon: const Icon(Icons.cancel_outlined, size: 18),
              label: const Text('取消计划包'),
            ),
          if (result.status == 'CONFIRMED' && _canReversePlanningPackage)
            UtenButton(
              type: UtenButtonType.danger,
              icon: Icons.undo_outlined,
              onPressed: () => Navigator.pop(
                ctx,
                const _PlanningResultSelection.lifecycle(
                  ProductionPlanningPackageLifecycleAction.reverse,
                ),
              ),
              child: const Text('冲销计划包'),
            ),

          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Future<void> _openMaterialSettlement() async {
    final closed = await showProductionMaterialSettlementSheet(
      context,
      ref,
      planId: widget.id,
      canSettle: _canSettleMaterials,
      canReverse: _canReverseMaterialSettlement,
      canClose: _canCloseProductionTask,
    );
    if (closed == true && mounted) {
      await _load();
    }
  }

  /// 已审核计划只保留真实执行结果与材料台账入口。
  ///
  /// 物料齐套和计划生成统一在「物料分析准备」完成；计划详情不再提供第二套
  /// MRP 估算、选仓预排或补建计划包入口，避免直接自制的零物料计划被误报为
  /// 结构缺失错误。
  Widget _executionDocumentsCard(ThemeData theme) {
    return Card(
      key: const Key('production-execution-documents-card'),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '执行单据与物料台账',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        '查看审核下达形成的执行子计划、领料单和工卡；'
                        '材料退库与结清以仓库实际发料为准。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                UtenButton(
                  key: const Key('production-open-execution-documents'),
                  type: UtenButtonType.tonal,
                  icon: Icons.receipt_long_outlined,
                  isLoading: _executionBusy,
                  onPressed: _commandBusy ? null : _openLatestPlanningResult,
                  child: const Text('查看执行单据 / 打印工卡'),
                ),
                UtenButton(
                  key: const Key('production-open-material-ledger'),
                  type: UtenButtonType.secondary,
                  icon: Icons.fact_check_outlined,
                  onPressed: _commandBusy ? null : _openMaterialSettlement,
                  child: Text(
                    _canManageProductionMaterials ? '材料退库与结清' : '查看材料台账',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 子计划进度卡：与看板同款圆环进度行（点行跳子计划详情，可继续向下展开）。
  Widget _subplansCard(ThemeData theme) {
    final subs = _subplans;
    if (subs == null || subs.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '子任务 · 子计划(${subs.length} 张)',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            for (final sp in subs) _subplanProgressRow(theme, sp),
          ],
        ),
      ),
    );
  }

  Widget _subplanErrorCard(ThemeData theme) {
    final message = _subplanError;
    if (message == null) return const SizedBox.shrink();
    return Card(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                '子计划列表加载失败：$message',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            TextButton(onPressed: _loadSubplans, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  Widget _subplanProgressRow(ThemeData theme, MrpSubplanRef sp) {
    final pct = sp.percent.clamp(0.0, 1.0);
    final reversed = sp.status == -1;
    final done = !reversed && (sp.closed || pct >= 1.0);
    final statusText = reversed
        ? '红冲'
        : sp.status == 0
        ? '草稿'
        : done
        ? '已完成 ✓'
        : '进行中';
    final statusColor = reversed
        ? theme.colorScheme.onSurfaceVariant
        : sp.status == 0
        ? Colors.orange
        : done
        ? Colors.green
        : Colors.orange;
    String fmt(double? v) => v == null
        ? '—'
        : (v == v.roundToDouble()
              ? v.toStringAsFixed(0)
              : v.toStringAsFixed(2));
    return InkWell(
      borderRadius: UtenRadius.mdAll,
      onTap: () => _openChildPlan(sp),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
        child: Row(
          children: [
            ProgressRing(value: pct, size: 40, fontSize: 10, done: done),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    sp.billNo ?? '—',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      decoration: reversed ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (sp.deliveryDate != null)
                    Text(
                      '交货 ${sp.deliveryDate!.substring(0, 10)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Text(
              '${fmt(sp.inboundQty)} / ${fmt(sp.totalQty)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                statusText,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: statusColor,
                ),
              ),
            ),
            const SizedBox(width: UtenSpacing.s4),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openChildPlan(MrpSubplanRef subplan) async {
    final childPlanId = subplan.planId.trim();
    if (childPlanId.isEmpty || childPlanId == widget.id) {
      context.appError('子计划链接异常，请刷新后重试', force: true);
      return;
    }
    try {
      await context.push(RoutePath.productionPlanDetail(childPlanId));
    } catch (_) {
      if (mounted) context.appError('无法打开子计划，请刷新后重试', force: true);
    }
  }

  Future<void> _delete() async {
    if (!_canDelete) {
      context.appWarning('当前账号没有生产计划删除权限', force: true);
      return;
    }
    if (_commandBusy) {
      context.appWarning('预排或其他计划操作正在处理，请完成后再删除', force: true);
      return;
    }
    final c = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除计划单'),
        content: const Text('确定删除该草稿计划单吗？已审单据请走红冲。'),
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
      await ref.read(productionPlanRepositoryProvider).delete(widget.id);
      if (!mounted) return;
      context.appSuccess('已删除');
      context.go('/production/plans');
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
    final scopeCapability = ref.watch(
      documentScopeCapabilityProvider(DocumentDataScope.productionPlan),
    );
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    return Scaffold(
      appBar: UtenAppBar(
        title: '生产计划单详情',
        leading: UtenBackButton(
          onPressed: () {
            if (_commandBusy) {
              context.appWarning('生产计划操作正在处理，请完成后再离开', force: true);
              return;
            }
            popOrBackTo(context, defaultPath: RouteName.production);
          },
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.tonal,
            icon: Icons.history_rounded,
            onPressed: _commandBusy
                ? null
                : () => context.push('/production/plans'),
            onDisabledTap: () =>
                context.appWarning('生产计划操作正在处理，请完成后再离开', force: true),
            child: const Text('查看历史'),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : _error != null
              ? Center(child: Text(_error!))
              : _detail == null
              ? const SizedBox.shrink()
              : ListView(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  children: [
                    DocumentScopeWriteNotice(
                      capability: scopeCapability,
                      ownerEmployeeId: _detail!.makerId,
                      onRetry: () => ref.invalidate(
                        documentScopeCapabilityProvider(
                          DocumentDataScope.productionPlan,
                        ),
                      ),
                    ),
                    _headerCard(theme, names),
                    if (_detail!.status == kProductionStatusDraft) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      _planProductSummary(theme, names),
                    ],
                    if (_hasTraceability) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      _traceabilityCard(theme),
                    ],
                    const SizedBox(height: UtenSpacing.s12),
                    ProductionExecutionSegmentsCard(
                      key: ValueKey('${widget.id}|$_executionSegmentsRevision'),
                      planId: widget.id,
                      canAssign: _canAssignExecution,
                      canReleaseDefer: _canReleaseExecutionDefer,
                      canDispatch: _canDispatchExecution,
                      canStart: _canStartExecution,
                      canReport: _canReport,
                      initialSegmentId: _focusedExecutionSegmentId,
                      onChanged: _loadSubplans,
                    ),
                    if (_detail!.status == kProductionStatusApproved) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      _executionDocumentsCard(theme),
                    ],
                    if (_subplanError != null)
                      const SizedBox(height: UtenSpacing.s12),
                    _subplanErrorCard(theme),
                    if (_subplans != null && _subplans!.isNotEmpty)
                      const SizedBox(height: UtenSpacing.s12),
                    _subplansCard(theme),
                  ],
                ),
        ),
      ),
      bottomNavigationBar: _detail == null ? null : _actions(theme),
    );
  }

  /// 部分溯源投影是否有内容（三组链接任一非空即展示卡片）。
  bool get _hasTraceability {
    final d = _detail;
    if (d == null) return false;
    return d.traceSalesOrders.isNotEmpty ||
        d.traceMaterialDraws.isNotEmpty ||
        d.tracePurchaseRequests.isNotEmpty ||
        d.traceSubcontractApplications.isNotEmpty ||
        d.traceDailyReports.isNotEmpty;
  }

  /// 当前只展示服务端已有结构化联接；不是采购/委外/IQC/报工/发运全链。
  Widget _traceabilityCard(ThemeData theme) {
    final d = _detail!;
    final stockDraws = d.traceMaterialDraws
        .where((link) => link.kind == 'STOCK_DRAW')
        .toList(growable: false);
    final finishedIns = d.traceMaterialDraws
        .where((link) => link.kind == 'FINISHED_IN')
        .toList(growable: false);
    return Card(
      key: const Key('production-plan-traceability'),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '关联单据(部分溯源)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '结构化关联投影：销售订单(含客户/业务员)、领料、成品入库、采购/委外申请、已审核报工；'
              '采购/委外订货、收货、IQC 与发运仍需在各权威单据核对。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (d.traceSalesOrders.isNotEmpty)
              _traceGroup(
                theme,
                label: '来源销售订单',
                icon: Icons.receipt_long_outlined,
                links: d.traceSalesOrders,
                onOpen: (id) =>
                    _openLinkedPage(RoutePath.salesDocDetail('orders', id)),
              ),
            if (stockDraws.isNotEmpty)
              _traceGroup(
                theme,
                label: '生产领料单',
                icon: Icons.outbound_outlined,
                links: stockDraws,
                onOpen: (id) =>
                    _openLinkedPage(RoutePath.stockDocDetail('DRAW', id)),
              ),
            if (finishedIns.isNotEmpty)
              _traceGroup(
                theme,
                label: '成品入库单',
                icon: Icons.inventory_2_outlined,
                links: finishedIns,
                onOpen: (id) => _openLinkedPage(
                  RoutePath.stockDocDetail('FINISHED_IN', id),
                ),
              ),
            if (d.tracePurchaseRequests.isNotEmpty)
              _traceGroup(
                theme,
                label: '采购申请',
                icon: Icons.shopping_cart_outlined,
                links: d.tracePurchaseRequests,
                onOpen: (id) => _openLinkedPage(
                  RoutePath.purchaseDocDetail('requests', id),
                ),
              ),
            if (d.traceSubcontractApplications.isNotEmpty)
              _traceGroup(
                theme,
                label: '委外申请',
                icon: Icons.precision_manufacturing_outlined,
                links: d.traceSubcontractApplications,
                onOpen: (id) => _openLinkedPage(
                  RoutePath.subcontractDocDetail('applications', id),
                ),
              ),
            if (d.traceDailyReports.isNotEmpty)
              _traceGroup(
                theme,
                label: '报工单(已审核)',
                icon: Icons.edit_note_outlined,
                links: d.traceDailyReports,
                onOpen: (id) =>
                    _openLinkedPage('/production/daily-reports/$id'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _traceGroup(
    ThemeData theme, {
    required String label,
    required IconData icon,
    required List<ProductionPlanTraceLink> links,
    required void Function(String id) onOpen,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: UtenSpacing.s4),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s4),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s4,
            children: [
              for (final link in links)
                ActionChip(
                  key: ValueKey(
                    'production-plan-trace-${link.kind}-${link.id}',
                  ),
                  avatar: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: Text(
                    (link.billNo ?? link.id) +
                        (link.clientName == null || link.clientName!.isEmpty
                            ? ''
                            : ' · ${link.clientName}') +
                        (link.sellerName == null || link.sellerName!.isEmpty
                            ? ''
                            : ' · ${link.sellerName}'),
                  ),
                  onPressed: () => onOpen(link.id),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _headerCard(ThemeData theme, MasterNameService names) {
    final d = _detail!;
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('单据日期', d.billDate),
      _KV('制单员', d.makerName),
      _KV('制单时间', utenFmtIsoTime(d.createdAt)),
      if ((d.fStyle ?? '').isNotEmpty) _KV('生产类型', d.fStyle),
      if (d.deliveryDate != null) _KV('交货日', d.deliveryDate),
      if (d.departmentId != null || (d.workshopName ?? '').isNotEmpty)
        _KV(
          '车间',
          d.departmentId != null
              ? names.department(d.departmentId)
              : d.workshopName,
        ),
      if (d.workerId != null || (d.workerName ?? '').isNotEmpty)
        _KV(
          '计划负责人',
          d.workerId != null ? names.employee(d.workerId) : d.workerName,
        ),
      if (d.sellerId != null || (d.sellerName ?? '').isNotEmpty)
        _KV(
          '跟单员',
          d.sellerId != null ? names.employee(d.sellerId) : d.sellerName,
        ),
      if ((d.sourceDocNo ?? '').isNotEmpty) _KV('来源单号', d.sourceDocNo),
      if ((d.remark ?? '').isNotEmpty) _KV('备注', d.remark),
      _KV(
        '状态',
        null,
        badge: ProductionStatusBadge(
          status: d.status,
          closed: d.closed,
          stopped: d.stopped,
          canceled: d.canceled,
        ),
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final r in rows) _kvRow(theme, r)],
        ),
      ),
    );
  }

  Widget _kvRow(ThemeData theme, _KV r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              r.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: r.badge ?? Text(r.value ?? '—')),
        ],
      ),
    );
  }

  /// Draft-only product context. Approved plans use execution cards as the
  /// authoritative operational surface while the item model remains intact.
  Widget _planProductSummary(ThemeData theme, MasterNameService names) {
    final items = _detail!.items;
    String quantity(double? value) {
      if (value == null) return '—';
      return value == value.roundToDouble()
          ? value.toStringAsFixed(0)
          : value.toStringAsFixed(2);
    }

    final totalQty = items.fold<double>(
      0,
      (sum, item) => sum + (item.qty ?? 0),
    );
    final namesPreview = [
      for (final item in items.take(3)) names.goods(item.goodsId),
    ].join('、');
    final first = items.firstOrNull;
    final firstMeta = first == null
        ? const <String>[]
        : [
            first.productNo,
            names.color(first.colorId),
            names.unit(first.unitId),
            if ((first.salesOrderNo ?? '').isNotEmpty)
              '销售订单 ${first.salesOrderNo!}',
          ].whereType<String>().where((value) => value != '—').toList();
    final singleSummary = first == null
        ? ''
        : '${names.goods(first.goodsId)}'
              '${firstMeta.isEmpty ? '' : ' · ${firstMeta.join(' · ')}'}'
              ' · 计划 ${quantity(first.qty)}'
              '${first.outboundDate == null ? '' : ' · 交货 ${productionDateOnly(first.outboundDate)}'}';
    final multiSummary =
        '$namesPreview'
        '${items.length > 3 ? ' 等 ${items.length} 项' : ''}'
        ' · 排产合计 ${quantity(totalQty)}';

    return Card(
      key: const Key('production-plan-draft-product-summary'),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '计划产品摘要',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (items.isEmpty)
                    Text(
                      '暂无计划产品',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  else if (items.length == 1)
                    Text(singleSummary)
                  else
                    Text(multiSummary),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions(ThemeData theme) {
    final s = _detail!.status;
    final children = <Widget>[];
    if (s == kProductionStatusDraft) {
      if (_isMaterialAnalysisPlan) {
        children.add(
          UtenButton(
            key: const Key('return-to-material-analysis'),
            type: UtenButtonType.secondary,
            icon: Icons.fact_check_outlined,
            onPressed: _commandBusy || !_canReturnToMaterialAnalysis
                ? null
                : () => _openLinkedPage(
                    RouteName.productionMaterialAnalysis,
                    extra: ProductionMaterialAnalysisSeed(
                      analysisId: _detail!.materialAnalysisId,
                    ),
                  ),
            onDisabledTap: !_canReturnToMaterialAnalysis
                ? () => context.appWarning(
                    '没有查看该物料分析的权限，或该任务不在当前负责范围',
                    force: true,
                  )
                : () => context.appWarning(
                    '预排或其他计划操作正在处理，请完成后再返回物料分析',
                    force: true,
                  ),
            child: const Text('回到物料分析'),
          ),
        );
      } else {
        if (_canDelete) {
          children.add(
            UtenButton(
              type: UtenButtonType.danger,
              icon: Icons.delete_outline,
              onPressed: _commandBusy ? null : _delete,
              onDisabledTap: () =>
                  context.appWarning('预排或其他计划操作正在处理，请完成后再删除', force: true),
              child: const Text('删除'),
            ),
          );
        }
        if (_canEdit) {
          if (children.isNotEmpty) {
            children.add(const SizedBox(width: UtenSpacing.s8));
          }
          children.add(
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.edit_outlined,
              onPressed: _commandBusy
                  ? null
                  : () =>
                        _openLinkedPage('/production/plans/${widget.id}/edit'),
              onDisabledTap: () =>
                  context.appWarning('预排或其他计划操作正在处理，请完成后再编辑', force: true),
              child: const Text('编辑'),
            ),
          );
        }
      }
      if (_canApprove) {
        if (children.isNotEmpty) {
          children.add(const SizedBox(width: UtenSpacing.s8));
        }
        children.add(
          UtenButton(
            icon: Icons.check_circle_outline,
            onPressed: _commandBusy ? null : _approve,
            onDisabledTap: () =>
                context.appWarning('预排或其他计划操作正在处理，请完成后再审核', force: true),
            child: const Text('审核'),
          ),
        );
      }
    } else if (s == kProductionStatusApproved && _canReverse) {
      children.add(
        UtenButton(
          type: UtenButtonType.danger,
          icon: Icons.undo_outlined,
          onPressed: _commandBusy ? null : _reverse,
          onDisabledTap: () =>
              context.appWarning('生产计划操作正在处理，请完成后再红冲', force: true),
          child: const Text('红冲'),
        ),
      );
    }
    if (children.isEmpty) {
      children.add(
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: _commandBusy
              ? null
              : () => context.go('/production/plans'),
          onDisabledTap: () =>
              context.appWarning('生产计划操作正在处理，请完成后再离开', force: true),
          child: const Text('返回列表'),
        ),
      );
    }
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

class _PlanningResultSelection {
  const _PlanningResultSelection._({
    this.route,
    this.executionSegmentId,
    this.printWorkCards = false,
    this.lifecycleAction,
  });

  const _PlanningResultSelection.route(String route) : this._(route: route);

  const _PlanningResultSelection.executionSegment(String executionSegmentId)
    : this._(executionSegmentId: executionSegmentId);

  const _PlanningResultSelection.printWorkCards()
    : this._(printWorkCards: true);
  const _PlanningResultSelection.lifecycle(
    ProductionPlanningPackageLifecycleAction action,
  ) : this._(lifecycleAction: action);

  final String? route;
  final String? executionSegmentId;
  final ProductionPlanningPackageLifecycleAction? lifecycleAction;
  final bool printWorkCards;
}

class _KV {
  const _KV(this.label, this.value, {this.badge});
  final String label;
  final String? value;
  final Widget? badge;
}
