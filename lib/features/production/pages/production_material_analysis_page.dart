import 'dart:async';

import 'package:flutter/material.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../features/basic_data/models/master_facet.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/uten_tree_table_cell.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/production_material_analysis.dart';
import '../models/production_flow_stage.dart';
import '../models/production_work_card.dart';
import '../providers/material_analysis_warehouse_prefs_provider.dart';
import '../providers/production_execution_refresh.dart';
import '../repositories/production_repository.dart';
import '../widgets/material_reallocation_dialog.dart';
import '../widgets/production_execution_card_print_preview.dart';
import '../widgets/production_flow_stage_cell.dart';
import '../widgets/material_borrow_dialog.dart';
import '../widgets/material_required_reason_dialog.dart';
import '../widgets/material_supply_progress_dialog.dart';
import '../widgets/material_supply_submit_confirm.dart';

part 'material_analysis_bom_tree.dart';
part 'material_analysis_borrow.dart';
part 'material_analysis_bucket_detail.dart';
part 'material_analysis_candidates.dart';
part 'material_analysis_plan_actions.dart';
part 'material_analysis_product_tasks.dart';
part 'material_analysis_material_table.dart';
part 'material_analysis_supply_actions.dart';
part 'material_analysis_view_models.dart';

/// 独立、预计划的物料分析工作台。
///
/// No BOM or inventory arithmetic lives here. Every readiness quantity and
/// plan eligibility decision is returned by the server and protected by a
/// version/fingerprint pair.
class ProductionMaterialAnalysisPage extends ConsumerStatefulWidget {
  const ProductionMaterialAnalysisPage({
    super.key,
    this.seed = const ProductionMaterialAnalysisSeed(),
  });

  final ProductionMaterialAnalysisSeed seed;

  @override
  ConsumerState<ProductionMaterialAnalysisPage> createState() =>
      _ProductionMaterialAnalysisPageState();
}

