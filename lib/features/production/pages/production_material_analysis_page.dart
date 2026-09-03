import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../models/production_material_analysis.dart';
import '../models/production_work_card.dart';
import '../repositories/production_repository.dart';
import '../widgets/material_reallocation_dialog.dart';
import '../widgets/production_execution_card_print_preview.dart';
import 'production_plan_wizard_page.dart';
import '../widgets/material_borrow_dialog.dart';
import '../widgets/material_required_reason_dialog.dart';
import '../widgets/material_supply_progress_dialog.dart';
import '../widgets/material_supply_quantity_dialog.dart';
import '../widgets/subcontract_make_task_tile.dart';

part 'material_analysis_bom_tree.dart';
part 'material_analysis_borrow.dart';
part 'material_analysis_candidates.dart';
part 'material_analysis_plan_actions.dart';
part 'material_analysis_product_tasks.dart';
part 'material_analysis_subcontract_make.dart';
part 'material_analysis_supply_actions.dart';
part 'material_analysis_view_models.dart';

/// Independent, pre-plan material analysis workbench.
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
  static const int _bomProductPageSize = 30;
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
  ProductionMaterialPlanPreview? _planPreview;
  MaterialAnalysisSalesCandidatePage? _candidatePage;
  String? _warehouseId;
  String? _error;
  String? _serverRefreshNotice;
  bool _booting = true;
  bool _loadingCandidates = false;
  bool _previewingAnalysis = false;
  bool _savingRoutes = false;
  bool _savingPriorities = false;
  bool _borrowing = false;
  bool _previewingPlan = false;
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
  final Set<String> _selectedPlanLineIds = {};
  final Map<MaterialSupplyRoute, Set<String>> _selectedSupplyGroups = {
    for (final route in MaterialSupplyRoute.values) route: <String>{},
  };
  final Map<String, MaterialSupplyRoute> _routeDraft = {};
  final Map<String, String> _routeReasons = {};
  final Set<String> _dirtyRouteGroups = {};
  final Set<String> _expandedPathGroups = {};
  final Set<String> _collapsedBomProducts = {};
  final Set<String> _collapsedBomBranches = {};
  // 节点卡左侧竖向进度条的「点按看数字」：记录当前展开数字进度的物料行，
  // 点按其它任意位置（页面级 onTapDown）即清除。
  String? _progressPeekLineId;
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
  int _productVisibleLimit = 60;
  int _pendingMakeVisibleLimit = 20;
  int _bomProductVisibleLimit = _bomProductPageSize;
  String? _bulkOperationLabel;
  int _bulkOperationCompleted = 0;
  int _bulkOperationTotal = 0;
  ProductionMaterialAnalysisView? _indexCacheAnalysis;
  _MaterialAnalysisIndexes? _indexCache;
  ProductionMaterialAnalysisView? _bomProjectionAnalysis;
  _BomViewMode? _bomProjectionMode;
  String? _bomProjectionKeyword;
  _BomFilterProjection? _bomProjectionCache;

  DateTime _billDate = ChinaDateTime.today();
  DateTime? _deliveryDate;

  Set<String> get _permissions => ref.read(currentPermissionsProvider);
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
  bool get _isFqcReplenishmentOnly => _analysis?.fqcReplenishmentOnly == true;
  bool get _canGenerate =>
      !_isFqcReplenishmentOnly &&
      _permissions.contains(Perm.productionMaterialAnalysisGenerate) &&
      _serverAllows('GENERATE_PLAN');
  bool get _canViewPlans => _permissions.contains(Perm.productionPlanView);
  bool get _canViewSubcontractPreparations =>
      _permissions.contains(Perm.subcontractPreparationView);
  bool get _canStartSubcontractPreparations =>
      _permissions.contains(Perm.subcontractPreparationStart);
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
      _borrowing ||
      _previewingPlan ||
      _generating ||
      _notifyingRoute != null;

  bool get _planSubmissionInProgress => _previewingPlan || _generating;

  bool get _canAdjustPriorities =>
      _canReallocate &&
      (_analysis?.allowedActions.contains('REALLOCATE') ?? false);

  /// Actionable node tasks whose route is still only a suggestion (not
  /// confirmed) but whose suggestion is a concrete BUY/SUBCONTRACT/MAKE route.
  /// These can be bulk-accepted; REVIEW (null suggestion) groups need a manual
  /// decision and are counted separately.
  int get _unconfirmedSuggestedRouteCount {
    final analysis = _analysis;
    if (analysis == null) return 0;
    return _materialGroups(analysis)
        .where(
          (group) =>
              group.actionable &&
              group.representative.confirmedRoute == null &&
              group.representative.sourceSuggestion != null,
        )
        .length;
  }

  // ===== 继承链协作契约：实现在后段 part，基类生命周期按虚调用分发 =====
  Future<void> _previewAnalysis();
  List<_MaterialGroup> _executableSupplyGroups(MaterialSupplyRoute route);
  String _analysisDynamicProjectionKey(ProductionMaterialAnalysisView view);
  Widget _borrowBadges(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material, {
    required bool selected,
  });
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
      _selectedSupplyGroups.values.any((selected) => selected.isNotEmpty) ||
      _batchQtyControllers.values.any(
        (controller) => controller.text.trim().isNotEmpty,
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
      final warehouses = ref.read(masterNameServiceProvider).warehouseEntries;
      if (_warehouseId == null && warehouses.isNotEmpty) {
        _warehouseId = warehouses.keys.first;
      }
      if (_warehouseId == null) {
        setState(() {
          _booting = false;
          _error = '尚未维护可用仓库，无法按仓库分析物料';
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
    _analysis = view;
    _serverRefreshNotice = null;
    _indexCacheAnalysis = null;
    _indexCache = null;
    _bomProjectionAnalysis = null;
    _bomProjectionCache = null;
    _warehouseId = view.warehouseId ?? _warehouseId;
    _planPreview = null;
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
    _routeReasons.clear();
    _dirtyRouteGroups.clear();
    _selectedPlanLineIds.clear();
    for (final selected in _selectedSupplyGroups.values) {
      selected.clear();
    }
    final groups = _materialGroups(view);
    for (final group in groups) {
      if (!group.actionable) continue;
      final route = group.representative.confirmedRoute;
      if (route != null) {
        _routeDraft[group.key] = route;
        final reason = group.representative.routeReason?.trim();
        if (reason?.isNotEmpty == true) _routeReasons[group.key] = reason!;
      }
    }
    final validProductIds = view.products
        .map((product) => product.analysisLineId)
        .toSet();
    _collapsedBomProducts.removeWhere(
      (analysisLineId) => !validProductIds.contains(analysisLineId),
    );
    final validNodeKeys = view.materials
        .map((material) => material.nodeKey)
        .whereType<String>()
        .toSet();
    _collapsedBomBranches.removeWhere(
      (nodeKey) => !validNodeKeys.contains(nodeKey),
    );
    for (final key
        in _batchQtyControllers.keys
            .where((key) => !validProductIds.contains(key))
            .toList()) {
      _batchQtyControllers.remove(key)?.dispose();
    }
    for (final product in view.products) {
      final controller = _batchQtyControllers.putIfAbsent(
        product.analysisLineId,
        () => TextEditingController(),
      );
      // Do not pre-fill the batch quantity. A server refresh starts a new
      // planning round, so the previous round's value is cleared and the
      // planner re-enters a quantity up to the "最多可生产" headline cap.
      controller.value = TextEditingValue.empty;
    }
  }

  /// 服务端刷新会重建节点视图；只把相对最新快照仍合法的未保存路线覆盖回去。
  /// 服务端已确认的路线永远优先；建议变化后缺少覆盖原因的旧草稿也不恢复。
  ({int preserved, int dropped, int settled})
  _applyAnalysisPreservingRouteDrafts(
    ProductionMaterialAnalysisView view, {
    Map<String, ({MaterialSupplyRoute route, String? reason})>
        additionalDrafts =
        const {},
  }) {
    final pendingDrafts =
        <String, ({MaterialSupplyRoute route, String? reason})>{};
    for (final groupKey in _dirtyRouteGroups) {
      final route = _routeDraft[groupKey];
      if (route == null) continue;
      pendingDrafts[groupKey] = (route: route, reason: _routeReasons[groupKey]);
    }
    pendingDrafts.addAll(additionalDrafts);
    final preservedSelections = _supplySelectionSnapshot();
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
      if (group.representative.confirmedRoute != null) {
        settled++;
        continue;
      }
      final stillEditable =
          group.actionable &&
          group.representative.shortageQty > 0 &&
          _notifiedTargetOf(group.representative) == null;
      final reason = entry.value.reason?.trim();
      final reasonRequired =
          group.representative.sourceSuggestion != entry.value.route;
      if (!stillEditable ||
          (reasonRequired && (reason == null || reason.isEmpty))) {
        dropped++;
        continue;
      }
      _routeDraft[entry.key] = entry.value.route;
      if (reason?.isNotEmpty == true) {
        _routeReasons[entry.key] = reason!;
      } else {
        _routeReasons.remove(entry.key);
      }
      _dirtyRouteGroups.add(entry.key);
      preserved++;
    }
    _restoreValidSupplySelections(preservedSelections);
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
    Map<String, ({MaterialSupplyRoute route, String? reason})>
        pendingRouteDrafts =
        const {},
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
      if (product.sourceType != 'MAKE_COMPONENT')
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

  void _changeWarehouse(String? value) {
    if (value == null || value == _warehouseId || _busy) return;
    setState(() {
      _warehouseId = value;
      _planPreview = null;
    });
    if (_analysis != null && _canManage) _previewAnalysis();
  }

  void _beginPriorityEdit() {
    if (!_canAdjustPriorities || _busy) return;
    setState(() {
      _priorityBaseline = List<String>.from(_priorityDraft);
      _editingPriorities = true;
      _planPreview = null;
    });
  }

  void _cancelPriorityEdit() {
    if (_savingPriorities) return;
    setState(() {
      _priorityDraft = List<String>.from(_priorityBaseline);
      _editingPriorities = false;
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
      _planPreview = null;
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

  Map<MaterialSupplyRoute, Set<String>> _supplySelectionSnapshot() => {
    for (final route in MaterialSupplyRoute.values)
      route: Set<String>.from(_selectedSupplyGroups[route]!),
  };

  /// 服务端刷新会重建节点任务，旧选择只能按仍可执行的 actionGroup/path 键恢复；
  /// 已下达、已齐套、路线变化或 MAKE 门槛重新关闭的节点一律不恢复。
  void _restoreValidSupplySelections(
    Map<MaterialSupplyRoute, Set<String>> snapshot,
  ) {
    for (final entry in snapshot.entries) {
      final valid = _executableSupplyGroups(
        entry.key,
      ).map((group) => group.key).toSet();
      _selectedSupplyGroups[entry.key]!.addAll(
        entry.value.where(valid.contains),
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
    final groups = <_MaterialGroup>[];
    final groupsByLine = <String, _MaterialGroup>{};
    for (final material in analysis.materials) {
      materialsByProduct
          .putIfAbsent(material.analysisLineId, () => [])
          .add(material);
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
    return !_productFullyTransferred(product) && product.readyNowQty > 0;
  }

  bool _productFullyTransferred(ProductionMaterialAnalysisProduct product) =>
      product.remainingQty <= 0.000001 &&
      _productExecutionStage(product) != null;

  _ProductExecutionStage? _productExecutionStage(
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
    final progressRatio = product.planExecutionProgressRatio;
    final normalizedProgress = progressRatio == null || !progressRatio.isFinite
        ? null
        : progressRatio.clamp(0.0, 1.0).toDouble();
    final progressPercent = normalizedProgress == null
        ? null
        : normalizedProgress >= 1
        ? 100
        : (normalizedProgress * 100).round().clamp(0, 99);
    return switch (status) {
      'SUBMITTED' => const _ProductExecutionStage(
        status: 'SUBMITTED',
        label: '计划审批中',
        detail: '待审批；通过后进入执行',
        icon: Icons.hourglass_top_rounded,
      ),
      'APPROVED' => const _ProductExecutionStage(
        status: 'APPROVED',
        label: '计划已审核 · 待执行下达',
        detail: '进入计划确认执行与领料条件',
        icon: Icons.verified_outlined,
      ),
      'WAITING' => const _ProductExecutionStage(
        status: 'WAITING',
        label: '执行计划待料',
        detail: '合格物料补齐后恢复可派工',
        icon: Icons.inventory_2_outlined,
      ),
      'READY' => const _ProductExecutionStage(
        status: 'READY',
        label: '已下达 · 待派工 / 仓库发料',
        detail: '尚未开工；进入计划核对派工与领料条件',
        icon: Icons.assignment_turned_in_outlined,
      ),
      'DISPATCHED' => const _ProductExecutionStage(
        status: 'DISPATCHED',
        label: '已派工 · 等待开工',
        detail: '满足领料等开工条件后确认开工',
        icon: Icons.groups_outlined,
      ),
      'IN_PROGRESS' => _ProductExecutionStage(
        status: 'IN_PROGRESS',
        label: progressPercent == null
            ? '生产执行中 · 执行进度待回传'
            : progressPercent == 0 &&
                  (product.planExecutionInboundQty ?? 0) <= 0
            ? '生产执行中 0% · 尚未完工入库'
            : '生产执行中 $progressPercent%',
        detail: progressPercent == 0 ? '执行进度按仓库实收入库计算，不是物料保障率' : null,
        icon: Icons.precision_manufacturing_outlined,
        progress: normalizedProgress,
      ),
      'COMPLETED' => const _ProductExecutionStage(
        status: 'COMPLETED',
        label: '已完工入库',
        icon: Icons.task_alt_rounded,
      ),
      _ => _ProductExecutionStage(
        status: status,
        label: status == 'TRANSFERRED' ? '本批已全部转生产' : '生产计划执行中',
        detail: '进入计划查看执行进度',
        icon: Icons.account_tree_outlined,
      ),
    };
  }

  /// 统一小胶囊徽章：浅底 + 半透明描边 + 彩色加粗小字；上下内边距收紧
  /// （2px），标题行可连续排布多枚而不撑高卡片。
  Widget _miniBadge(
    ThemeData theme, {
    required String label,
    required Color color,
    Color? onColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: onColor == null ? color.withValues(alpha: 0.14) : color,
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: onColor ?? color,
          fontWeight: FontWeight.w700,
        ),
      ),
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
  Color _levelBandColor(ThemeData theme, int level) {
    const lightPalette = <Color>[
      Color(0xFF0F766E), // 层级 1 深青
      Color(0xFF1D4ED8), // 层级 2 深蓝（与青拉开明度差）
      Color(0xFFEA580C), // 层级 3 橙
      Color(0xFF7C3AED), // 层级 4 紫罗兰
      Color(0xFFDB2777), // 层级 5 品红
      Color(0xFF65A30D), // 层级 6+ 橄榄绿
    ];
    const darkPalette = <Color>[
      Color(0xFF2DD4BF),
      Color(0xFF7AA2F7),
      Color(0xFFFB923C),
      Color(0xFFA78BFA),
      Color(0xFFF472B6),
      Color(0xFFA3E635),
    ];
    final palette = theme.brightness == Brightness.dark
        ? darkPalette
        : lightPalette;
    final index = (level - 1).clamp(0, palette.length - 1);
    return palette[index];
  }

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
      if (target.target == null) continue;
      if (target.status == 'CANCELLED') continue;
      return target;
    }
    return null;
  }

  /// 解析已确认路线的「先自制」委托子产品（MAKE 与有子层委外共用一套：
  /// 只认服务端显式 delegated child ID 或对应 MAKE_TASK.documentId；
  /// 同货可能出现在多条路径，禁止按 parentAnalysisLineId + goodsId 猜测）。
  ProductionMaterialAnalysisProduct? _delegatedChildProductOf(
    ProductionMaterialAnalysisMaterial material, {
    required MaterialSupplyRoute route,
    required String documentType,
    required String sourceType,
  }) {
    final analysis = _analysis;
    if (analysis == null) return null;
    String? childId = material.delegatedToAnalysisLineId;
    for (final target in material.notifiedTargets) {
      if (target.target == route && target.documentType == documentType) {
        childId ??= target.documentId;
        break;
      }
    }
    if (childId == null) return null;
    for (final product in analysis.products) {
      if (product.sourceType != sourceType) continue;
      if (product.analysisLineId == childId) return product;
    }
    return null;
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
}

/// 继承链的最终实现类：保持测试与 createState 引用的原私有名。
class _ProductionMaterialAnalysisPageState
    extends _MaterialAnalysisSubcontractMakeState {
  @override
  Widget build(BuildContext context) {
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
        title: '物料分析准备',
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
            // 竖向进度条的数字浮层：点按其它任意位置即消失（onTapDown 与
            // 子组件不竞争手势，按钮点击照常生效）。
            ExcludeFocus(
              excluding: _planSubmissionInProgress,
              child: GestureDetector(
                behavior: HitTestBehavior.deferToChild,
                onTapDown: (_) {
                  if (_progressPeekLineId != null) {
                    setState(() => _progressPeekLineId = null);
                  }
                },
                child: UtenContentContainer.wide(
                  child: _booting
                      ? const Center(child: CircularProgressIndicator())
                      : _analysis == null
                      ? _candidateBody(theme)
                      : _analysisBody(theme),
                ),
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
    final generating = _generating;
    final title = generating
        ? _planSubmissionApproveNow
              ? '正在生成并审核下达'
              : '正在生成生产计划'
        : '正在校验最新库存与齐套状态';
    final description = generating
        ? _planSubmissionApproveNow
              ? '系统正在同一事务内创建计划、审核下达、锁定物料并按需生成提货单。'
              : '系统正在创建计划草稿并提交审批。'
        : '系统正在重新核对可生产数量，避免库存变化造成重复占用。';
    final stepLabel = generating ? '第 2 / 2 步' : '第 1 / 2 步';

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
                label: '$title。$description。$stepLabel。',
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
                                    '$stepLabel · 请勿重复提交或关闭页面',
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
    final offTargetWarehousePegs = _offTargetWarehousePegs(analysis);
    // 悬浮动作区不占布局空间：列表底部预留透明高度，
    // 让末尾内容能滚到悬浮按钮上方，不被常驻遮挡。
    final actionCount = _bottomActionButtons().length;
    final bottomClearance = actionCount == 0
        ? UtenSpacing.s16
        : context.breakpoint.isCompact
        ? 24.0 + actionCount * 60.0
        : 96.0;
    return CustomScrollView(
      key: const Key('material-analysis-results'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          sliver: SliverToBoxAdapter(child: _analysisHeader(theme, analysis)),
        ),
        if (offTargetWarehousePegs.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            sliver: SliverToBoxAdapter(
              child: _offTargetWarehouseBanner(
                theme,
                analysis,
                offTargetWarehousePegs,
              ),
            ),
          ),
        if (_serverRefreshNotice != null)
          SliverPadding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            sliver: SliverToBoxAdapter(
              child: _serverRefreshBanner(theme, _serverRefreshNotice!),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          sliver: SliverToBoxAdapter(child: _productSection(theme, analysis)),
        ),
        // V458：有子层级委外件的前置自制进度与分批通知入口。
        SliverPadding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          sliver: SliverToBoxAdapter(
            child: _subcontractMakeSection(theme, analysis),
          ),
        ),
        if (_error != null)
          SliverPadding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            sliver: SliverToBoxAdapter(
              child: _inlineError(theme, _error!, _previewAnalysis),
            ),
          ),
        if (analysis.materials.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.only(top: UtenSpacing.s12),
            sliver: SliverToBoxAdapter(
              child: _unifiedBomTreeHeader(theme, analysis),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            sliver: _bomTreeSliver(theme, analysis),
          ),
        ],
        if (_planPreview != null)
          SliverPadding(
            padding: EdgeInsets.only(
              top: UtenSpacing.s12,
              bottom: bottomClearance,
            ),
            sliver: SliverToBoxAdapter(
              child: _planPreviewCard(theme, _planPreview!),
            ),
          )
        else
          SliverPadding(padding: EdgeInsets.only(bottom: bottomClearance)),
      ],
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
      return '下一步：有 $unconfirmed 条缺料路线待确认。点“待确认路线”，逐条采用采购、委外或自制建议。';
    }
    final executable = MaterialSupplyRoute.values.fold<int>(
      0,
      (sum, route) => sum + _executableSupplyGroups(route).length,
    );
    if (executable > 0) {
      return '下一步：勾选可处理的缺料，再用底部按钮提交采购、委外或安排自制生产。';
    }
    final ready = analysis.products
        .where((product) => _canSelectProduct(product))
        .length;
    if (ready > 0) {
      return '下一步：已有 $ready 个产品可生产。勾选产品，填写计划单并在汇总页确认提交。';
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
