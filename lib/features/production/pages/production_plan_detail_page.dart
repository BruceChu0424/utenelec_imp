// 生产计划单详情页（全页路由）：主表头卡 + 只读明细子表 + 状态门控操作（审核/红冲/编辑/删除）。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。操作按 production_plan:edit。
// is_closed（CheckFulfill4 派生：所有明细 qty-iqty≤0）/ is_stopped / is_canceled 经徽章副标体现。
// 关联销售订单：明细 salesOrderNo（文本占位，销售模块上线后挂真 FK）。
// 名称解析：货品/颜色/单位经 MasterNameService（跨 feature 复用 purchase 的 provider）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/responsive/dialog_size.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../models/production_execution_planning.dart';
import '../models/production_material_analysis.dart';
import '../widgets/execution_segment_planning_sheet.dart';
import '../models/production_plan.dart';
import '../repositories/production_repository.dart';
import '../widgets/material_review_dialog.dart';
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
  List<MrpRow>? _mrpRows;
  List<MrpSubplanRef>? _subplans;
  bool _mrpLoading = false;
  ProductionPlanningDraftView? _planningDraft;
  bool _planningDraftLoading = false;
  String? _planningDraftError;
  bool _mrpBusy = false;
  String? _mrpError;
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
      _mrpRows = null;
      _subplans = null;
      _planningDraft = null;
      _planningDraftLoading = false;
      _planningDraftError = null;
      _mrpError = null;
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

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.productionPlanEdit);

  bool get _canApprove =>
      ref.read(currentPermissionsProvider).contains(Perm.productionPlanApprove);

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
    return actions.isEmpty || actions.contains(action);
  }

  bool get _commandBusy => _busy || _mrpBusy;

  bool get _canSettleMaterials =>
      ref.read(currentPermissionsProvider).contains(Perm.productionPlanEdit);

  bool get _canReport => ref
      .read(currentPermissionsProvider)
      .contains(Perm.productionDailyReportEdit);

  Future<void> _load() async {
    if (!mounted) return;
    final planId = widget.id;
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
      _loadMrp();
      if (d.status == kProductionStatusDraft) {
        _loadPlanningDraft(planId: planId);
      } else {
        setState(() {
          _planningDraft = null;
          _planningDraftError = null;
        });
      }
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

  Future<void> _loadPlanningDraft({String? planId}) async {
    if (!mounted) return;
    final requestedPlanId = planId ?? widget.id;
    setState(() {
      _planningDraftLoading = true;
      _planningDraftError = null;
    });
    try {
      final draft = await ref
          .read(productionPlanRepositoryProvider)
          .planningDraft(requestedPlanId);
      if (!mounted || widget.id != requestedPlanId) return;
      setState(() {
        _planningDraft = draft;
        _planningDraftLoading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || widget.id != requestedPlanId) return;
      setState(() {
        _planningDraft = null;
        _planningDraftLoading = false;
        _planningDraftError = error.code == 'NOT_FOUND' ? null : error.message;
      });
    } catch (_) {
      if (!mounted || widget.id != requestedPlanId) return;
      setState(() {
        _planningDraft = null;
        _planningDraftLoading = false;
        _planningDraftError = '预排草案加载失败';
      });
    }
  }

  Future<void> _approve() async {
    if (_mrpBusy) {
      context.appWarning('预排方案正在处理，请完成或关闭后再审核', force: true);
      return;
    }
    if (_planningDraftLoading) {
      context.appWarning('正在确认预排草案状态，请稍候再审核', force: true);
      return;
    }
    if (_planningDraftError != null) {
      context.appError('预排草案状态读取失败，请刷新页面后再审核', force: true);
      return;
    }
    final confirm = _planningDraft != null
        ? '本计划已有预排草案。审核与正式下达将在同一事务完成；'
              '任一步失败都会整体回滚，不会留下半套单据。确认继续？'
        : '当前没有已保存的预排草案。本次只审核，不会自动生成计划包；'
              '建议先取消并完成物料评审与预排。若继续，审核后可再补建排产。';
    await _doAction(
      confirm,
      (repo) => repo.approve(widget.id),
      '已审核',
      afterSuccess: _showLatestPlanningResultAfterApproval,
    );
  }

  Future<void> _reverse() => _doAction(
    '红冲将反向冲销，单据保留不可删，确认？',
    (repo) => repo.reverse(widget.id),
    '已红冲',
  );

  Future<void> _doAction(
    String confirm,
    Future<void> Function(ProductionPlanRepository) fn,
    String ok, {
    Future<void> Function(ProductionPlanRepository)? afterSuccess,
  }) async {
    if (_commandBusy) {
      context.appWarning('已有生产计划操作正在处理，请稍候', force: true);
      return;
    }
    final c = await showDialog<bool>(
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

  // ───────────────────────── MRP-lite 面板 ─────────────────────────
  Future<void> _loadMrp() async {
    if (!mounted) return;
    final planId = widget.id;
    setState(() {
      _mrpLoading = true;
      _mrpError = null;
      _subplanError = null;
    });
    final subplansFuture = _loadSubplans(planId: planId);
    try {
      final repo = ref.read(productionPlanRepositoryProvider);
      final rows = await repo.mrpPreview(planId);
      if (!mounted || widget.id != planId) return;
      setState(() {
        _mrpRows = rows;
        _mrpLoading = false;
      });
    } catch (error) {
      if (!mounted || widget.id != planId) return;
      setState(() {
        _mrpLoading = false;
        _mrpError = productionErrorMessage(error, fallback: '物料需求加载失败');
      });
    }
    await subplansFuture;
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
    setState(() => _mrpBusy = true);
    try {
      final result = await ref
          .read(productionPlanRepositoryProvider)
          .latestPlanningPackageResult(widget.id);
      if (!mounted) return;
      await _presentPlanningResult(result);
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'NOT_FOUND') {
        context.appWarning('当前计划尚未生成正式计划包；有编辑权限的调度员可执行补建', force: true);
      } else {
        context.appError(error.message, force: true);
      }
    } catch (_) {
      if (mounted) context.appError('已生成单据加载失败，请稍后重试', force: true);
    } finally {
      if (mounted) setState(() => _mrpBusy = false);
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

  ProductionPlanningDraftView? _compatibleDraftForPreview(
    ProductionPlanningPreview preview,
  ) {
    final draft = _planningDraft;
    if (draft == null || draft.warehouseId != preview.warehouseId) return null;
    final sources = <String, ProductionExecutionSegmentPreview>{
      for (final source in preview.executionSegments)
        source.sourcePlanItemId: source,
    };
    final previewTotals = <String, double>{};
    for (final source in preview.executionSegments) {
      previewTotals.update(
        source.sourcePlanItemId,
        (value) => value + source.plannedQty,
        ifAbsent: () => source.plannedQty,
      );
    }
    final draftTotals = <String, double>{};
    for (final segment in draft.segments) {
      final source = sources[segment.sourcePlanItemId];
      if (source == null || source.bomFingerprint != segment.bomFingerprint) {
        return null;
      }
      draftTotals.update(
        segment.sourcePlanItemId,
        (value) => value + segment.plannedQty,
        ifAbsent: () => segment.plannedQty,
      );
    }
    if (previewTotals.length != draftTotals.length) return null;
    for (final entry in previewTotals.entries) {
      final draftQty = draftTotals[entry.key];
      if (draftQty == null ||
          (draftQty - entry.value).abs() > kProductionPlanningQuantityEpsilon) {
        return null;
      }
    }
    return draft;
  }

  Future<bool> _confirmUseFreshProposalAfterDraftConflict() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('已存草案与最新生产结构不一致'),
        content: const SizedBox(
          width: 500,
          child: Text(
            '计划数量、产品行或 BOM 已发生变化，旧草案不能安全套用。'
            '系统不会猜测或修改旧数据；可以取消后核对，也可以基于最新数据重新规划并覆盖当前草案。',
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消并核对'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('使用最新数据重排'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// 唯一排产入口：草稿阶段只保存可恢复预排；已审核无包时，
  /// 服务端重算并在同一事务生成 READY/WAITING、占用与下游单据。
  Future<void> _generatePlanningPackage() async {
    if (_commandBusy) {
      context.appWarning('已有生产计划操作正在处理，请稍候', force: true);
      return;
    }
    final detail = _detail;
    if (detail == null) return;
    final isDraft = detail.status == kProductionStatusDraft;
    final isApproved = detail.status == kProductionStatusApproved;
    if (!isDraft && !isApproved) {
      context.appWarning('仅草稿或已审核计划可以排产', force: true);
      return;
    }

    if (isApproved) {
      setState(() => _mrpBusy = true);
      try {
        final existing = await ref
            .read(productionPlanRepositoryProvider)
            .latestPlanningPackageResult(widget.id);
        if (!mounted) return;
        await _presentPlanningResult(existing);
        return;
      } on ApiException catch (error) {
        if (error.code != 'NOT_FOUND') {
          if (mounted) context.appError(error.message);
          return;
        }
      } catch (_) {
        if (mounted) context.appError('计划包结果加载失败，请稍后重试');
        return;
      } finally {
        if (mounted) setState(() => _mrpBusy = false);
      }
    }
    if (!mounted) return;

    final names = ref.read(masterNameServiceProvider);
    final warehouses = names.warehouseEntries.entries.toList();
    if (warehouses.isEmpty) {
      context.appError('仓库字典未加载，无法按目标发料仓计算齐套', force: true);
      return;
    }
    final savedWarehouseId = _planningDraft?.warehouseId;
    String warehouseId =
        isDraft &&
            savedWarehouseId != null &&
            warehouses.any((warehouse) => warehouse.key == savedWarehouseId)
        ? savedWarehouseId
        : warehouses.first.key;
    final selected = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isDraft ? '选择预排发料仓' : '选择正式发料仓'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isDraft
                      ? '草案将按这个仓库计算齐套与供给缺口，但不会锁料或开单。再次保存会覆盖当前草案。'
                      : '齐套、锁料、采购净缺口和领料单都以这个仓库为准。'
                            '正式下达后若要换仓，必须取消未启动计划包并释放原占用。',
                ),
                const SizedBox(height: UtenSpacing.s12),
                DropdownButtonFormField<String>(
                  initialValue: warehouseId,
                  decoration: const InputDecoration(
                    labelText: '发料仓库',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final warehouse in warehouses)
                      DropdownMenuItem(
                        value: warehouse.key,
                        child: Text(warehouse.value),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => warehouseId = value);
                    }
                  },
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
              child: const Text('计算齐套并规划'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (selected != true) {
      context.appInfo('已取消');
      return;
    }

    setState(() => _mrpBusy = true);
    try {
      final repo = ref.read(productionPlanRepositoryProvider);
      final preview = await repo.planningExecutionPreview(
        widget.id,
        warehouseId,
      );
      final requestedDraft =
          isDraft && _planningDraft?.warehouseId == warehouseId
          ? _planningDraft
          : null;
      final initialDraft = requestedDraft == null
          ? null
          : _compatibleDraftForPreview(preview);
      final initialDraftRebased =
          initialDraft != null &&
          initialDraft.previewFingerprint != preview.fingerprint;
      final materialGoodsIds = <String>{
        for (final material in preview.materials) material.goodsId,
        for (final segment in preview.executionSegments)
          for (final material in segment.materials) material.goodsId,
      };
      await names.loadGoodsNames(materialGoodsIds);
      await names.loadEmployeeNames(<String?>{
        for (final segment in preview.executionSegments)
          segment.responsibleEmployeeId,
        for (final segment
            in requestedDraft?.segments ??
                const <ProductionExecutionSegmentConfirm>[])
          segment.responsibleEmployeeId,
      });
      if (!mounted) return;
      setState(() => _mrpBusy = false);
      if (preview.executionSegments.isEmpty) {
        await _showNoExecutableSegmentsDialog();
        return;
      }
      if (requestedDraft != null && initialDraft == null) {
        final useFresh = await _confirmUseFreshProposalAfterDraftConflict();
        if (!mounted || !useFresh) return;
      }
      final reviewDecision = await showMaterialReviewDialog(
        context,
        preview: preview,
        warehouseName: names.warehouse(warehouseId),
        planBillNo: _detail?.billNo ?? widget.id,
      );
      if (!mounted) return;
      if (reviewDecision == null) {
        context.appInfo('已取消');
        return;
      }
      final ProductionPlanningConfirmRequest? request;
      if (initialDraft != null ||
          reviewDecision.type ==
              MaterialReviewDecisionType.openDetailedPlanning) {
        request = await showExecutionSegmentPlanningSheet(
          context,
          ref,
          preview: preview,
          names: names,
          warehouseName: names.warehouse(warehouseId),
          mode: isDraft
              ? ProductionPlanningSheetMode.draft
              : ProductionPlanningSheetMode.confirm,
          initialDraft: initialDraft,
          initialDraftRebased: initialDraftRebased,
          initialFocusMaterialIds: reviewDecision.focusMaterialIds,
        );
      } else {
        request = reviewDecision.request;
      }
      if (!mounted) return;
      if (request == null) {
        context.appInfo('未提交排产方案');
        return;
      }
      setState(() => _mrpBusy = true);
      if (isDraft) {
        final savedDraft = await repo.savePlanningDraft(widget.id, request);
        if (!mounted) return;
        setState(() {
          _planningDraft = savedDraft;
          _planningDraftError = null;
          _mrpBusy = false;
        });
        await _showPlanningDraftSaved(savedDraft, names);
      } else {
        final result = await repo.confirmExecutionPlanning(widget.id, request);
        if (!mounted) return;
        setState(() => _mrpBusy = false);
        await _presentPlanningResult(result);
      }
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('生成生产计划失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _mrpBusy = false);
    }
  }

  /// 预览无可执行分段时（通常是成品未维护 BOM，或剩余可排量为 0），
  /// 用对话框明确告知原因并引导去货品资料维护 BOM，而不是一闪而过的 toast。
  Future<void> _showNoExecutableSegmentsDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('暂无可排产的执行分段'),
        content: const SizedBox(
          width: 440,
          child: Text(
            '一键生成子计划需要每个成品在「货品资料」维护组成 BOM，'
            '并且计划尚有未排数量。可能原因：\n\n'
            '• 成品尚未维护 BOM（请在货品资料为成品添加组成组件）\n'
            '• 所有计划行的剩余可排数量已为 0（已全部排产）\n'
            '• 成品 BOM 中含自制/委外组件且路线尚未配置',
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              context.go(RouteName.basicinfoGoods);
            },
            child: const Text('前往货品资料'),
          ),
        ],
      ),
    );
  }

  Future<void> _showPlanningDraftSaved(
    ProductionPlanningDraftView draft,
    MasterNameService names,
  ) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('预排草案已保存'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.warehouse_outlined),
                title: Text('发料仓 ${names.warehouse(draft.warehouseId)}'),
                subtitle: Text(
                  '${draft.segmentCount} 个执行段 · '
                  '保存于 ${_planningTimestamp(draft.plannedAt)}',
                ),
              ),
              const Divider(),
              const Text(
                '当前只保存排产方案，不锁料，也不生成采购、委外或领料单。'
                '审核后系统会按草案尝试正式下达；届时可在结果窗口打开关联单据。',
              ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSavedPlanningDraftDetails() async {
    final draft = _planningDraft;
    if (draft == null) return;
    final names = ref.read(masterNameServiceProvider);
    await names.loadGoodsNames(draft.routes.map((route) => route.goodsId));
    await names.loadEmployeeNames(
      draft.segments.map((segment) => segment.responsibleEmployeeId),
    );
    if (!mounted) return;
    final planItems = <String, ProductionPlanItem>{
      for (final item in _detail?.items ?? const <ProductionPlanItem>[])
        item.id: item,
    };
    final routeSummary = draft.routes
        .map((route) {
          final color = route.colorId == null
              ? ''
              : ' / ${names.color(route.colorId)}';
          final routeLabel = switch (route.supplyRoute) {
            'BUY' => '采购',
            'SUBCONTRACT' => '委外',
            _ => route.supplyRoute,
          };
          return '${names.goods(route.goodsId)}$color → $routeLabel';
        })
        .join('；');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('已保存的预排草案'),
        content: SizedBox(
          // AlertDialog 会对 content 做 intrinsic 测量：宽度必须有界。
          // 用屏幕宽度钳制，大屏不超过 980，中/小屏随窗口收缩。
          width: (MediaQuery.sizeOf(ctx).width - 96).clamp(280.0, 980.0),
          height: MediaQuery.sizeOf(ctx).height * 0.68,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '发料仓 ${names.warehouse(draft.warehouseId)} · '
                '${draft.segmentCount} 个执行段 · '
                '保存于 ${_planningTimestamp(draft.plannedAt)}',
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '采购申请：${draft.generatePurchaseRequest ? '审核时生成' : '不生成'} · '
                '采购/委外路线 ${draft.routes.length} 条',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: UtenSpacing.s4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 72),
                child: SingleChildScrollView(
                  child: Text(
                    routeSummary.isEmpty
                        ? '无显式采购/委外路线（自制缺口由服务端推导）'
                        : routeSummary,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '以下是审核时将重新校验并原子下达的精确草案。此处只读；如需修改，关闭后重新预排保存。',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: UtenSpacing.s12),
              Expanded(
                child: MasterDataTableView<ProductionExecutionSegmentConfirm>(
                  embedded: true,
                  columns: [
                    MasterColumnDef(
                      key: 'segment',
                      label: '临时分段号',
                      width: 145,
                      value: (segment) => segment.clientSegmentKey,
                    ),
                    MasterColumnDef(
                      key: 'product',
                      label: '货品 / 编号 / 颜色',
                      width: 280,
                      value: (segment) {
                        final item = planItems[segment.sourcePlanItemId];
                        return [
                              names.goods(item?.goodsId),
                              item?.productNo,
                              names.color(item?.colorId),
                              if (item?.salesOrderNo?.isNotEmpty == true)
                                '订单 ${item!.salesOrderNo}',
                            ]
                            .whereType<String>()
                            .where((value) => value != '—')
                            .join(' · ');
                      },
                    ),
                    MasterColumnDef(
                      key: 'qty',
                      label: '实排数量',
                      width: 100,
                      type: 'number',
                      value: (segment) =>
                          formatProductionPlanningQuantity(segment.plannedQty),
                    ),
                    MasterColumnDef(
                      key: 'status',
                      label: '排产决策',
                      width: 168,
                      value: (segment) => segment.requestedStatus == 'READY'
                          ? '优先生产'
                          : segment.deferUntilManualRelease
                          ? '人工暂缓 / 手动恢复'
                          : '待料 / 齐套自动转产',
                    ),
                    MasterColumnDef(
                      key: 'workshop',
                      label: '生产车间',
                      width: 150,
                      value: (segment) =>
                          names.department(segment.workshopDepartmentId),
                    ),
                    MasterColumnDef(
                      key: 'team',
                      label: '生产班组',
                      width: 150,
                      value: (segment) =>
                          names.department(segment.teamDepartmentId),
                    ),
                    MasterColumnDef(
                      key: 'owner',
                      label: '负责人',
                      width: 130,
                      value: (segment) =>
                          names.employee(segment.responsibleEmployeeId),
                    ),
                    MasterColumnDef(
                      key: 'dates',
                      label: '计划开工 / 完工',
                      width: 210,
                      value: (segment) =>
                          '${segment.planBeginDate ?? '—'} / ${segment.planEndDate ?? '—'}',
                    ),
                  ],
                  items: draft.segments,
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  emptyMessage: '草案没有执行分段',
                ),
              ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _showLatestPlanningResultAfterApproval(
    ProductionPlanRepository repo,
  ) async {
    try {
      final result = await repo.latestPlanningPackageResult(widget.id);
      if (!mounted) return;
      setState(() => _planningDraft = null);
      await _presentPlanningResult(result);
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'NOT_FOUND') {
        context.appInfo('审核已完成，当前没有正式计划包；有编辑权限的调度员可点击“补建正式计划包”');
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
    await _loadMrp();
  }

  static String _planningTimestamp(String value) {
    final parsed = DateTime.tryParse(value)?.toLocal();
    if (parsed == null) return value;
    String two(int number) => number.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} '
        '${two(parsed.hour)}:${two(parsed.minute)}';
  }

  Future<_PlanningResultSelection?> _showPlanningPackageResult(
    ProductionPlanningConfirmResult result,
  ) {
    return showDialog<_PlanningResultSelection>(
      context: context,
      builder: (ctx) => AlertDialog(
        insetPadding: utenDialogInsetPadding(ctx),
        title: const Text('生产下达结果'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: utenDialogWidth(ctx, 720),
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
                  leading: Icon(Icons.replay_circle_filled_outlined, size: 20),
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
                  title: Text('采购申请 ${result.purchaseRequest!.requestBillNo}'),
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
                if (result.drawDocuments.isEmpty && result.drawDocument != null)
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
                    '${segment.segmentCode} · 数量 ${_mrpNumber(segment.plannedQty)}',
                  ),
                  subtitle: Text(
                    segment.status == 'READY'
                        ? '可开工 · 已按该执行段锁料 · 点击查看详情'
                        : '待料或人工暂缓 · 当前零锁料 · 点击查看详情',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                ),
            ],
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
      allowEdit: _canSettleMaterials,
    );
    if (closed == true && mounted) {
      await _load();
    }
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
              '子任务 · 子计划（${subs.length} 张）',
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

  Widget _mrpCard(ThemeData theme, MasterNameService names) {
    final rows = _mrpRows;
    final legacy = rows?.any((row) => row.isLegacyAvailability) ?? false;
    final hasLateInbound =
        rows?.any((row) => row.materialStatus == 'INBOUND_LATE') ?? false;
    final detail = _detail!;
    final isDraft = detail.status == kProductionStatusDraft;
    final canPlan =
        (isDraft || detail.status == kProductionStatusApproved) &&
        !detail.stopped &&
        !detail.canceled;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '物料需求只读估算（MRP）',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_mrpLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton.icon(
                    onPressed: _commandBusy ? null : _loadMrp,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('刷新物料'),
                  ),
              ],
            ),
            Text(
              '估算可用 = 账面库存 − 销售锁定 − 安全库存；及时在途仅计算需求日前可到货数量。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            _mrpNotice(
              theme,
              color: theme.colorScheme.primary,
              icon: Icons.verified_user_outlined,
              text: isDraft
                  ? '下表用于快速浏览物料风险；“预排并保存草案”会按实际发料仓重新计算，'
                        '只保存执行段、数量、车间和日期建议，不锁料、不开单。'
                  : '下表用于快速浏览物料风险；“补建正式计划包”会先读取既有结果，'
                        '已有计划包只返回不可变结果，完全没有时才重新计算并正式下达。'
                        '正式下达会原子写入执行段、物料占用及适用的采购、委外、领料单据。',
            ),
            if (isDraft && _planningDraftLoading) ...[
              const SizedBox(height: UtenSpacing.s8),
              _mrpNotice(
                theme,
                color: theme.colorScheme.primary,
                icon: Icons.hourglass_top_rounded,
                text: '正在读取已保存的预排草案…',
              ),
            ],
            if (isDraft && _planningDraft != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              _mrpNotice(
                theme,
                color: Colors.green,
                icon: Icons.save_outlined,
                text:
                    '已预排草案 · 发料仓 '
                    '${names.warehouse(_planningDraft!.warehouseId)} · '
                    '${_planningDraft!.segmentCount} 个执行段 · '
                    '${_planningTimestamp(_planningDraft!.plannedAt)}。'
                    '再次预排会覆盖本计划当前草案，历史计划数据不会回填或批量改写。',
              ),
            ],
            if (isDraft && _planningDraftError != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              _mrpNotice(
                theme,
                color: theme.colorScheme.error,
                icon: Icons.sync_problem_outlined,
                text:
                    '预排草案读取失败：${_planningDraftError!}。'
                    '可刷新页面重试；不要在状态不明时重复审核。',
              ),
            ],
            if (legacy) ...[
              const SizedBox(height: UtenSpacing.s8),
              _mrpNotice(
                theme,
                color: theme.colorScheme.error,
                icon: Icons.gpp_maybe_outlined,
                text:
                    '当前快速浏览仍是旧口径；一键排产会调用目标仓权威预览重新计算。'
                    '若 BOM、库存或供给挂接不完整，服务端会拒绝提交。',
              ),
            ],
            if (hasLateInbound) ...[
              const SizedBox(height: UtenSpacing.s8),
              _mrpNotice(
                theme,
                color: theme.colorScheme.tertiary,
                icon: Icons.local_shipping_outlined,
                text: '存在在途晚到物料。系统不会因晚到自动重复采购，请先催交、改配到货或人工确认追加采购。',
              ),
            ],
            if (_canEdit && !canPlan) ...[
              const SizedBox(height: UtenSpacing.s8),
              _mrpNotice(
                theme,
                color: theme.colorScheme.onSurfaceVariant,
                icon: Icons.lock_outline_rounded,
                text: '仅草稿或已审核且未停止、未取消的当前计划可进入预排或正式下达。',
              ),
            ],
            if (_canEdit) ...[
              const SizedBox(height: UtenSpacing.s8),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  UtenButton(
                    icon: Icons.account_tree_outlined,
                    isLoading: _mrpBusy,
                    onPressed: _commandBusy || !canPlan
                        ? null
                        : _generatePlanningPackage,
                    onDisabledTap: () => context.appWarning(
                      _commandBusy ? '正在处理，请稍候…' : '当前计划状态不支持预排或正式下达',
                      force: true,
                    ),
                    child: Text(
                      isDraft
                          ? _planningDraft == null
                                ? '预排并保存草案'
                                : '继续编辑并保存草案'
                          : '补建正式计划包',
                    ),
                  ),
                  if (isDraft && _planningDraft != null)
                    OutlinedButton.icon(
                      onPressed: _commandBusy
                          ? null
                          : _showSavedPlanningDraftDetails,
                      icon: const Icon(Icons.preview_outlined, size: 18),
                      label: const Text('查看草案明细'),
                    ),
                ],
              ),
            ],
            if (detail.status == kProductionStatusApproved) ...[
              const SizedBox(height: UtenSpacing.s8),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _commandBusy ? null : _openLatestPlanningResult,
                    icon: const Icon(Icons.receipt_long_outlined, size: 18),
                    label: const Text('查看已生成单据 / 打印工卡'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _commandBusy ? null : _openMaterialSettlement,
                    icon: const Icon(Icons.fact_check_outlined, size: 18),
                    label: Text(_canSettleMaterials ? '材料退库与结清' : '查看材料台账'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: UtenSpacing.s8),
            const Divider(height: 1),
            const SizedBox(height: UtenSpacing.s8),
            if (_mrpError != null)
              _mrpErrorView()
            else if (rows == null)
              const Padding(
                padding: EdgeInsets.all(UtenSpacing.s16),
                child: Center(child: Text('正在加载物料需求…')),
              )
            else if (rows.isEmpty)
              _mrpNotice(
                theme,
                color: theme.colorScheme.error,
                icon: Icons.error_outline_rounded,
                text:
                    '接口已成功返回，但未得到任何 BOM 物料。请检查本计划的每个产品是否已维护并启用 BOM；'
                    '资料补齐前不能判断齐套。',
              )
            else
              _mrpTable(theme, names, rows),
          ],
        ),
      ),
    );
  }

  Widget _mrpTable(
    ThemeData theme,
    MasterNameService names,
    List<MrpRow> rows,
  ) {
    return MasterDataTableView<MrpRow>(
      embedded: true,
      columns: [
        MasterColumnDef(
          key: 'goods',
          label: '物料 / 编码 / 规格',
          width: 250,
          value: (row) {
            final detail = [
              row.goodsCode,
              row.spec,
              names.color(row.colorId),
            ].where((value) => value != null && value != '—').join(' · ');
            return '${row.goodsName ?? names.goods(row.goodsId)}'
                '${detail.isEmpty ? '' : '（$detail）'}';
          },
        ),
        MasterColumnDef(
          key: 'supplyType',
          label: '供应方式',
          width: 90,
          value: (row) => row.selfMade ? '自制' : '外购',
        ),
        MasterColumnDef(
          key: 'unit',
          label: '单位',
          width: 80,
          value: (row) => names.unit(row.unitId),
        ),
        MasterColumnDef(
          key: 'gross',
          label: '总需求',
          width: 90,
          type: 'number',
          value: (row) => _mrpNumber(row.gross),
        ),
        MasterColumnDef(
          key: 'bookStock',
          label: '账面库存',
          width: 90,
          type: 'number',
          value: (row) => _mrpNumber(row.bookStock),
        ),
        MasterColumnDef(
          key: 'salesReserved',
          label: '其他单据占用',
          width: 90,
          type: 'number',
          value: (row) => _mrpNumber(row.salesReserved),
        ),
        MasterColumnDef(
          key: 'safetyStock',
          label: '安全库存',
          width: 90,
          type: 'number',
          value: (row) => _mrpNumber(row.safetyStock),
        ),
        MasterColumnDef(
          key: 'availableNow',
          label: '估算可用',
          width: 90,
          type: 'number',
          value: (row) => _mrpNumber(row.availableNow),
        ),
        MasterColumnDef(
          key: 'openPoTotal',
          label: '全部在途',
          width: 90,
          type: 'number',
          value: (row) => _mrpNumber(row.openPoTotal),
        ),
        MasterColumnDef(
          key: 'openPoOnTime',
          label: '及时在途',
          width: 90,
          type: 'number',
          value: (row) => _mrpNumber(row.openPoOnTime),
        ),
        MasterColumnDef(
          key: 'needDate',
          label: '需求日期',
          width: 110,
          type: 'date',
          value: (row) {
            final value = productionDateOnly(row.needDate);
            return value.isEmpty ? null : value;
          },
        ),
        MasterColumnDef(
          key: 'earliestArrivalDate',
          label: '最早到货',
          width: 110,
          type: 'date',
          value: (row) {
            final value = productionDateOnly(row.earliestArrivalDate);
            return value.isEmpty ? null : value;
          },
        ),
        MasterColumnDef(
          key: 'purchaseNetShortage',
          label: '估算采购缺口',
          width: 100,
          type: 'number',
          value: (row) => _mrpNumber(row.purchaseNetShortage),
        ),
        MasterColumnDef(
          key: 'timelyShortage',
          label: '估算开工缺口',
          width: 100,
          type: 'number',
          value: (row) => _mrpNumber(row.timelyShortage),
        ),
        MasterColumnDef(
          key: 'materialStatus',
          label: '估算状态',
          width: 120,
          value: (row) =>
              row.isLegacyAvailability ? '旧口径 · 待复核' : row.statusLabel,
        ),
      ],
      items: rows,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      rowColor: (row) => _mrpRowColor(theme, row),
      emptyMessage: '暂无物料需求',
    );
  }

  Color? _mrpRowColor(ThemeData theme, MrpRow row) {
    if (row.isLegacyAvailability) {
      return theme.colorScheme.errorContainer.withValues(alpha: 0.2);
    }
    return switch (row.materialStatus) {
      'READY' || 'READY_NOW' || 'READY_BY_DATE' =>
        theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
      'PARTIAL_SHORTAGE' || 'PARTIAL' || 'INBOUND_LATE' =>
        theme.colorScheme.tertiaryContainer.withValues(alpha: 0.28),
      'SHORTAGE' ||
      'BOM_MISSING' => theme.colorScheme.errorContainer.withValues(alpha: 0.28),
      _ => null,
    };
  }

  Widget _mrpErrorView() => ProductionMrpErrorPanel(
    serverMessage: _mrpError!,
    isRetrying: _mrpLoading,
    onRetry: _loadMrp,
  );

  Widget _mrpNotice(
    ThemeData theme, {
    required Color color,
    required IconData icon,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  String? _mrpNumber(double? value) {
    if (value == null) return null;
    return formatProductionPlanningQuantity(value);
  }

  Future<void> _delete() async {
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
                    _headerCard(theme, names),
                    const SizedBox(height: UtenSpacing.s12),
                    _itemsCard(theme, names),
                    if (_hasTraceability) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      _traceabilityCard(theme),
                    ],
                    const SizedBox(height: UtenSpacing.s12),
                    _mrpCard(theme, names),
                    const SizedBox(height: UtenSpacing.s12),
                    ProductionExecutionSegmentsCard(
                      key: ValueKey('${widget.id}|$_executionSegmentsRevision'),
                      planId: widget.id,
                      canEdit: _canEdit,
                      canReport: _canReport,
                      initialSegmentId: _focusedExecutionSegmentId,
                      onChanged: _loadMrp,
                    ),
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
                  '关联单据（部分溯源）',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '结构化关联投影：销售订单（含客户/业务员）、领料、成品入库、采购/委外申请、已审核报工；'
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
                    context.push(RoutePath.salesDocDetail('orders', id)),
              ),
            if (stockDraws.isNotEmpty)
              _traceGroup(
                theme,
                label: '生产领料单',
                icon: Icons.outbound_outlined,
                links: stockDraws,
                onOpen: (id) =>
                    context.push(RoutePath.stockDocDetail('DRAW', id)),
              ),
            if (finishedIns.isNotEmpty)
              _traceGroup(
                theme,
                label: '成品入库单',
                icon: Icons.inventory_2_outlined,
                links: finishedIns,
                onOpen: (id) =>
                    context.push(RoutePath.stockDocDetail('FINISHED_IN', id)),
              ),
            if (d.tracePurchaseRequests.isNotEmpty)
              _traceGroup(
                theme,
                label: '采购申请',
                icon: Icons.shopping_cart_outlined,
                links: d.tracePurchaseRequests,
                onOpen: (id) =>
                    context.push(RoutePath.purchaseDocDetail('requests', id)),
              ),
            if (d.traceSubcontractApplications.isNotEmpty)
              _traceGroup(
                theme,
                label: '委外申请',
                icon: Icons.precision_manufacturing_outlined,
                links: d.traceSubcontractApplications,
                onOpen: (id) => context.push(
                  RoutePath.subcontractDocDetail('applications', id),
                ),
              ),
            if (d.traceDailyReports.isNotEmpty)
              _traceGroup(
                theme,
                label: '报工单（已审核）',
                icon: Icons.edit_note_outlined,
                links: d.traceDailyReports,
                onOpen: (id) => context.push('/production/daily-reports/$id'),
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
          '生产工',
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

  /// 明细区：统一表格样式（MasterDataTableView 嵌入模式，与全站报表/主档同款），
  /// 不再是卡片式拼凑行；口径保留（编号/颜色/单位并入货品列，关联销售订单一并显示）。
  Widget _itemsCard(ThemeData theme, MasterNameService names) {
    final items = _detail!.items;
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
        MasterDataTableView<ProductionPlanItem>(
          embedded: true,
          columns: [
            MasterColumnDef(
              key: 'goods',
              label: '货品 / 编号',
              width: 260,
              value: (it) {
                final sub = [
                  it.productNo,
                  names.color(it.colorId),
                  names.unit(it.unitId),
                ].where((s) => s != '—').join(' · ');
                final so = it.salesOrderNo;
                return '${names.goods(it.goodsId)}'
                    '${sub.isEmpty ? '' : '（$sub）'}'
                    '${(so != null && so.isNotEmpty) ? ' · 销售订单：$so' : ''}';
              },
            ),
            MasterColumnDef(
              key: 'qty',
              label: '排产量',
              width: 90,
              type: 'number',
              value: (it) => it.qty?.toStringAsFixed(2),
            ),
            MasterColumnDef(
              key: 'oqty',
              label: '订货量',
              width: 90,
              type: 'number',
              value: (it) => it.oqty?.toStringAsFixed(2),
            ),
            MasterColumnDef(
              key: 'iqty',
              label: '完工量',
              width: 90,
              type: 'number',
              value: (it) => it.iqty?.toStringAsFixed(2),
            ),
            MasterColumnDef(
              key: 'outboundDate',
              label: '交货日',
              width: 110,
              type: 'date',
              value: (it) => productionDateOnly(it.outboundDate),
            ),
          ],
          items: items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          emptyMessage: '暂无明细',
        ),
      ],
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
                : () => context.push(
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
      } else if (_canEdit && _serverAllowsPlanAction('EDIT')) {
        children
          ..add(
            UtenButton(
              type: UtenButtonType.danger,
              icon: Icons.delete_outline,
              onPressed: _commandBusy ? null : _delete,
              onDisabledTap: () =>
                  context.appWarning('预排或其他计划操作正在处理，请完成后再删除', force: true),
              child: const Text('删除'),
            ),
          )
          ..add(const SizedBox(width: UtenSpacing.s8))
          ..add(
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.edit_outlined,
              onPressed: _commandBusy
                  ? null
                  : () => context.push('/production/plans/${widget.id}/edit'),
              onDisabledTap: () =>
                  context.appWarning('预排或其他计划操作正在处理，请完成后再编辑', force: true),
              child: const Text('编辑'),
            ),
          );
      }
      if (_canApprove && _serverAllowsPlanAction('APPROVE')) {
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
    } else if (s == kProductionStatusApproved && _canEdit) {
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

@visibleForTesting
class ProductionMrpErrorGuidance {
  const ProductionMrpErrorGuidance({
    required this.title,
    required this.nextStep,
    required this.icon,
  });

  final String title;
  final String nextStep;
  final IconData icon;

  static ProductionMrpErrorGuidance fromServerMessage(String message) {
    final normalized = message.toLowerCase();
    if (_containsAny(normalized, const [
      '多层 bom',
      '下层 bom',
      '超过 10 层',
      '循环引用',
    ])) {
      return const ProductionMrpErrorGuidance(
        title: 'BOM 层级当前无法处理',
        nextStep:
            '请先为半成品建立独立生产计划，或调整 BOM 层级后再刷新。'
            '不要在资料未调整前继续生成执行分段。',
        icon: Icons.account_tree_outlined,
      );
    }
    if (_containsAny(normalized, const [
      '未维护 bom',
      '没有有效 bom',
      '缺少有效 bom',
      '没有可排产的成品行或有效 bom',
      '无物料可领',
    ])) {
      return const ProductionMrpErrorGuidance(
        title: '计划产品缺少有效 BOM',
        nextStep:
            '请逐项检查计划产品，在基础资料中维护并启用 BOM；'
            '所有计划行都有有效 BOM 后再刷新物料需求。',
        icon: Icons.inventory_2_outlined,
      );
    }

    final mentionsColor =
        normalized.contains('颜色') || normalized.contains('color');
    final mentionsUnit =
        normalized.contains('单位') ||
        normalized.contains('换算率') ||
        normalized.contains('unit');
    if (mentionsColor && mentionsUnit) {
      return const ProductionMrpErrorGuidance(
        title: 'BOM 颜色或单位资料不完整',
        nextStep:
            '请检查相关 BOM 组件的颜色映射、基本单位和换算率；'
            '无颜色组件也应按系统约定维护，修正后再刷新。',
        icon: Icons.rule_folder_outlined,
      );
    }
    if (mentionsColor) {
      return const ProductionMrpErrorGuidance(
        title: 'BOM 颜色映射无效',
        nextStep:
            '请检查相关 BOM 组件及货品档案的颜色资料；'
            '确认无颜色组件符合系统约定后再刷新。',
        icon: Icons.palette_outlined,
      );
    }
    if (mentionsUnit) {
      return const ProductionMrpErrorGuidance(
        title: '物料单位或换算率无效',
        nextStep:
            'BOM 用量按组件货品基本单位计算，不另设 BOM 单位。'
            '请维护货品基本单位；仅对仍有未收数量的采购行，'
            '确认采购单位有效且换算率大于 0。'
            '没有未完成采购行时不受这项校验影响。',
        icon: Icons.straighten_outlined,
      );
    }
    return const ProductionMrpErrorGuidance(
      title: '物料需求接口校验失败',
      nextStep:
          '请按下方服务端原始提示检查计划或物料资料后重试；'
          '若仍失败，请将完整提示交给系统管理员排查。',
      icon: Icons.sync_problem_outlined,
    );
  }

  static bool _containsAny(String value, List<String> patterns) =>
      patterns.any(value.contains);
}

@visibleForTesting
class ProductionMrpErrorPanel extends StatelessWidget {
  const ProductionMrpErrorPanel({
    super.key,
    required this.serverMessage,
    required this.onRetry,
    this.isRetrying = false,
  });

  final String serverMessage;
  final VoidCallback onRetry;
  final bool isRetrying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final guidance = ProductionMrpErrorGuidance.fromServerMessage(
      serverMessage,
    );
    return Semantics(
      liveRegion: true,
      label: '物料需求加载失败：${guidance.title}',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.32),
          border: Border.all(
            color: theme.colorScheme.error.withValues(alpha: 0.5),
          ),
          borderRadius: UtenRadius.smAll,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(guidance.icon, color: theme.colorScheme.error),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    guidance.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '下一步：${guidance.nextStep}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Text(
                    '服务端原始提示',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  SelectableText(
                    serverMessage,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 480;
                      final button = UtenButton(
                        type: UtenButtonType.tonal,
                        icon: Icons.refresh_rounded,
                        isLoading: isRetrying,
                        isExpanded: compact,
                        onPressed: isRetrying ? null : onRetry,
                        child: Text(isRetrying ? '正在重试' : '重试加载'),
                      );
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: compact
                            ? SizedBox(width: double.infinity, child: button)
                            : button,
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
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
  });

  const _PlanningResultSelection.route(String route) : this._(route: route);

  const _PlanningResultSelection.executionSegment(String executionSegmentId)
    : this._(executionSegmentId: executionSegmentId);

  const _PlanningResultSelection.printWorkCards()
    : this._(printWorkCards: true);

  final String? route;
  final String? executionSegmentId;
  final bool printWorkCards;
}

class _KV {
  const _KV(this.label, this.value, {this.badge});
  final String label;
  final String? value;
  final Widget? badge;
}