abstract class _MaterialAnalysisPageBase
    extends ConsumerState<ProductionMaterialAnalysisPage> {
  static const int _maxAnalysisItems = 500;
  static const int _requestChunkSize = 500;
  static const int _maxPlansPerPrintJob = 50;
  static const int _maxConcurrentPrintLoads = 5;
  static const Duration _analysisPollInterval = Duration(seconds: 45);
  static const _manualSourceTypes = <String, String>{
    'REWORK': '返工',
    'TRIAL': '试制',
    'SAMPLE': '样品',
    'STOCK': '备库',
    'OTHER': '其他',
  };

  ProductionMaterialAnalysisView? _analysis;
  MaterialAnalysisSalesCandidatePage? _candidatePage;
  String? _warehouseId;
  final Set<String> _warehouseIds = {};
  String? _error;
  String? _serverRefreshNotice;
  bool _booting = true;
  bool _loadingCandidates = false;
  bool _previewingAnalysis = false;
  bool _savingRoutes = false;
  bool _savingPriorities = false;
  bool _cancellingAnalysis = false;
  bool _cancellingAction = false;
  bool _claimingSharedFuture = false;
  bool _borrowing = false;
  bool _generating = false;
  bool _planSubmissionApproveNow = false;
  MaterialSupplyRoute? _notifyingRoute;
  int _candidatePageNo = 1;
  final int _candidatePageSize = 100;
  String _candidateKeyword = '';
  final _candidateSearch = TextEditingController();
  final _bomSearch = TextEditingController();
  final _manualSourceRef = TextEditingController();
  final _manualQty = TextEditingController(text: '1');
  final _manualReason = TextEditingController();
  Timer? _analysisPollTimer;
  bool _silentAnalysisReloadInFlight = false;
  GoodsListItem? _manualGoods;
  bool _manualSourceExpanded = false;
  String? _manualSourceType;
  DateTime? _manualDeliveryDate;
  final List<MaterialAnalysisSourceInput> _manualSources = [];
  final Map<String, String> _manualSourceLabels = {};

  late List<MaterialAnalysisSourceInput> _sources;
  final Map<String, TextEditingController> _sourceQtyControllers = {};
  final Map<String, String> _selectedCandidateLabels = {};
  final Map<String, TextEditingController> _batchQtyControllers = {};
  final Map<String, String> _systemSeededBatchQtyTexts = {};

  /// Seed a planning quantity only when the planner has not entered one.
  /// Every product/child entry uses the same complete-kit-first suggestion.
  void _seedSuggestedPlanBatchQty(ProductionMaterialAnalysisProduct product) {
    final controller = _batchQtyControllers.putIfAbsent(
      product.analysisLineId,
      TextEditingController.new,
    );
    final existingSeed = _systemSeededBatchQtyTexts[product.analysisLineId];
    if (existingSeed != null && controller.text != existingSeed) {
      // The value no longer equals our last seed, so it is user-authored.
      _systemSeededBatchQtyTexts.remove(product.analysisLineId);
      return;
    }
    if (controller.text.trim().isNotEmpty && existingSeed == null) return;
    // 2026-09-05 ADR-71：默认数量=剩余需求（齐不齐料由车间侧判断，计划侧
    // 不再按齐套量预拆批）。
    final suggested = product.remainingQty;
    // Do not write the placeholder string "0": a later refresh must be able to
    // seed the newly positive remaining quantity.
    if (!suggested.isFinite || suggested <= 0) return;
    final text = _qty(suggested);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _systemSeededBatchQtyTexts[product.analysisLineId] = text;
  }

  /// Bucket rows are rebuilt when their full-screen table opens. Preserve any
  /// quantity already typed on the host; otherwise default to the remaining
  /// demand (ADR-71：齐套拆批由执行段完成，计划默认全量剩余需求).
  String _planBatchDraftText(ProductionMaterialAnalysisProduct product) {
    _refreshSystemSeededPlanBatchQty(product);
    final existing = _batchQtyControllers[product.analysisLineId]?.text.trim();
    return existing?.isNotEmpty == true
        ? existing!
        : _qty(product.remainingQty);
  }

  void _rememberPlanBatchQty(String analysisLineId, String value) {
    _systemSeededBatchQtyTexts.remove(analysisLineId);
    final controller = _batchQtyControllers[analysisLineId];
    if (controller == null || controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  void _refreshSystemSeededPlanBatchQty(
    ProductionMaterialAnalysisProduct product,
  ) {
    final id = product.analysisLineId;
    final previousSeed = _systemSeededBatchQtyTexts[id];
    final controller = _batchQtyControllers[id];
    if (previousSeed == null || controller == null) return;
    if (controller.text != previousSeed) {
      _systemSeededBatchQtyTexts.remove(id);
      return;
    }
    final suggested = product.remainingQty;
    if (!suggested.isFinite || suggested <= 0) {
      controller.clear();
      _systemSeededBatchQtyTexts.remove(id);
      return;
    }
    final text = _qty(suggested);
    if (controller.text != text) {
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    _systemSeededBatchQtyTexts[id] = text;
  }

  final Set<String> _selectedPlanLineIds = {};
  final Map<String, MaterialSupplyRoute> _routeDraft = {};
  final Map<
    ({String goodsId, String? colorId, String? unitId}),
    MaterialSupplyRoute
  >
  _rememberedRouteDimensions = {};
  final Set<String> _routeMemoryResolvedGoods = {};
  String? _routeMemoryScope;
  String? _routeMemoryPendingKey;
  int _routeMemoryGeneration = 0;
  bool _loadingRouteMemory = false;
  Set<String>? _routeMemoryScopePermissions;
  String? _routeMemoryScopeIdentity;
  String? _routeMemoryComputedScope;

  final Set<String> _dirtyRouteGroups = {};
  final Set<String> _selectedMaterialGroupKeys = {};
  final Set<String> _collapsedBomProducts = {};
  final Set<String> _collapsedBomBranches = {};
  _BomViewMode _bomViewMode = _BomViewMode.all;

  /// BOM 区展示的两种排布：false = 按产品分组的 BOM 树（默认，现状）；
  /// true = 按物料汇总缺料（跨产品聚合同一物料，展开看每条 BOM 路径）。
  /// 只是展示投影：勾选与下达仍落到各自的逐路径节点任务，不合并任务身份。
  bool _bomAggregateByMaterial = false;
  final Set<String> _expandedMaterialAggregates = {};
  String _bomKeyword = '';
  List<String> _priorityDraft = [];
  List<String> _priorityBaseline = [];
  bool _editingPriorities = false;
  int _bomTablePageNo = 1;

  /// BOM 表是否处于全屏（表格全屏路由打开时顶部卡片不可见，搜索框
  /// 借 [MasterDataTableView.onFullscreenChanged] 回到表格工具条）。
  bool _bomTableFullscreen = false;
  String? _bulkOperationLabel;
  int _bulkOperationCompleted = 0;
  int _bulkOperationTotal = 0;
  ProductionMaterialAnalysisView? _indexCacheAnalysis;
  _MaterialAnalysisIndexes? _indexCache;
  ProductionMaterialAnalysisView? _bomProjectionAnalysis;
  _BomViewMode? _bomProjectionMode;
  String? _bomProjectionKeyword;
  _BomFilterProjection? _bomProjectionCache;
  ProductionMaterialAnalysisView? _bucketRowsCacheAnalysis;
  Map<_AnalysisBucket, List<_BucketRow>>? _bucketRowsCache;

  void _invalidateBucketRowsCache() {
    _bucketRowsCacheAnalysis = null;
    _bucketRowsCache = null;
  }

  DateTime _billDate = ChinaDateTime.today();
  DateTime? _deliveryDate;

  Set<String> get _permissions => ref.read(currentPermissionsProvider);
  AppLocalizations get _l10n => AppLocalizations.of(context);
  bool _serverAllows(String action) {
    final analysis = _analysis;
    // 新分析尚无对象级动作清单，创建入口仍由本地权限与服务端端点校验；
    // 一旦加载了持久化分析，动作缺失必须 fail closed，不能因空列表恢复写入口。
    return analysis == null || analysis.allowedActions.contains(action);
  }

  bool get _canManage {
    final required = _analysis == null
        ? Perm.productionMaterialAnalysisCreate
        : Perm.productionMaterialAnalysisRefresh;
    return _permissions.contains(required) && _serverAllows('REFRESH');
  }

  bool get _canRoute =>
      _permissions.contains(Perm.productionMaterialAnalysisRoute) &&
      _serverAllows('CONFIRM_ROUTES');
  bool get _canNotify =>
      _permissions.contains(Perm.productionMaterialAnalysisNotify) &&
      _serverAllows('NOTIFY_SUPPLY');
  bool get _canCancelAnalysis =>
      _permissions.contains(Perm.productionMaterialAnalysisCancel) &&
      _serverAllows('CANCEL_ANALYSIS');
  bool get _canCancelAction =>
      (_permissions.contains(Perm.productionMaterialAnalysisNotify) ||
          _permissions.contains(
            Perm.productionMaterialAnalysisClaimSharedFuture,
          )) &&
      _serverAllows('CANCEL_ACTION');
  bool get _canOverSupply =>
      _permissions.contains(Perm.productionMaterialAnalysisOverSupply) &&
      _serverAllows('OVER_SUPPLY');
  bool get _canClaimSharedFuture =>
      _permissions.contains(Perm.productionMaterialAnalysisClaimSharedFuture) &&
      _serverAllows('CLAIM_SHARED_FUTURE');
  bool get _isFqcReplenishmentOnly => _analysis?.fqcReplenishmentOnly == true;
  bool get _canGenerate =>
      !_isFqcReplenishmentOnly &&
      _permissions.contains(Perm.productionMaterialAnalysisGenerate) &&
      _serverAllows('GENERATE_PLAN');
  bool get _canViewPlans => _permissions.contains(Perm.productionPlanView);
  bool get _canReallocate =>
      _permissions.contains(Perm.productionMaterialAnalysisReallocate) &&
      _serverAllows('REALLOCATE');
  bool get _canCrossReallocate =>
      _permissions.contains(Perm.productionMaterialAnalysisCrossReallocate) &&
      _serverAllows('CROSS_REALLOCATE');

  bool get _busy =>
      _previewingAnalysis ||
      _savingRoutes ||
      _savingPriorities ||
      _cancellingAnalysis ||
      _cancellingAction ||
      _claimingSharedFuture ||
      _borrowing ||
      _generating ||
      _notifyingRoute != null;

  bool get _planSubmissionInProgress => _generating;

  bool get _canAdjustPriorities =>
      _canReallocate &&
      (_analysis?.allowedActions.contains('REALLOCATE') ?? false);

  /// Selection is stored by authoritative task identity across table pages.
  bool _canEditMaterialRoute(_MaterialGroup group) =>
      group.actionable &&
      _planningBlockForGroup(group) == null &&
      group.paths.every(_hasResolvedMaterialSource) &&
      !group.paths.any(
        (path) => path.notifiedTargets.any(
          (target) =>
              target.status != 'CANCELLED' && !target.isReversedRootOutput,
        ),
      );

  String? _planningBlockForGroup(_MaterialGroup group) {
    for (final path in group.paths) {
      final reason = _analysis?.planningBlockedReason(path.analysisLineId);
      if (reason != null) return reason;
    }
    return null;
  }

  bool _hasExistingRootPlan(ProductionMaterialAnalysisProduct product) =>
      product.latestPlanId != null ||
      product.submittedQty > 0 ||
      product.approvedQty > 0;

  MaterialSupplyRoute _draftRoute(_MaterialGroup group) {
    final material = group.representative;
    final explicit = _routeDraft[group.key] ?? material.confirmedRoute;
    if (explicit != null) return explicit;
    final product = _analysis == null
        ? null
        : _analysisIndexes(_analysis!).productsById[material.analysisLineId];
    // A historical production plan proves MAKE even before its new root node
    // has a route-confirmation record. Do not overwrite that fact with memory.
    if (material.isRootSupply &&
        product != null &&
        _hasExistingRootPlan(product)) {
      return MaterialSupplyRoute.make;
    }
    return _rememberedRouteForGoods(
          material.goodsId,
          material.colorId,
          material.unitId,
        ) ??
        material.sourceSuggestion ??
        MaterialSupplyRoute.subcontract;
  }

  String _routeMemoryScopeKey() {
    final session = ref.read(sessionProvider);
    final permissions = _permissions;
    final identity =
        '${session.status}|${session.user?.id}|${session.actor?.id}|'
        '${session.impersonationReadOnly}|${identityHashCode(session.user)}|'
        '${identityHashCode(session.actor)}';
    if (identity == _routeMemoryScopeIdentity &&
        identical(permissions, _routeMemoryScopePermissions)) {
      return _routeMemoryComputedScope!;
    }
    final ordered = permissions.toList()..sort();
    _routeMemoryScopeIdentity = identity;
    _routeMemoryScopePermissions = permissions;
    return _routeMemoryComputedScope = '$identity|${ordered.join(',')}';
  }

  MaterialSupplyRoute? _rememberedRouteForGoods(
    String? goodsId,
    String? colorId,
    String? unitId,
  ) {
    if (goodsId == null || _routeMemoryScope != _routeMemoryScopeKey()) {
      return null;
    }
    return _rememberedRouteDimensions[(
      goodsId: goodsId.trim(),
      colorId: colorId?.trim().isNotEmpty == true ? colorId!.trim() : null,
      unitId: unitId?.trim().isNotEmpty == true ? unitId!.trim() : null,
    )];
  }

  void _clearRememberedRoutes() {
    _routeMemoryGeneration++;
    _routeMemoryScope = null;
    _routeMemoryPendingKey = null;
    _loadingRouteMemory = false;
    _rememberedRouteDimensions.clear();
    _routeMemoryResolvedGoods.clear();
  }

  int get _selectedRouteCount {
    final analysis = _analysis;
    if (analysis == null) return 0;
    return _materialGroups(analysis)
        .where(
          (group) =>
              _selectedMaterialGroupKeys.contains(group.key) &&
              _canEditMaterialRoute(group) &&
              (group.representative.confirmedRoute == null ||
                  _dirtyRouteGroups.contains(group.key)),
        )
        .length;
  }

  // ===== 继承链协作契约：实现在后段 part，基类生命周期按虚调用分发 =====
  Future<void> _previewAnalysis();
  bool _normalizeNewWarehouseScope();
  ProductionMaterialAnalysisMaterial? _rootSupplyMaterialOf(
    ProductionMaterialAnalysisProduct product,
  );
  bool _hasResolvedMaterialSource(ProductionMaterialAnalysisMaterial material);
  String _analysisDynamicProjectionKey(ProductionMaterialAnalysisView view);
  Widget _nodeBorrowSection(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
  );

  Future<void> _loadCandidates({int? page}) async {
    if (_loadingCandidates) return;
    setState(() {
      _loadingCandidates = true;
      _error = null;
      if (page != null) _candidatePageNo = page;
    });
    try {
      final result = await ref
          .read(productionPlanRepositoryProvider)
          .materialAnalysisSalesCandidates(
            page: _candidatePageNo,
            size: _candidatePageSize,
            keyword: _candidateKeyword,
          );
      if (!mounted) return;
      setState(() {
        _candidatePage = result;
        _candidatePageNo = result.page;
        _loadingCandidates = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingCandidates = false;
        _error = productionErrorMessage(error, fallback: '加载待分析销售订单失败');
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _sources = List<MaterialAnalysisSourceInput>.from(widget.seed.sources);
    _warehouseId = widget.seed.warehouseId;
    _warehouseIds.addAll(widget.seed.warehouseIds);
    if (_warehouseId?.isNotEmpty == true) _warehouseIds.add(_warehouseId!);
    _billDate = DateTime.tryParse(widget.seed.billDate ?? '') ?? _billDate;
    _deliveryDate = DateTime.tryParse(widget.seed.deliveryDate ?? '');
    _analysisPollTimer = Timer.periodic(
      _analysisPollInterval,
      (_) => unawaited(_pollAnalysisIfIdle()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  /// 页面停留期间轻量读取服务端权威快照。只在当前路由可见且员工没有进行中
  /// 操作/编辑时触发；它不提交刷新命令，也不会覆盖尚未保存的现场输入。
  Future<void> _pollAnalysisIfIdle() async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (_analysis == null || _booting || _busy || _hasUnsavedAnalysisEditing) {
      return;
    }
    await _reloadAnalysisSilently(protectUnsavedEditing: true);
  }

  bool get _hasUnsavedAnalysisEditing =>
      _editingPriorities ||
      _dirtyRouteGroups.isNotEmpty ||
      _selectedPlanLineIds.isNotEmpty ||
      _batchQtyControllers.entries.any(
        (entry) =>
            entry.value.text.trim().isNotEmpty &&
            _systemSeededBatchQtyTexts[entry.key] != entry.value.text,
      );

  /// 静默重拉当前分析详情（返回即刷新）。本地未保存的路线草稿/勾选按稳定
  /// 操作组键恢复到新快照，避免吞掉计划员正在做的决定。
  Future<void> _reloadAnalysisSilently({
    bool protectUnsavedEditing = false,
  }) async {
    final analysis = _analysis;
    if (analysis == null ||
        _busy ||
        _booting ||
        _silentAnalysisReloadInFlight ||
        (protectUnsavedEditing && _hasUnsavedAnalysisEditing)) {
      return;
    }
    // 产品优先级正在拖动时不替换产品顺序；路线草稿则可以按 action group
    // 安全地映射到新快照，既加载最新库存，又不吞掉计划员的未保存决定。
    if (_editingPriorities) return;
    _silentAnalysisReloadInFlight = true;
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .materialAnalysisDetail(analysis.analysisId);
      if (!mounted) return;
      final current = _analysis;
      // 请求发出后员工可能开始编辑/提交，或者手动刷新已经返回了更高版本。
      // 这两种情况下都丢弃轮询结果，防止迟到的 GET 覆盖新快照或现场输入。
      if (_busy ||
          (protectUnsavedEditing && _hasUnsavedAnalysisEditing) ||
          current == null ||
          current.analysisId != analysis.analysisId ||
          view.version < current.version) {
        return;
      }
      // 分析头版本只保护分析本身的写入 CAS；计划审批、派工、仓库发料、
      // 报工/入库和 exact peg 是读侧动态投影，可能在 version/fingerprint
      // 不变时更新。只有头与动态投影都相同才跳过重建。
      if (view.version == current.version &&
          view.fingerprint == current.fingerprint &&
          _analysisDynamicProjectionKey(view) ==
              _analysisDynamicProjectionKey(current)) {
        return;
      }
      setState(() {
        final drafts = _applyAnalysisPreservingRouteDrafts(view);
        _sources = _reconstructSourcesFromView(view);
        if (drafts.preserved > 0 || drafts.dropped > 0 || drafts.settled > 0) {
          _serverRefreshNotice = _routeDraftRefreshNotice(drafts);
        }
      });
    } catch (_) {
      // 静默失败：页面仍显示当前快照，用户可手动刷新。
    } finally {
      _silentAnalysisReloadInFlight = false;
    }
  }

  @override
  void dispose() {
    _analysisPollTimer?.cancel();
    _candidateSearch.dispose();
    _bomSearch.dispose();
    _manualSourceRef.dispose();
    _manualQty.dispose();
    _manualReason.dispose();
    for (final controller in _sourceQtyControllers.values) {
      controller.dispose();
    }
    for (final controller in _batchQtyControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      await ref.read(masterNameServiceProvider).ensureLoaded();
      if (!mounted) return;
      final existingAnalysisId = widget.seed.analysisId;
      if (existingAnalysisId != null) {
        final view = await ref
            .read(productionPlanRepositoryProvider)
            .materialAnalysisDetail(existingAnalysisId);
        if (!mounted) return;
        setState(() {
          _booting = false;
          _applyAnalysis(view);
          // A persisted analysis is authoritative. Resume seeds can contain a
          // stale or partial sales selection, so always reconstruct the full
          // user-originated source set before any stock recompute. System-made
          // MAKE_COMPONENT children are recreated by the server and excluded.
          _sources = _reconstructSourcesFromView(view);
        });
        // Opening an active writable analysis refreshes its stock/BOM snapshot
        // once. This upgrades legacy persisted rows to the current node-task
        // rules immediately; staff should not have to guess that the old
        // "本批需求为 0" result needs a manual refresh. VIEW-only records remain
        // strictly read-only and keep their persisted historical snapshot.
        if (view.allowedActions.contains('REFRESH') && _canManage) {
          await _previewAnalysis();
        }
        return;
      }
      await ref.read(materialAnalysisWarehousePrefsProvider.notifier).syncNow();
      if (!mounted) return;
      final preference = ref.read(materialAnalysisWarehousePrefsProvider);
      _warehouseId ??= preference.primaryWarehouseId;
      if (!_normalizeNewWarehouseScope()) {
        setState(() {
          _booting = false;
          _error = '尚未维护可用主仓库，无法分析物料';
        });
        return;
      }
      setState(() => _booting = false);
      if (_sources.isNotEmpty) {
        await _previewAnalysis();
      } else {
        await _loadCandidates();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _error = productionErrorMessage(error, fallback: '初始化物料分析失败');
      });
    }
  }

  void _applyAnalysis(ProductionMaterialAnalysisView view) {
    final previousAnalysisId = _analysis?.analysisId;
    _routeMemoryGeneration++;
    _routeMemoryPendingKey = null;
    _loadingRouteMemory = false;
    if (previousAnalysisId != view.analysisId ||
        _routeMemoryScope != _routeMemoryScopeKey()) {
      _clearRememberedRoutes();
    }
    if (previousAnalysisId != null && previousAnalysisId != view.analysisId) {
      for (final controller in _batchQtyControllers.values) {
        controller.dispose();
      }
      _batchQtyControllers.clear();
      _systemSeededBatchQtyTexts.clear();
    }
    _analysis = view;
    _serverRefreshNotice = null;
    _invalidateBucketRowsCache();
    _indexCacheAnalysis = null;
    _indexCache = null;
    _bomProjectionAnalysis = null;
    _bomProjectionCache = null;
    _warehouseId = view.warehouseId ?? _warehouseId;
    _warehouseIds
      ..clear()
      ..addAll(view.warehouseIds);
    if (_warehouseId != null) _warehouseIds.add(_warehouseId!);
    _persistWarehousePreference();
    final originalIndex = {
      for (var index = 0; index < view.products.length; index++)
        view.products[index].analysisLineId: index,
    };
    final orderedProducts = [...view.products]
      ..sort((left, right) {
        final leftPriority =
            left.allocationPriority ?? originalIndex[left.analysisLineId]! + 1;
        final rightPriority =
            right.allocationPriority ??
            originalIndex[right.analysisLineId]! + 1;
        final byPriority = leftPriority.compareTo(rightPriority);
        return byPriority != 0
            ? byPriority
            : originalIndex[left.analysisLineId]!.compareTo(
                originalIndex[right.analysisLineId]!,
              );
      });
    _priorityDraft = [
      for (final product in orderedProducts) product.analysisLineId,
    ];
    _priorityBaseline = List<String>.from(_priorityDraft);
    _editingPriorities = false;
    _routeDraft.clear();
    _dirtyRouteGroups.clear();
    _selectedPlanLineIds.clear();
    final groups = _materialGroups(view);
    final selectableKeys = groups
        .where(_canEditMaterialRoute)
        .map((g) => g.key)
        .toSet();
    _selectedMaterialGroupKeys.removeWhere(
      (key) => !selectableKeys.contains(key),
    );
    for (final group in groups) {
      if (!group.actionable) continue;
      final route = group.representative.confirmedRoute;
      if (route != null) {
        _routeDraft[group.key] = route;
      }
    }
    final validProductIds = view.products
        .map((product) => product.analysisLineId)
        .toSet();
    _collapsedBomProducts.removeWhere(
      (analysisLineId) => !validProductIds.contains(analysisLineId),
    );
    final validNodeKeys = view.materials
        .map((material) => material.materialLineId)
        .toSet();
    _collapsedBomBranches.removeWhere(
      (nodeKey) => !validNodeKeys.contains(nodeKey),
    );
    for (final key
        in _batchQtyControllers.keys
            .where((key) => !validProductIds.contains(key))
            .toList()) {
      _batchQtyControllers.remove(key)?.dispose();
      _systemSeededBatchQtyTexts.remove(key);
    }
    for (final product in view.products) {
      _batchQtyControllers.putIfAbsent(
        product.analysisLineId,
        TextEditingController.new,
      );
      _refreshSystemSeededPlanBatchQty(product);
      // Existing non-empty input is an explicit planner decision. A stock or
      // supply refresh may change the suggestion/cap, but must not silently
      // replace that draft; final validation still checks the latest cap.
    }
  }

  /// 服务端刷新会重建节点视图；只把相对最新快照仍合法的未保存路线覆盖回去。
  /// 外部已修改的确认路线优先；仍合法的本地草稿保留到显式创建时核对。
  ({int preserved, int dropped, int settled})
  _applyAnalysisPreservingRouteDrafts(
    ProductionMaterialAnalysisView view, {
    Map<String, MaterialSupplyRoute> additionalDrafts = const {},
  }) {
    final pendingDrafts = <String, MaterialSupplyRoute>{};
    for (final groupKey in _dirtyRouteGroups) {
      final route = _routeDraft[groupKey];
      if (route == null) continue;
      pendingDrafts[groupKey] = route;
    }
    pendingDrafts.addAll(additionalDrafts);
    final previousRoutes = {
      if (_analysis != null)
        for (final group in _materialGroups(_analysis!))
          group.key: group.representative.confirmedRoute,
    };
    _applyAnalysis(view);
    final currentGroups = {
      for (final group in _materialGroups(view)) group.key: group,
    };
    var preserved = 0;
    var dropped = 0;
    var settled = 0;
    for (final entry in pendingDrafts.entries) {
      final group = currentGroups[entry.key];
      if (group == null) {
        dropped++;
        continue;
      }
      if (group.representative.confirmedRoute == entry.value) {
        settled++;
        continue;
      }
      if (group.representative.confirmedRoute != previousRoutes[entry.key]) {
        dropped++;
        continue;
      }
      if (!_canEditMaterialRoute(group)) {
        dropped++;
        continue;
      }
      _routeDraft[entry.key] = entry.value;
      _dirtyRouteGroups.add(entry.key);
      preserved++;
    }
    return (preserved: preserved, dropped: dropped, settled: settled);
  }

  String _routeDraftRefreshNotice(
    ({int preserved, int dropped, int settled}) drafts,
  ) {
    final parts = <String>['已加载服务端最新物料分析'];
    if (drafts.preserved > 0) {
      parts.add('已保留 ${drafts.preserved} 条未保存路线草稿，请核对后确认');
    }
    if (drafts.settled > 0) {
      parts.add('${drafts.settled} 条路线以服务端最新确认结果为准');
    }
    if (drafts.dropped > 0) {
      parts.add('${drafts.dropped} 条失效路线草稿未恢复');
    }
    return parts.join('；');
  }

  bool _isAnalysisConflict(Object error) =>
      error is ApiException && error.code == 'CONFLICT';

  /// 所有携 version/fingerprint 的写入口遇到 409 后都只读 GET 最新详情。
  /// 不自动重试写操作；服务端事实优先，并只保留相对最新快照仍合法的本地草稿。
  Future<bool> _recoverLatestAnalysisAfterConflict(
    Object error, {
    required String operation,
    Map<String, MaterialSupplyRoute> pendingRouteDrafts = const {},
  }) async {
    if (!_isAnalysisConflict(error) || !mounted) return false;
    final analysisId = _analysis?.analysisId ?? widget.seed.analysisId;
    if (analysisId == null) return false;
    final original = productionErrorMessage(error, fallback: '请求冲突');
    try {
      final latest = await ref
          .read(productionPlanRepositoryProvider)
          .materialAnalysisDetail(analysisId);
      if (!mounted) return true;
      setState(() {
        _error = null;
        final drafts = _applyAnalysisPreservingRouteDrafts(
          latest,
          additionalDrafts: pendingRouteDrafts,
        );
        _sources = _reconstructSourcesFromView(latest);
        final latestNotice =
            drafts.preserved > 0 || drafts.dropped > 0 || drafts.settled > 0
            ? _routeDraftRefreshNotice(drafts)
            : '已加载服务端最新物料分析';
        _serverRefreshNotice = '$operation未自动重试：$original；$latestNotice';
      });
      return true;
    } catch (reloadError) {
      if (!mounted) return true;
      setState(() {
        _error =
            '$operation失败：$original；加载服务端最新结果失败：'
            '${productionErrorMessage(reloadError, fallback: '请稍后重试')}';
      });
      return true;
    }
  }

  /// Rebuilds the user-originated source set from a persisted analysis so a
  /// resumed analysis can be refreshed against current stock. Each non-system
  /// product maps 1:1 to one source identity. Quantities use the original
  /// requested demand; the server keeps submitted/approved tracking internally,
  /// so re-sending requestedQty is a no-op on sources and only triggers a stock
  /// recompute.
  List<MaterialAnalysisSourceInput> _reconstructSourcesFromView(
    ProductionMaterialAnalysisView view,
  ) => [
    for (final product in view.products)
      // MAKE_COMPONENT / SUBCONTRACT_MAKE 都是系统生成的子件任务行，
      // 与服务端 requireSameSources 排除口径一致，不能回填为用户来源。
      if (product.sourceType != 'MAKE_COMPONENT' &&
          product.sourceType != 'SUBCONTRACT_MAKE')
        (product.salesOrderItemId?.isNotEmpty ?? false)
            ? MaterialAnalysisSourceInput(
                salesOrderItemId: product.salesOrderItemId,
                requestedQty: product.requestedQty,
              )
            : MaterialAnalysisSourceInput(
                sourceType: product.sourceType,
                sourceRef: product.sourceRef,
                goodsId: product.goodsId,
                colorId: product.colorId,
                unitId: product.unitId,
                requestedQty: product.requestedQty,
                sourceReason: product.sourceReason,
                deliveryDate: product.deliveryDate,
              ),
  ];

  Future<void> _applyWarehouseSelection(
    String primary,
    Set<String> selected,
  ) async {
    if (_busy ||
        !_canManage ||
        !selected.contains(primary) ||
        selected.isEmpty) {
      return;
    }
    if (selected.length > 100) {
      context.appWarning(_l10n.materialWarehouseLimit);
      return;
    }
    final unchanged =
        primary == _warehouseId &&
        selected.length == _warehouseIds.length &&
        selected.containsAll(_warehouseIds);
    if (unchanged) return;
    final previous = _analysis;
    setState(() {
      _warehouseId = primary;
      _warehouseIds
        ..clear()
        ..addAll(selected);
    });
    if (previous == null) {
      _persistWarehousePreference();
      return;
    }
    await _previewAnalysis();
    if (!mounted) return;
    // A rejected refresh must not relabel unchanged stock facts with a new scope.
    final current = _analysis ?? previous;
    setState(() {
      _warehouseId = current.warehouseId;
      _warehouseIds
        ..clear()
        ..addAll(current.warehouseIds);
      if (_warehouseId != null) _warehouseIds.add(_warehouseId!);
    });
    _persistWarehousePreference();
  }

  void _persistWarehousePreference() {
    final primary = _warehouseId;
    if (primary == null || !_warehouseIds.contains(primary)) return;
    final current = ref
        .read(materialAnalysisWarehousePrefsProvider)
        .normalized();
    final next = MaterialAnalysisWarehousePrefs(
      primaryWarehouseId: primary,
      warehouseIds: _warehouseIds.toList(growable: false),
    ).normalized();
    if (current.primaryWarehouseId == next.primaryWarehouseId &&
        current.warehouseIds.length == next.warehouseIds.length &&
        current.warehouseIds.toSet().containsAll(next.warehouseIds)) {
      return;
    }
    ref.read(materialAnalysisWarehousePrefsProvider.notifier).update(next);
  }

  void _beginPriorityEdit() {
    if (!_canAdjustPriorities || _busy) return;
    setState(() {
      _priorityBaseline = List<String>.from(_priorityDraft);
      _editingPriorities = true;
    });
  }

  void _cancelPriorityEdit() {
    if (_savingPriorities) return;
    setState(() {
      _priorityDraft = List<String>.from(_priorityBaseline);
      _editingPriorities = false;
      _invalidateBucketRowsCache();
    });
  }

  void _movePriority(int index, int offset) {
    if (_savingPriorities) return;
    final target = index + offset;
    if (index < 0 || index >= _priorityDraft.length) return;
    if (target < 0 || target >= _priorityDraft.length) return;
    setState(() {
      final id = _priorityDraft.removeAt(index);
      _priorityDraft.insert(target, id);
      _invalidateBucketRowsCache();
    });
  }

  Future<void> _savePriorities() async {
    final analysis = _analysis;
    if (analysis == null || !_canAdjustPriorities || _savingPriorities) return;
    final productIds = analysis.products
        .map((product) => product.analysisLineId)
        .toSet();
    if (_priorityDraft.length != productIds.length ||
        _priorityDraft.toSet().length != productIds.length ||
        !_priorityDraft.every(productIds.contains)) {
      context.appWarning('产品集合已变化，请刷新物料分析后重新排序');
      return;
    }
    final items = [
      for (var index = 0; index < _priorityDraft.length; index++)
        MaterialAllocationPriorityInput(
          analysisLineId: _priorityDraft[index],
          priority: index + 1,
        ),
    ];
    final key = businessIdempotencyKey(
      'material-analysis-allocation-priorities',
      [
        analysis.analysisId,
        analysis.version,
        analysis.fingerprint,
        for (final item in items) '${item.analysisLineId}:${item.priority}',
      ].join('|'),
    );
    setState(() => _savingPriorities = true);
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .updateMaterialAllocationPriorities(
            analysis: analysis,
            idempotencyKey: key,
            items: items,
          );
      if (!mounted) return;
      setState(() {
        _savingPriorities = false;
        _applyAnalysis(view);
      });
      context.appSuccess('生产优先级已更新，可生产数量已由服务端重新计算');
    } catch (error) {
      if (!mounted) return;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '保存生产优先级',
      )) {
        if (!mounted) return;
        setState(() => _savingPriorities = false);
        return;
      }
      if (!mounted) return;
      setState(() => _savingPriorities = false);
      context.appError(
        productionErrorMessage(error, fallback: '生产优先级保存失败，请刷新后重试'),
        force: true,
      );
    }
  }

  _MaterialAnalysisIndexes _analysisIndexes(
    ProductionMaterialAnalysisView analysis,
  ) {
    if (identical(_indexCacheAnalysis, analysis) && _indexCache != null) {
      return _indexCache!;
    }
    final productsById = {
      for (final product in analysis.products) product.analysisLineId: product,
    };
    final materialsByProduct =
        <String?, List<ProductionMaterialAnalysisMaterial>>{};
    final childrenByParentNodeKey =
        <
          ({String? analysisLineId, String parentNodeKey}),
          List<ProductionMaterialAnalysisMaterial>
        >{};
    final groups = <_MaterialGroup>[];
    final groupsByLine = <String, _MaterialGroup>{};
    for (final material in analysis.materials) {
      materialsByProduct
          .putIfAbsent(material.analysisLineId, () => [])
          .add(material);
      final parentKey = material.parentNodeKey;
      if (parentKey != null && parentKey.isNotEmpty) {
        childrenByParentNodeKey
            .putIfAbsent((
              analysisLineId: material.analysisLineId,
              parentNodeKey: parentKey,
            ), () => [])
            .add(material);
      }
      final group = _MaterialGroup(
        key:
            'NODE|${material.actionGroupKey ?? material.materialLineId}|'
            '${material.materialLineId}',
        paths: [material],
      );
      groups.add(group);
      groupsByLine[material.materialLineId] = group;
    }
    final indexes = _MaterialAnalysisIndexes(
      productsById: productsById,
      materialsByProduct: materialsByProduct,
      groups: groups,
      groupsByLine: groupsByLine,
      childrenByParentNodeKey: childrenByParentNodeKey,
    );
    _indexCacheAnalysis = analysis;
    _indexCache = indexes;
    return indexes;
  }

  List<_MaterialGroup> _materialGroups(
    ProductionMaterialAnalysisView analysis,
  ) => _analysisIndexes(analysis).groups;

  List<String> _readablePath(ProductionMaterialAnalysisMaterial material) =>
      material.path
          .where((segment) => !_looksLikeUuid(segment))
          .toList(growable: false);

  String _pathLabel(ProductionMaterialAnalysisMaterial material) {
    final path = _readablePath(material);
    if (path.isNotEmpty) return path.join(' → ');
    final parent = material.parentLabel?.trim();
    if (parent != null && parent.isNotEmpty && !_looksLikeUuid(parent)) {
      return '$parent → ${material.goodsName ?? material.goodsCode ?? '当前物料'}';
    }
    return '父项待解析';
  }

  bool _looksLikeUuid(String value) => RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  ).hasMatch(value.trim());

  String _analysisStatusText(String? status) => switch (status) {
    null || '' => '待分析',
    'READY' || 'CONFIRMED' || 'ANALYZED' => '已分析',
    'PARTIAL' => '部分齐套',
    'STALE' => '需刷新',
    _ => status,
  };

  String _qty(double? value) {
    if (value == null) return '—';
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value
        .toStringAsFixed(4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  String _dateTimeOnly(String? value) {
    if (value == null || value.isEmpty) return '待计算';
    return value.replaceFirst('T', ' ').split('.').first;
  }

  String _dateOnly(String? value) => value == null || value.isEmpty
      ? '未定'
      : value.length >= 10
      ? value.substring(0, 10)
      : value;

  String? _dateText(DateTime? date) => date == null
      ? null
      : '${date.year.toString().padLeft(4, '0')}-'
            '${date.month.toString().padLeft(2, '0')}-'
            '${date.day.toString().padLeft(2, '0')}';

  bool _canSelectProduct(ProductionMaterialAnalysisProduct product) {
    final root = _rootSupplyMaterialOf(product);
    if (root != null) {
      // 顶层与子层同口径：路线必须显式确认为自制（历史计划只影响草稿预填，
      // 见 _draftRoute 的根分支，不再绕过确认门）。
      final group = _analysisIndexes(
        _analysis!,
      ).groupsByLine[root.materialLineId];
      if (root.confirmedRoute != MaterialSupplyRoute.make ||
          group == null ||
          _dirtyRouteGroups.contains(group.key)) {
        return false;
      }
    }
    return !_productFullyTransferred(product) && product.canSchedule;
  }

  bool _productFullyTransferred(ProductionMaterialAnalysisProduct product) =>
      product.remainingQty <= 0.000001 &&
      _productExecutionStage(product) != null;

  /// 顶层产品 / 计划锚点行的执行阶段（全站唯一词表口径）。
  ///
  /// 服务端 planExecutionStatus 缺失时按提交/审核数量回退推导；
  /// 文案、顺序与语义全部来自 [ProductionFlowStage]，本页不再自造状态。
  ProductionFlowStage? _productExecutionStage(
    ProductionMaterialAnalysisProduct product,
  ) {
    var status = product.planExecutionStatus?.trim().toUpperCase();
    if (status == null || status.isEmpty) {
      if (product.approvedQty > 0) {
        status = 'APPROVED';
      } else if (product.submittedQty > 0 || product.latestPlanId != null) {
        status = 'SUBMITTED';
      } else if (product.requestedQty > 0 && product.remainingQty <= 0.000001) {
        status = 'TRANSFERRED';
      }
    }
    if (status == null || status.isEmpty) return null;
    if (status == 'TRANSFERRED') {
      return const ProductionFlowStage(
        route: ProductionFlowRoute.make,
        key: 'TRANSFERRED',
        label: '本批已全部转生产',
        tone: ProductionFlowTone.pending,
        stepIndex: 5,
        stepCount: 6,
      );
    }
    return ProductionFlowStage.forProduct(
      planExecutionStatus: status,
      zeroMaterial: product.planExecutionZeroMaterial,
      reportedQty: product.planExecutionReportedQty,
      plannedQty: product.planExecutionPlannedQty,
      fallbackRatio: product.planExecutionProgressRatio,
    );
  }

  Widget _statusLabel(ThemeData theme, _StatusView status) => Semantics(
    container: true,
    label: status.label,
    child: ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(status.icon, size: 18, color: status.color),
          const SizedBox(width: UtenSpacing.s4),
          Flexible(
            child: Text(
              status.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: status.color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _errorState(String message, Future<void> Function() retry) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.error_outline_rounded,
          size: 40,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: UtenSpacing.s8),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: UtenSpacing.s8),
        UtenButton(
          type: UtenButtonType.tonal,
          icon: Icons.refresh_rounded,
          onPressed: retry,
          child: const Text('重试'),
        ),
      ],
    ),
  );

  Widget _inlineError(ThemeData theme, String message, VoidCallback retry) =>
      Container(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(child: Text(message)),
            TextButton(onPressed: retry, child: const Text('重试')),
          ],
        ),
      );

  String _materialDimensionKey(ProductionMaterialAnalysisMaterial material) {
    final materialKey = material.materialKey?.trim();
    if (materialKey?.isNotEmpty == true) return materialKey!;
    return [
      material.goodsId ?? material.materialLineId,
      material.colorId ?? 'NONE',
      material.unitId ?? 'NONE',
    ].join('|');
  }

  /// primary/secondary/tertiary——它们同属 teal 色系，层级会糊成一片。
  String _materialStageLabel(ProductionMaterialAnalysisMaterial material) =>
      switch (material.controlStage?.trim().toUpperCase()) {
        'START' => '开工',
        'ASSEMBLY' => '装配',
        'FINISH' || 'PACK' => '完工',
        'SHIP' => '发货参考',
        'WARNING' || 'REFERENCE' => '参考',
        _ => '参考',
      };

  /// 一个操作组通常只对一条路线下达；返回第一个有效目标。
  MaterialAnalysisNotificationTarget? _notifiedTargetOf(
    ProductionMaterialAnalysisMaterial material,
  ) {
    for (final target in material.notifiedTargets) {
      if (target.target == null || target.isRootOutput) continue;
      if (target.status == 'CANCELLED') continue;
      return target;
    }
    return null;
  }

  /// 解析已确认路线的「先自制」委托子产品（MAKE 与有子层委外共用一套：
  /// 优先取持久材料锚点 planAnchorAnalysisLineId，旧载荷只认显式
  /// delegated child ID 或对应 MAKE_TASK.documentId；
  /// 同货可能出现在多条路径，禁止按 parentAnalysisLineId + goodsId 猜测）。
  /// 子产品经 productsById 索引取（原为全产品线性扫描）。
  ProductionMaterialAnalysisProduct? _delegatedChildProductOf(
    ProductionMaterialAnalysisMaterial material, {
    required MaterialSupplyRoute route,
    required String documentType,
    required String sourceType,
  }) {
    final analysis = _analysis;
    if (analysis == null) return null;
    final indexes = _analysisIndexes(analysis);
    String? childId =
        material.planAnchorAnalysisLineId ?? material.delegatedToAnalysisLineId;
    if (childId == null) {
      for (final target in material.notifiedTargets) {
        if (target.target != route ||
            target.isRootOutput ||
            target.status?.toUpperCase() == 'CANCELLED') {
          continue;
        }
        if (target.documentType == documentType && target.documentId != null) {
          childId = target.documentId;
          break;
        }
      }
    }
    if (childId == null) return null;
    final product = indexes.productsById[childId];
    if (product == null || product.sourceType != sourceType) return null;
    return product;
  }

  /// 解析自制通知对应的 MAKE_COMPONENT 子产品（用于待生产/生产中/已完工）。
  ProductionMaterialAnalysisProduct? _makeChildProductOf(
    ProductionMaterialAnalysisMaterial material,
  ) => _delegatedChildProductOf(
    material,
    route: MaterialSupplyRoute.make,
    documentType: 'PREPLAN_MAKE_TASK',
    sourceType: 'MAKE_COMPONENT',
  );

  /// 解析有子层级委外件「先自制」对应的 SUBCONTRACT_MAKE 子产品——与
  /// MAKE 同一条委托链，入库满批/分批后由服务端通知委外部（V458）。
  ProductionMaterialAnalysisProduct? _subcontractMakeChildProductOf(
    ProductionMaterialAnalysisMaterial material,
  ) => _delegatedChildProductOf(
    material,
    route: MaterialSupplyRoute.subcontract,
    documentType: 'SUBCONTRACT_MAKE_TASK',
    sourceType: 'SUBCONTRACT_MAKE',
  );

  /// 已建子件任务节点（MAKE 或有子层 SUBCONTRACT）→ 真实子件产品。
  /// 两类任务完全同构，BOM 原节点内联进度/计划入口统一走这里解析。
  /// 任意一种子任务存在时均视为“已下达”，避免因 route 的首个通知项
  /// 落到其他类型上导致重复出现「等待下达车间」。
  ProductionMaterialAnalysisProduct? _taskChildProductOf(
    ProductionMaterialAnalysisMaterial material,
  ) {
    return _makeChildProductOf(material) ??
        _subcontractMakeChildProductOf(material);
  }

  /// A server-reported issued plan must not become a second executable MAKE
  /// candidate while its exact child projection is unavailable.
  bool _hasUnlinkedIssuedPlan(ProductionMaterialAnalysisMaterial material) {
    if (_taskChildProductOf(material) != null) return false;
    final stage = material.flowStage?.trim().toUpperCase();
    return material.planAnchorAnalysisLineId != null ||
        (stage != null &&
            stage.startsWith('MAKE_') &&
            stage != 'MAKE_PENDING_ISSUE');
  }
}

/// 继承链的最终实现类：保持测试与 createState 引用的原私有名。
class _ProductionMaterialAnalysisPageState
    extends _MaterialAnalysisMaterialTableState {
  /// 任何路径装上新分析快照后只做路线学习预填。
  /// 子件任务必须由计划员在表格/分桶中显式创建，不因刷新、
  /// 轮询或采用路线而隐式下达。
  @override
  void _applyAnalysis(ProductionMaterialAnalysisView view) {
    super._applyAnalysis(view);
    unawaited(
      Future<void>.microtask(() async {
        if (mounted && identical(_analysis, view)) {
          await _prefillRememberedRoutes(view);
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    void reloadMemory() {
      if (_routeMemoryScope == _routeMemoryScopeKey()) return;
      _clearRememberedRoutes();
      final analysis = _analysis;
      if (analysis != null) unawaited(_prefillRememberedRoutes(analysis));
    }

    ref.listen(sessionProvider, (_, _) => reloadMemory());
    ref.listen(currentPermissionsProvider, (_, _) => reloadMemory());

    // 返回即刷新（须与 ref.listen 同位置=build 内注册）：采购/委外到货、IQC 合格放行
    // 等下游事实由服务端在各自事务里重算分析快照；本页从子页面返回时静默重拉详情，
    // 计划员看到的备料进度始终是最新权威值（不写业务事实，纯 GET 安全读）。
    ref.onPageResume(
      RouteName.productionMaterialAnalysis,
      () => _reloadAnalysisSilently(protectUnsavedEditing: true),
    );
    final theme = Theme.of(context);
    final compact = context.breakpoint.isCompact;
    final page = Scaffold(
      appBar: UtenAppBar(
        title: _l10n.productionHubMaterialAnalysis,
        titleWidget: Text(
          _l10n.productionHubMaterialAnalysis,
          style: theme.appBarTheme.titleTextStyle?.copyWith(
            fontFamily: theme.textTheme.titleLarge?.fontFamily,
          ),
        ),
        leading: _planSubmissionInProgress
            ? const SizedBox(width: 48)
            : UtenBackButton(
                onPressed: () => popOrBackTo(
                  context,
                  defaultPath: RouteName.productionSchedule,
                ),
              ),
        actions: [
          if (compact)
            SizedBox(
              width: 48,
              height: 48,
              child: PopupMenuButton<String>(
                tooltip: '打开记录',
                icon: const Icon(Icons.history_rounded),
                enabled: !_busy,
                onSelected: (value) {
                  if (value == 'sheet') {
                    _openSummarySheet();
                  } else if (value == 'analyses') {
                    context.push(RouteName.productionMaterialAnalysisHistory);
                  } else {
                    context.push(RouteName.productionPlanList);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'sheet',
                    child: ListTile(
                      leading: Icon(Icons.summarize_outlined),
                      title: Text('备料汇总预览'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'analyses',
                    child: ListTile(
                      leading: Icon(Icons.fact_check_outlined),
                      title: Text('物料分析记录'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'plans',
                    child: ListTile(
                      leading: Icon(Icons.assignment_outlined),
                      title: Text('生产计划历史'),
                    ),
                  ),
                ],
              ),
            )
          else ...[
            if (_analysis != null) ...[
              UtenButton(
                key: const Key('material-analysis-summary-sheet'),
                type: UtenButtonType.tonal,
                icon: Icons.summarize_outlined,
                onPressed: _busy ? null : _openSummarySheet,
                child: const Text('备料汇总预览'),
              ),
              const SizedBox(width: UtenSpacing.s8),
            ],
            UtenButton(
              type: UtenButtonType.tonal,
              icon: Icons.fact_check_outlined,
              onPressed: _busy
                  ? null
                  : () => context.push(
                      RouteName.productionMaterialAnalysisHistory,
                    ),
              child: const Text('物料分析记录'),
            ),
            const SizedBox(width: UtenSpacing.s8),
            UtenButton(
              type: UtenButtonType.tonal,
              icon: Icons.history_rounded,
              onPressed: _busy
                  ? null
                  : () => context.push(RouteName.productionPlanList),
              child: const Text('生产计划历史'),
            ),
            const SizedBox(width: UtenSpacing.s8),
          ],
          if (_analysis != null)
            if (_canCancelAnalysis)
              IconButton(
                key: const Key('material-analysis-cancel'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                tooltip: '取消分析',
                onPressed: _busy ? null : _cancelCurrentAnalysis,
                icon: const Icon(Icons.cancel_outlined),
              ),
          if (_analysis != null)
            IconButton(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              tooltip: '按最新库存刷新分析',
              onPressed: _busy || !_canManage ? null : _previewAnalysis,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ExcludeFocus(
              excluding: _planSubmissionInProgress,
              child: UtenContentContainer.wide(
                // 本页有分析结果轮询（_analysisPollTimer 周期性结构重建内容），
                // 拖选与轮询重建并发会触发框架 CME（准则 §3.4），故退出选择区。
                selectable: false,
                child: _booting
                    ? const Center(child: CircularProgressIndicator())
                    : _analysis == null
                    ? _candidateBody(theme)
                    : _analysisBody(theme),
              ),
            ),
            if (_planSubmissionInProgress)
              Positioned.fill(child: _planSubmissionOverlay(theme)),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      // 悬浮动作随勾选状态出现/消失，不做进场缩放动画：状态变化后
      // 立即可点（动画中途命中区域为缩放中尺寸，会吃掉点击）。
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _analysis == null
          ? _candidateFloatingAction()
          : _floatingActions(),
    );
    return PopScope(canPop: !_planSubmissionInProgress, child: page);
  }

  Widget _planSubmissionOverlay(ThemeData theme) {
    // ADR-71：下达车间是一次原子调用（建子件任务+出计划+可选审核同一事务），
    // 不再有「校验→生成」两阶段，遮罩只描述这一个不可中断的步骤。
    final title = _planSubmissionApproveNow ? '正在生成并审核下达' : '正在生成生产计划';
    final description = _planSubmissionApproveNow
        ? '系统正在同一事务内创建子件任务、生成计划、审核下达并按需生成提货单。'
        : '系统正在创建计划草稿并提交审批。';

    return BlockSemantics(
      child: Stack(
        alignment: Alignment.center,
        children: [
          ModalBarrier(
            dismissible: false,
            color: theme.colorScheme.scrim.withValues(alpha: 0.42),
            semanticsLabel: '生产计划提交处理中',
          ),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s24),
            child: SingleChildScrollView(
              child: Semantics(
                key: const Key('material-analysis-plan-submission-progress'),
                container: true,
                liveRegion: true,
                label: '$title。$description。请勿重复提交或关闭页面。',
                child: ExcludeSemantics(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Material(
                      color: theme.colorScheme.surface,
                      elevation: 12,
                      borderRadius: UtenRadius.lgAll,
                      child: Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                  ),
                                ),
                                const SizedBox(width: UtenSpacing.s16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                      const SizedBox(height: UtenSpacing.s8),
                                      Text(
                                        description,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                              height: 1.45,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: UtenSpacing.s20),
                            const LinearProgressIndicator(minHeight: 4),
                            const SizedBox(height: UtenSpacing.s12),
                            Row(
                              children: [
                                Icon(
                                  Icons.hourglass_top_rounded,
                                  size: 18,
                                  color: theme.colorScheme.primary,
                                ),
                                const SizedBox(width: UtenSpacing.s8),
                                Expanded(
                                  child: Text(
                                    '请勿重复提交或关闭页面',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _analysisBody(ThemeData theme) {
    final analysis = _analysis!;
    // 悬浮动作区不占布局空间：列表底部预留透明高度，
    // 让末尾内容能滚到悬浮按钮上方，不被常驻遮挡。
    final actionCount = _bottomActionButtons().length;
    final bottomClearance = actionCount == 0
        ? UtenSpacing.s16
        : context.breakpoint.isCompact
        ? 24.0 + actionCount * 60.0
        : 96.0;
    final headerSections = [
      Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s8),
        child: _analysisHeader(theme, analysis),
      ),
      if (_serverRefreshNotice != null)
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: _serverRefreshBanner(theme, _serverRefreshNotice!),
        ),
      Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s8),
        child: _productSection(theme, analysis),
      ),
      // 2026-09-03：独立「委外件前置自制」区块下线——委外子件与自制同构，
      // 账本数量与「通知委外」入口内嵌在产品卡（见 _subcontractMakeTaskPanel）。
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: _inlineError(theme, _error!, _previewAnalysis),
        ),
    ];
    // 无物料任务时不进联动滚动：单一滚动区铺完各区块即可（表格缺席时
    // NestedScrollView 的 body 没有可内滚的主体，联动失去意义）。
    // 手机窄屏同样回退单一滚动区：联动头区（分析卡+横幅+入口条）在窄屏
    // 可能高过视口，NestedScrollView 会把 body 挤成零高、钉住的树顶工具条
    // 随即溢出——窄屏保持「整页滚动 + 有界表格内滚」的既有形态。
    final compact = context.breakpoint.isCompact;
    if (analysis.materials.isEmpty || compact) {
      final hasTable = compact && analysis.materials.isNotEmpty;
      final viewportHeight = MediaQuery.sizeOf(context).height;
      final tableHeight = (viewportHeight * 0.62).clamp(280.0, 620.0);
      return ListView(
        key: const Key('material-analysis-results'),
        children: [
          ...headerSections,
          if (hasTable) ...[
            Padding(
              padding: const EdgeInsets.only(
                top: UtenSpacing.s4,
                bottom: UtenSpacing.s12,
              ),
              child: SizedBox(
                height: tableHeight,
                child: _materialAnalysisTable(theme, analysis, primary: false),
              ),
            ),
          ],
          SizedBox(height: bottomClearance),
        ],
      );
    }
    // 宽屏与货品资料同款「整页先滚、表格吸顶内滚」：上方区块随滚动收起，
    // 表格列头顶到页面顶部后才滚动表体；树顶工具条（查找/视图切换）钉在
    // 表格上方保持可见。表格横滚条按内容高度定位（行少贴末行、超高钉底）。
    return UtenCollapsingHeaderScrollView(
      key: const Key('material-analysis-results'),
      collapsingHeader: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: headerSections,
      ),
      body: Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s8),
        child: _materialAnalysisTable(theme, analysis),
      ),
    );
  }

  Widget _analysisHeader(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) => Container(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(width: 260, child: _warehouseField()),
            Tooltip(
              message:
                  '分析版本 ${analysis.version} · '
                  '产品 ${analysis.products.length} · 物料 ${analysis.materials.length}',
              child: _factChip(
                theme,
                Icons.schedule_outlined,
                '更新 ${_dateTimeOnly(analysis.analyzedAt)}',
              ),
            ),
            // 查找框常驻顶部卡片（更新时间右侧）；全屏时顶部卡片不可见，
            // 由 _bomToolbarActions 在全屏工具条里再挂一个（共享同一控制器）。
            SizedBox(
              width: context.breakpoint.isCompact ? 200 : 240,
              child: UtenSearchBar(
                key: const Key('material-bom-search'),
                controller: _bomSearch,
                hint: _l10n.materialSearchHint,
                onChanged: _bomSearchChanged,
              ),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        Container(
          key: const Key('material-analysis-next-step'),
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s8,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
            borderRadius: UtenRadius.mdAll,
          ),
          child: Row(
            children: [
              Icon(
                Icons.assistant_direction_rounded,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  _nextStepText(analysis),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_bulkOperationLabel != null && _bulkOperationTotal > 0) ...[
          const SizedBox(height: UtenSpacing.s8),
          Semantics(
            liveRegion: true,
            label:
                '$_bulkOperationLabel，已完成 $_bulkOperationCompleted / $_bulkOperationTotal',
            child: Container(
              key: const Key('material-analysis-bulk-progress'),
              padding: const EdgeInsets.all(UtenSpacing.s12),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer.withValues(
                  alpha: 0.45,
                ),
                borderRadius: UtenRadius.mdAll,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '$_bulkOperationLabel · $_bulkOperationCompleted / $_bulkOperationTotal',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  LinearProgressIndicator(
                    value: _bulkOperationCompleted / _bulkOperationTotal,
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '数量较多时系统会自动分批提交，请勿重复点击。已完成的批次不会重复创建。',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );

  String _nextStepText(ProductionMaterialAnalysisView analysis) {
    if (analysis.fqcReplenishmentOnly) {
      return '此分析仅用于冻结 FQC 补产 BOM，不生成普通生产计划或供给单。核对完成后，请返回“FQC 补产待办”确认真实用料。';
    }
    final shortages = analysis.materials.where(
      (material) => material.shortageQty > 0,
    );
    final unconfirmed = shortages
        .where((material) => material.confirmedRoute == null)
        .length;
    if (unconfirmed > 0) {
      return _l10n.materialRoutesNext(unconfirmed);
    }
    final executable = MaterialSupplyRoute.values.fold<int>(
      0,
      (sum, route) => sum + _executableSupplyGroups(route).length,
    );
    if (executable > 0) {
      return _l10n.materialIssueNext;
    }
    final ready = analysis.products
        .where((product) => _canSelectProduct(product))
        .length;
    if (ready > 0) {
      return _l10n.materialWorkshopNext(ready);
    }
    final waiting = shortages
        .where((material) => _notifiedTargetOf(material) != null)
        .length;
    if (waiting > 0) {
      return '当前无需重复下达：$waiting 条缺料正在采购、委外或自制处理中；合格入库后会自动刷新齐套结果。';
    }
    return '当前没有可执行任务。可切换“全部 BOM”核对完整结构，或刷新最新库存和任务状态。';
  }

  @override
  String _analysisDynamicProjectionKey(ProductionMaterialAnalysisView view) {
    final parts = <String>[
      view.status ?? '',
      (view.allowedActions.toList()..sort()).join(','),
      view.warehouseId ?? '',
      (view.warehouseIds.toList()..sort()).join(','),
    ];
    for (final product in view.products) {
      parts.add(
        <Object?>[
          product.analysisLineId,
          product.submittedQty,
          product.approvedQty,
          product.remainingQty,
          product.readyNowQty,
          product.readyStartQty,
          product.readyFinishQty,
          product.readyShipQty,
          product.readyByDateQty,
          product.readinessRatio,
          product.planExecutionStatus,
          product.latestPlanId,
          product.latestPlanNo,
          product.planExecutionPlannedQty,
          product.planExecutionInboundQty,
          product.planExecutionProgressRatio,
        ].join('|'),
      );
    }
    for (final material in view.materials) {
      parts.add(
        <Object?>[
          material.materialLineId,
          material.availableQty,
          material.allocatedAvailableQty,
          material.exactPeggedQty,
          material.reservedQty,
          material.safetyStockQty,
          material.mainWarehousePublicAvailableQty,
          material.mainWarehouseOpenSafetySupplyQty,
          material.mainWarehouseSafetyReplenishmentGapQty,
          material.inboundQty,
          material.shortageQty,
          material.demandSupplyGapQty,
          material.requirementState?.wireName,
          material.delegatedToAnalysisLineId,
          material.delegatedToSourceRef,
          material.delegatedToRequestedQty,
          material.lowerLevelPending,
          material.expectedReadyDate,
          material.status,
          material.borrowedInQty,
          material.borrowedOutQty,
          material.crossReallocatedInQty,
          material.crossReallocatedOutQty,
          material.priorityPendingQty,
          material.priorityFulfilledQty,
          material.selectedWarehousesAvailableQty,
          material.selectedOtherWarehouseTransferableQty,
          material.publicSurplusApprovedInboundQty,
          material.publicSurplusRemainingQty,
          material.sharedFutureClaimedQty,
          material.additionalSupplyRecommendedQty,
          for (final target in material.notifiedTargets)
            '${target.target?.wireName}:${target.documentType}:'
                '${target.documentId}:${target.status}:${target.allocatedQty}',
          for (final stock in material.warehouseStocks)
            '${stock.warehouseId}:${stock.onHandQty}:${stock.reservedQty}:'
                '${stock.availableQty}:${stock.ownPeggedQty}:'
                '${stock.publicAvailableQty}:${stock.openSafetySupplyQty}:'
                '${stock.safetyReplenishmentGapQty}',
        ].join('|'),
      );
    }
    for (final action in view.supplyActions) {
      parts.add(
        <Object?>[
          action.actionId,
          action.actionGroupKey,
          action.generation,
          action.status,
          action.requestedQty,
          action.safetyReplenishmentQty,
          action.totalRequestedQty,
          action.safetyStockSnapshotQty,
          action.publicAvailableSnapshotQty,
          action.openSafetySupplySnapshotQty,
        ].join('|'),
      );
    }
    return parts.join('\n');
  }
}
