import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_field_message.dart';
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
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../models/production_material_analysis.dart';
import '../repositories/production_repository.dart';
import '../widgets/material_reallocation_dialog.dart';
import '../widgets/production_execution_card_print_preview.dart';
import 'production_plan_wizard_page.dart';

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

class _ProductionMaterialAnalysisPageState
    extends ConsumerState<ProductionMaterialAnalysisPage> {
  static const int _maxAnalysisItems = 500;
  static const int _requestChunkSize = 500;
  static const int _bomProductPageSize = 30;
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
  Timer? _searchDebounce;
  Timer? _bomSearchDebounce;
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

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _bomSearchDebounce?.cancel();
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

  void _searchCandidates(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _candidateKeyword = value.trim();
      _loadCandidates(page: 1);
    });
  }

  bool _candidateSelected(MaterialAnalysisSalesCandidateLine line) =>
      _sourceQtyControllers.containsKey(line.salesOrderItemId);

  int get _selectedAnalysisSourceCount =>
      _sourceQtyControllers.length + _manualSources.length;

  int get _remainingSalesSourceSlots =>
      (_maxAnalysisItems - _manualSources.length).clamp(0, _maxAnalysisItems);

  void _toggleCandidate(
    MaterialAnalysisSalesCandidateLine line,
    bool selected,
  ) {
    if (selected && (line.remainingQty ?? 0) <= 0) {
      context.appWarning('该销售订单行已无待排数量');
      return;
    }
    if (selected &&
        !_sourceQtyControllers.containsKey(line.salesOrderItemId) &&
        _selectedAnalysisSourceCount >= _maxAnalysisItems) {
      context.appWarning('单次联合分析最多 500 个产品，其余请另开一个批次');
      return;
    }
    setState(() {
      final id = line.salesOrderItemId;
      if (selected) {
        _sourceQtyControllers.putIfAbsent(
          id,
          () => TextEditingController(text: _qty(line.remainingQty ?? 0)),
        );
        _selectedCandidateLabels[id] = _candidateLabel(line);
      } else {
        _sourceQtyControllers.remove(id)?.dispose();
        _selectedCandidateLabels.remove(id);
      }
    });
  }

  /// 桌面候选表使用与调度台一致的受控多选：表头可全选当前页，翻页后旧选择保留。
  /// 数量默认带入当前待排量，员工只需在下方“已选产品”区改例外数量。
  void _replaceCandidateIds(
    Set<String> nextIds,
    List<MaterialAnalysisSalesCandidateLine> visibleLines,
  ) {
    final salesSourceLimit = _remainingSalesSourceSlots;
    final visibleById = {
      for (final line in visibleLines) line.salesOrderItemId: line,
    };
    final acceptedIds = <String>{};
    for (final id in _sourceQtyControllers.keys) {
      if (nextIds.contains(id) && acceptedIds.length < salesSourceLimit) {
        acceptedIds.add(id);
      }
    }
    for (final id in nextIds) {
      if (acceptedIds.length >= salesSourceLimit) break;
      acceptedIds.add(id);
    }
    final capped = acceptedIds.length < nextIds.length;
    setState(() {
      final removed = _sourceQtyControllers.keys
          .where((id) => !acceptedIds.contains(id))
          .toList(growable: false);
      for (final id in removed) {
        _sourceQtyControllers.remove(id)?.dispose();
        _selectedCandidateLabels.remove(id);
      }
      for (final id in acceptedIds) {
        if (_sourceQtyControllers.containsKey(id)) continue;
        final line = visibleById[id];
        final quantity = line?.remainingQty ?? 0;
        if (line == null || quantity <= 0) continue;
        _sourceQtyControllers[id] = TextEditingController(text: _qty(quantity));
        _selectedCandidateLabels[id] = _candidateLabel(line);
      }
    });
    if (capped) {
      context.appWarning(
        '单次联合分析最多 500 个来源(含手工计划)，已保留可加入的前 $salesSourceLimit 项；其余请另开一个批次',
      );
    }
  }

  String _candidateLabel(MaterialAnalysisSalesCandidateLine line) => [
    line.orderNo,
    line.goodsName ?? line.goodsCode,
    line.spec,
  ].whereType<String>().where((value) => value.trim().isNotEmpty).join(' · ');

  List<MaterialAnalysisSourceInput>? _candidateSources() {
    final result = <MaterialAnalysisSourceInput>[..._manualSources];
    for (final entry in _sourceQtyControllers.entries) {
      final quantity = double.tryParse(entry.value.text.trim());
      if (quantity == null || !quantity.isFinite || quantity <= 0) {
        context.appWarning('所选产品的分析数量必须大于 0');
        return null;
      }
      result.add(
        MaterialAnalysisSourceInput(
          salesOrderItemId: entry.key,
          requestedQty: quantity,
        ),
      );
    }
    if (result.isEmpty) {
      context.appWarning('请至少选择一个待分析产品');
      return null;
    }
    if (result.length > _maxAnalysisItems) {
      context.appWarning('单次联合分析最多 500 个来源(销售产品与手工计划合计)');
      return null;
    }
    return result;
  }

  Future<void> _pickManualGoods() async {
    if (_busy) return;
    final goods = await showUtenGoodsPicker(
      context,
      ref,
      scope: UtenGoodsPickerScope.allExceptUncategorized,
    );
    if (goods == null || !mounted) return;
    setState(() => _manualGoods = goods);
  }

  Future<void> _pickManualDeliveryDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _manualDeliveryDate ?? _deliveryDate ?? _billDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (selected != null && mounted) {
      setState(() => _manualDeliveryDate = selected);
    }
  }

  void _addManualSource() {
    final goods = _manualGoods;
    final sourceType = _manualSourceType;
    final sourceRef = _manualSourceRef.text.trim();
    final quantity = double.tryParse(_manualQty.text.trim());
    final reason = _manualReason.text.trim();
    if (sourceType == null) {
      context.appWarning('请选择返工、试制、样品、备库或其他来源');
      return;
    }
    if (sourceRef.isEmpty) {
      context.appWarning('手工计划需求编号必填');
      return;
    }
    if (sourceRef.length > 200) {
      context.appWarning('手工计划需求编号不能超过 200 个字符');
      return;
    }
    if (goods == null) {
      context.appWarning('请选择手工计划货品');
      return;
    }
    if (quantity == null || !quantity.isFinite || quantity <= 0) {
      context.appWarning('手工计划数量必须大于 0');
      return;
    }
    if (reason.isEmpty) {
      context.appWarning('手工计划来源原因必填');
      return;
    }
    final source = MaterialAnalysisSourceInput(
      sourceType: sourceType,
      sourceRef: sourceRef,
      goodsId: goods.id,
      colorId: goods.colorId,
      unitId: goods.unitId,
      requestedQty: quantity,
      sourceReason: reason,
      deliveryDate: _dateText(_manualDeliveryDate ?? _deliveryDate),
    );
    final replacesExisting = _manualSources.any(
      (existing) => existing.canonicalKey == source.canonicalKey,
    );
    if (!replacesExisting &&
        _selectedAnalysisSourceCount >= _maxAnalysisItems) {
      context.appWarning('单次联合分析最多 500 个来源；请先移除一个已选产品或手工计划');
      return;
    }
    final conflictingReference = _manualSources.any(
      (existing) =>
          existing.sourceType == sourceType &&
          existing.sourceRef?.trim().toLowerCase() == sourceRef.toLowerCase() &&
          existing.canonicalKey != source.canonicalKey,
    );
    if (conflictingReference) {
      context.appWarning('同一来源类型下，一个需求编号只能对应一个产品需求');
      return;
    }
    setState(() {
      _manualSources.removeWhere(
        (existing) => existing.canonicalKey == source.canonicalKey,
      );
      _manualSources.add(source);
      _manualSourceLabels[source.canonicalKey] =
          '${goods.code ?? ''} ${goods.name ?? ''}'.trim();
      _manualGoods = null;
      _manualDeliveryDate = null;
    });
    _manualSourceRef.clear();
    _manualReason.clear();
    _manualQty.text = '1';
    context.appSuccess('已加入手工分析来源');
  }

  void _removeManualSource(MaterialAnalysisSourceInput source) {
    setState(() {
      _manualSources.remove(source);
      _manualSourceLabels.remove(source.canonicalKey);
    });
  }

  Future<void> _startCandidateAnalysis() async {
    final sources = _candidateSources();
    if (sources == null) return;
    _sources = sources;
    await _previewAnalysis();
  }

  Future<void> _previewAnalysis() async {
    if (_previewingAnalysis || !_canManage) return;
    final warehouseId = _warehouseId;
    if (warehouseId == null) {
      context.appWarning('请先选择分析仓库');
      return;
    }
    if (_sources.isEmpty) {
      context.appWarning('请至少选择一个待分析产品');
      return;
    }
    if (_sources.length > _maxAnalysisItems) {
      context.appWarning('单次联合分析最多 500 个来源，请拆成多个分析批次');
      return;
    }
    final canonicalSources = [..._sources]
      ..sort((a, b) => a.canonicalKey.compareTo(b.canonicalKey));
    final key = businessIdempotencyKey(
      'material-analysis-preview',
      [
        _analysis?.analysisId ?? widget.seed.analysisId ?? 'NEW',
        _analysis?.version ?? widget.seed.analysisVersion ?? 0,
        warehouseId,
        for (final source in canonicalSources)
          '${source.canonicalKey}:${source.requestedQty}:${source.sourceReason ?? ''}',
      ].join('|'),
    );
    setState(() {
      _previewingAnalysis = true;
      _error = null;
    });
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .previewMaterialAnalysis(
            analysisId: _analysis?.analysisId ?? widget.seed.analysisId,
            expectedVersion: _analysis?.version ?? widget.seed.analysisVersion,
            analysisFingerprint: _analysis?.fingerprint,
            warehouseId: warehouseId,
            idempotencyKey: key,
            sources: canonicalSources,
          );
      if (!mounted) return;
      setState(() {
        _previewingAnalysis = false;
        _applyAnalysis(view);
      });
    } catch (error) {
      if (!mounted) return;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '刷新物料分析',
      )) {
        if (!mounted) return;
        setState(() => _previewingAnalysis = false);
        return;
      }
      setState(() {
        _previewingAnalysis = false;
        _error = productionErrorMessage(error, fallback: '联合物料分析失败');
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

  Future<void> _confirmSuggestedRoute(_MaterialGroup group) async {
    final analysis = _analysis;
    final suggestion = group.representative.sourceSuggestion;
    if (analysis == null ||
        suggestion == null ||
        !_canRoute ||
        !group.actionable ||
        _busy) {
      return;
    }
    final actionGroupKey = group.representative.actionGroupKey;
    final decision = actionGroupKey == null
        ? MaterialRouteDecision(
            materialLineId: group.representative.materialLineId,
            route: suggestion,
          )
        : MaterialRouteDecision(
            actionGroupKey: actionGroupKey,
            route: suggestion,
          );
    final key = businessIdempotencyKey(
      'material-analysis-route-node',
      '${analysis.analysisId}|${analysis.version}|${analysis.fingerprint}|'
          '${actionGroupKey ?? group.representative.materialLineId}|'
          '${suggestion.wireName}',
    );
    final preservedSelections = _supplySelectionSnapshot();
    setState(() => _savingRoutes = true);
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .updateMaterialAnalysisRoutes(
            analysis: analysis,
            idempotencyKey: key,
            decisions: [decision],
          );
      if (!mounted) return;
      setState(() {
        _savingRoutes = false;
        _applyAnalysis(view);
        _restoreValidSupplySelections(preservedSelections);
      });
      context.appSuccess('已采用${suggestion.label}路线，可直接下达任务');
    } catch (error) {
      if (!mounted) return;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '采用建议路线',
        pendingRouteDrafts: {group.key: (route: suggestion, reason: null)},
      )) {
        if (!mounted) return;
        setState(() => _savingRoutes = false);
        return;
      }
      if (!mounted) return;
      setState(() => _savingRoutes = false);
      context.appError(
        productionErrorMessage(error, fallback: '路线确认失败，请刷新后重试'),
        force: true,
      );
    }
  }

  Future<String?> _promptRouteReason(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) => showDialog<String>(
    context: context,
    builder: (_) => _RequiredReasonDialog(
      title: '填写路线覆盖原因',
      fieldKey: const Key('material-route-reason'),
      initialValue: _routeReasons[group.key] ?? '',
      helperMessage:
          '服务端建议 ${group.representative.sourceSuggestion?.label ?? '人工判断'}，'
          '当前选择 ${route.label}。取消不会改变原路线。',
      confirmLabel: '确认路线',
    ),
  );

  List<List<T>> _chunked<T>(List<T> values) {
    final result = <List<T>>[];
    for (var start = 0; start < values.length; start += _requestChunkSize) {
      final proposedEnd = start + _requestChunkSize;
      final end = proposedEnd < values.length ? proposedEnd : values.length;
      result.add(values.sublist(start, end));
    }
    return result;
  }

  void _clearBulkOperation() {
    _bulkOperationLabel = null;
    _bulkOperationCompleted = 0;
    _bulkOperationTotal = 0;
  }

  Future<void> _saveRoutes() async {
    final analysis = _analysis;
    if (analysis == null || !_canRoute || _savingRoutes) return;
    final groups = {
      for (final group in _materialGroups(analysis)) group.key: group,
    };
    final changes = <_PendingRouteDecision>[];
    final pendingDrafts =
        <String, ({MaterialSupplyRoute route, String? reason})>{};
    for (final key in _dirtyRouteGroups) {
      final group = groups[key];
      final route = _routeDraft[key];
      if (group == null || route == null) continue;
      final suggestion = group.representative.sourceSuggestion;
      final reason = _routeReasons[key]?.trim();
      if ((suggestion == null || suggestion != route) &&
          (reason == null || reason.isEmpty)) {
        context.appWarning('覆盖建议路线时必须填写原因');
        return;
      }
      pendingDrafts[key] = (route: route, reason: reason);
      final actionGroupKey = group.representative.actionGroupKey;
      if (actionGroupKey != null) {
        changes.add(
          _PendingRouteDecision(
            groupKey: key,
            decision: MaterialRouteDecision(
              actionGroupKey: actionGroupKey,
              route: route,
              reason: reason,
            ),
          ),
        );
      } else {
        changes.addAll([
          for (final path in group.paths)
            _PendingRouteDecision(
              groupKey: key,
              decision: MaterialRouteDecision(
                materialLineId: path.materialLineId,
                route: route,
                reason: reason,
              ),
            ),
        ]);
      }
    }
    if (changes.isEmpty) {
      context.appInfo('没有待确认的路线变更');
      return;
    }
    changes.sort((left, right) => left.identity.compareTo(right.identity));
    final preservedSelections = _supplySelectionSnapshot();
    var current = analysis;
    var completed = 0;
    final batches = _chunked(changes);
    setState(() {
      _savingRoutes = true;
      _bulkOperationLabel = '正在保存物料路线';
      _bulkOperationCompleted = 0;
      _bulkOperationTotal = changes.length;
    });
    try {
      for (final batch in batches) {
        final key = businessIdempotencyKey(
          'material-analysis-routes-chunk',
          [
            current.analysisId,
            current.version,
            current.fingerprint,
            for (final change in batch)
              '${change.decision.actionGroupKey ?? change.decision.materialLineId}:'
                  '${change.decision.route.wireName}:'
                  '${change.decision.reason ?? ''}',
          ].join('|'),
        );
        current = await ref
            .read(productionPlanRepositoryProvider)
            .updateMaterialAnalysisRoutes(
              analysis: current,
              idempotencyKey: key,
              decisions: [for (final change in batch) change.decision],
            );
        completed += batch.length;
        if (!mounted) return;
        setState(() => _bulkOperationCompleted = completed);
      }
      if (!mounted) return;
      setState(() {
        _savingRoutes = false;
        _clearBulkOperation();
        _applyAnalysis(current);
        _restoreValidSupplySelections(preservedSelections);
      });
      context.appSuccess(
        batches.length == 1 ? '物料路线已确认' : '物料路线已分 ${batches.length} 批全部确认',
      );
    } catch (error) {
      if (!mounted) return;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '批量保存物料路线',
      )) {
        if (!mounted) return;
        setState(() {
          _savingRoutes = false;
          _clearBulkOperation();
        });
        return;
      }
      if (!mounted) return;
      final remainingGroupKeys = changes
          .skip(completed)
          .map((change) => change.groupKey)
          .toSet();
      setState(() {
        _savingRoutes = false;
        _clearBulkOperation();
        _applyAnalysis(current);
        final currentKeys = _materialGroups(
          current,
        ).map((group) => group.key).toSet();
        for (final groupKey in remainingGroupKeys) {
          final draft = pendingDrafts[groupKey];
          if (draft == null || !currentKeys.contains(groupKey)) continue;
          _routeDraft[groupKey] = draft.route;
          if (draft.reason?.isNotEmpty == true) {
            _routeReasons[groupKey] = draft.reason!;
          }
          _dirtyRouteGroups.add(groupKey);
        }
        _restoreValidSupplySelections(preservedSelections);
      });
      final message = productionErrorMessage(error, fallback: '路线确认失败，请刷新后重试');
      context.appError(
        completed == 0
            ? message
            : '已保存 $completed / ${changes.length} 条；剩余路线仍保留在页面，可直接重试。$message',
        force: true,
      );
    }
  }

  /// One-click accepts every concrete BUY/SUBCONTRACT/MAKE suggestion as the
  /// confirmed route, so the planner is not forced to open 15 dropdowns before
  /// they can select shortages and notify. Suggestions equal to the chosen
  /// route need no reason (server contract). REVIEW / null-suggestion groups
  /// still require a manual decision and are reported back.
  Future<void> _acceptAllSuggestedRoutes() async {
    final analysis = _analysis;
    if (analysis == null || !_canRoute || _busy) return;
    final groups = _materialGroups(analysis);
    int accepted = 0;
    int manual = 0;
    setState(() {
      for (final group in groups) {
        if (!group.actionable) continue;
        if (group.representative.confirmedRoute != null) continue;
        final suggestion = group.representative.sourceSuggestion;
        if (suggestion == null) {
          manual++;
          continue;
        }
        _routeDraft[group.key] = suggestion;
        _routeReasons.remove(group.key);
        _dirtyRouteGroups.add(group.key);
        accepted++;
      }
      _planPreview = null;
    });
    if (accepted == 0) {
      context.appInfo(
        manual == 0 ? '当前没有待确认的建议路线' : '剩余 $manual 条建议为空，需逐条人工选择路线',
      );
      return;
    }
    final manualAfter = manual;
    await _saveRoutes();
    if (manualAfter > 0 && mounted) {
      context.appInfo('已采纳 $accepted 条建议路线；另有 $manualAfter 条建议为空，需逐条人工选择路线');
    }
  }

  /// 指定路线下「仍在途」的已提交量估算：汇总各路径下游引用中
  /// OPEN/CREATED/IN_PROGRESS 任务的分摊量（已撤销/已完成不计）。
  /// 仅用于界面默认值与提示；服务端提交时按实时「缺口 − 在途」复核。
  /// 历史投影缺分摊量（allocatedQty 为空）时保守按全额在途处理，
  /// 避免把「已整单提交」误当成可再次全量提交。
  double _openSubmittedQty(_MaterialGroup group, MaterialSupplyRoute route) {
    var total = 0.0;
    for (final path in group.paths) {
      for (final target in path.notifiedTargets) {
        if (target.target != route) continue;
        final status = target.status;
        if (status == 'CANCELLED' || status == 'DONE') continue;
        total +=
            target.allocatedQty ??
            (path.shortageQty > 0 ? path.shortageQty : 0);
      }
    }
    return total;
  }

  /// 本组尚未被已分配现货或 exact 到货权益覆盖的生产需求合计。
  /// shortageQty 仍可能包含安全库存硬保护，不能再作为采购需求上限。
  double _groupDemandSupplyGapQty(_MaterialGroup group) => group.paths.fold(
    0.0,
    (sum, path) =>
        sum + (path.demandSupplyGapQty > 0 ? path.demandSupplyGapQty : 0),
  );

  /// 剩余本批生产需求 = demandSupplyGapQty − 已在途生产需求（下限 0）。
  /// 公共安全库存补库是另一条显式数量切片，不得混入本值。
  double _residualSubmitQty(_MaterialGroup group, MaterialSupplyRoute route) {
    final residual =
        _groupDemandSupplyGapQty(group) - _openSubmittedQty(group, route);
    return residual > 0 ? residual : 0;
  }

  MaterialWarehouseStock? _selectedWarehouseStock(
    ProductionMaterialAnalysisMaterial material,
  ) {
    final warehouseId = _analysis?.warehouseId ?? _warehouseId;
    if (warehouseId == null || warehouseId.isEmpty) return null;
    return material.warehouseStocks
        .where((stock) => stock.warehouseId == warehouseId)
        .firstOrNull;
  }

  double _groupSafetyReplenishmentGapQty(_MaterialGroup group) => group.paths
      .map(_selectedWarehouseStock)
      .whereType<MaterialWarehouseStock>()
      .fold(
        0.0,
        (max, stock) => stock.safetyReplenishmentGapQty > max
            ? stock.safetyReplenishmentGapQty
            : max,
      );

  double _groupOpenSafetySupplyQty(_MaterialGroup group) => group.paths
      .map(_selectedWarehouseStock)
      .whereType<MaterialWarehouseStock>()
      .fold(
        0.0,
        (max, stock) =>
            stock.openSafetySupplyQty > max ? stock.openSafetySupplyQty : max,
      );

  bool _routeBlockedBySafetyGap(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) =>
      route != MaterialSupplyRoute.buy &&
      _groupSafetyReplenishmentGapQty(group) > 0;

  bool _hasSupplySubmitQty(_MaterialGroup group, MaterialSupplyRoute route) =>
      _residualSubmitQty(group, route) > 0 ||
      (route == MaterialSupplyRoute.buy &&
          _groupSafetyReplenishmentGapQty(group) > 0);

  bool _isExecutableSupplyGroup(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) =>
      group.actionable &&
      _routeDraft[group.key] == route &&
      !_dirtyRouteGroups.contains(group.key) &&
      !(route == MaterialSupplyRoute.make &&
          group.representative.lowerLevelPending) &&
      !_routeBlockedBySafetyGap(group, route) &&
      _hasSupplySubmitQty(group, route);

  List<_MaterialGroup> _executableSupplyGroups(MaterialSupplyRoute route) {
    final analysis = _analysis;
    if (analysis == null) return const [];
    return _materialGroups(analysis)
        .where((group) => _isExecutableSupplyGroup(group, route))
        .toList(growable: false);
  }

  int _selectedExecutableCount(MaterialSupplyRoute route) {
    final selected = _selectedSupplyGroups[route]!;
    return _executableSupplyGroups(
      route,
    ).where((group) => selected.contains(group.key)).length;
  }

  String _notifyLabel(MaterialSupplyRoute route) {
    final count = _selectedExecutableCount(route);
    return switch (route) {
      MaterialSupplyRoute.buy => '提交采购需求($count)',
      MaterialSupplyRoute.subcontract => '提交委外需求($count)',
      MaterialSupplyRoute.make => '安排自制生产($count)',
    };
  }

  bool? _supplyHeaderValue(MaterialSupplyRoute route) {
    final eligible = _executableSupplyGroups(route);
    if (eligible.isEmpty) return false;
    final selected = _selectedSupplyGroups[route]!;
    final selectedCount = eligible
        .where((group) => selected.contains(group.key))
        .length;
    if (selectedCount == 0) return false;
    if (selectedCount == eligible.length) return true;
    return null;
  }

  void _toggleSupplyGroup(
    MaterialSupplyRoute route,
    _MaterialGroup group,
    bool selected,
  ) {
    if (!_isExecutableSupplyGroup(group, route) || _busy) return;
    setState(() {
      final values = _selectedSupplyGroups[route]!;
      selected ? values.add(group.key) : values.remove(group.key);
      _planPreview = null;
    });
  }

  void _toggleAllSupplyGroups(MaterialSupplyRoute route, bool selected) {
    if (_busy) return;
    final eligible = _executableSupplyGroups(route);
    setState(() {
      final values = _selectedSupplyGroups[route]!;
      if (selected) {
        values.addAll(eligible.map((group) => group.key));
      } else {
        values.removeAll(eligible.map((group) => group.key));
      }
      _planPreview = null;
    });
  }

  /// 行首选择控件：固定 48px，只改变本地批量选择，不写业务事实。
  ///
  /// - 已下达且余量已闭合 → 显示「已下达」标记，不再参与勾选；
  /// - 已下达但仍有剩余缺口（分批提交的第二批起）→ 继续显示勾选框，
  ///   数量在提交对话框里按「缺口 − 在途」给默认与上限；
  /// - 库存已覆盖（无缺口）→ 显示「已齐」标记，不出现死勾选框；
  /// - 路线已确认且可执行 → 直接勾选/取消；
  /// - 路线未确认但有主档建议 → 固定宽图标，点按给出明确引导，不把普通
  ///   勾选伪装成一次 PUT 写入；
  /// - 无建议路线 / 下层未齐套等 → 点按给出明确引导，不静默无响应。
  Widget _nodeSelectionControl(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group,
    MaterialSupplyRoute? route,
    bool selected,
  ) {
    final notified = _notifiedTargetOf(material);
    if (notified != null &&
        (route == null ||
            (!_routeBlockedBySafetyGap(group, route) &&
                !_hasSupplySubmitQty(group, route)))) {
      return Tooltip(
        message: '已下达${notified.target?.label ?? ''}任务，无需重复选择',
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            Icons.check_circle_rounded,
            size: 22,
            color: selected ? Colors.white : theme.colorScheme.primary,
          ),
        ),
      );
    }
    if (material.requiredQty <= 0) {
      return Tooltip(
        message: '本批无需补货',
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Text(
              '—',
              style: TextStyle(
                color: selected
                    ? Colors.white70
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }
    if (material.requiredQty > 0 && material.shortageQty <= 0) {
      return Tooltip(
        message: '库存已覆盖，无需下达',
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            Icons.inventory_2_outlined,
            size: 20,
            color: selected ? Colors.white70 : theme.colorScheme.primary,
          ),
        ),
      );
    }
    final makeGated =
        route == MaterialSupplyRoute.make && material.lowerLevelPending;
    final label = '选择${material.goodsName ?? material.goodsCode ?? '当前物料'}';
    if (!_canNotify) {
      return _nodeGateIcon(
        theme,
        material,
        label: '仅查看',
        message: '没有下达采购、委外或生产任务的权限',
        icon: Icons.visibility_outlined,
      );
    }
    if (_dirtyRouteGroups.contains(group.key)) {
      return _nodeGateIcon(
        theme,
        material,
        label: '先保存路线',
        message: '路线有未保存修改，保存后才可加入批量下达',
        icon: Icons.save_outlined,
      );
    }
    if (route == null || material.confirmedRoute == null) {
      return _nodeGateIcon(
        theme,
        material,
        label: '先确认路线',
        message: '先采用建议路线，或在右侧详情中选择采购、委外或自制',
        icon: Icons.route_outlined,
      );
    }
    if (makeGated) {
      return _nodeGateIcon(
        theme,
        material,
        label: '下层未齐',
        message: '下层物料未齐套，暂不能安排生产，请先处理下层缺料',
        icon: Icons.account_tree_outlined,
      );
    }
    if (_routeBlockedBySafetyGap(group, route)) {
      return _nodeGateIcon(
        theme,
        material,
        label: '仅采购可补安全库存',
        message: '本版本仅采购路线支持公共安全补库；请改为采购路线，或先处理安全库存策略',
        icon: Icons.policy_outlined,
      );
    }
    if (!_isExecutableSupplyGroup(group, route)) {
      return _nodeGateIcon(
        theme,
        material,
        label: '暂不可选',
        message: '当前节点暂不可加入批量下达，请查看右侧状态和详情',
        icon: Icons.info_outline_rounded,
      );
    }
    return Tooltip(
      message: label,
      child: Semantics(
        container: true,
        checked: selected,
        enabled: !_busy,
        label: label,
        onTap: _busy
            ? null
            : () => _handleSupplyCheckbox(group, route, selected),
        child: InkWell(
          key: ValueKey('material-bom-select-${material.materialLineId}'),
          borderRadius: UtenRadius.smAll,
          onTap: _busy
              ? null
              : () => _handleSupplyCheckbox(group, route, selected),
          child: SizedBox(
            width: 48,
            height: 48,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Checkbox(
                  value: selected,
                  onChanged: _busy ? null : (_) {},
                  fillColor: selected
                      ? const WidgetStatePropertyAll(Colors.white)
                      : null,
                  checkColor: selected ? UtenColors.deepGreen : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 固定 48px 的行首门禁图标：不撑开行头宽度，保持整列对齐；
  /// 点按弹出大白话引导（适老：不依赖悬停 tooltip 才能看到原因）。
  Widget _nodeGateIcon(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material, {
    required String label,
    required String message,
    required IconData icon,
  }) => Tooltip(
    message: '$label：$message',
    child: Semantics(
      container: true,
      button: true,
      label: '$label：$message',
      child: InkWell(
        key: ValueKey('material-bom-gate-${material.materialLineId}'),
        borderRadius: UtenRadius.smAll,
        onTap: _busy ? null : () => context.appInfo(message),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            icon,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );

  /// 行首路线确认状态的视觉描述：待确认 / 已确认 / 已下达 / 分批在途 /
  /// 已齐 / 无需补货。汇总路径行的行首状态列使用（BOM 节点卡左栏已改为
  /// 纯层级底色 + 竖向进度条，不再显示该图标）。
  ({IconData icon, Color color, String tip, String? tapMessage})
  _routeStateVisual(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group,
    MaterialSupplyRoute? route, {
    required bool selected,
  }) {
    final onSelected = selected ? Colors.white : null;
    final onSelectedSoft = selected ? Colors.white70 : null;
    IconData icon;
    Color color;
    String tip;
    String? tapMessage;
    final notified = _notifiedTargetOf(material);
    if (notified != null) {
      final residual = route == null ? 0.0 : _residualSubmitQty(group, route);
      final safetyGap = _groupSafetyReplenishmentGapQty(group);
      if (route != null && _routeBlockedBySafetyGap(group, route)) {
        icon = Icons.policy_outlined;
        color = onSelected ?? theme.colorScheme.error;
        tip = '本版本仅采购路线支持公共安全补库';
        tapMessage =
            '当前路线为${route.label}，公共安全库存还差 ${_qty(safetyGap)}；本版本不能沿该路线继续下达';
      } else if (residual > 0 ||
          (route == MaterialSupplyRoute.buy && safetyGap > 0)) {
        icon = Icons.timelapse_rounded;
        color = onSelected ?? theme.colorScheme.secondary;
        tip = residual > 0 ? '分批在途：仍有本批生产需求可继续提交' : '本批生产需求已覆盖，仍有公共安全库存补库待确认';
      } else {
        icon = Icons.check_circle_rounded;
        color = onSelected ?? theme.colorScheme.primary;
        tip = '已下达${notified.target?.label ?? ''}任务';
      }
    } else if (material.requiredQty <= 0) {
      icon = Icons.remove_rounded;
      color = onSelectedSoft ?? theme.colorScheme.onSurfaceVariant;
      tip = '本批无需补货';
    } else if (material.shortageQty <= 0) {
      icon = Icons.inventory_2_outlined;
      color = onSelected ?? theme.colorScheme.primary;
      tip = '库存已覆盖，本层已齐';
    } else if (_dirtyRouteGroups.contains(group.key)) {
      icon = Icons.save_outlined;
      color = onSelected ?? Colors.orange.shade700;
      tip = '路线已改未保存';
      tapMessage = '路线有未保存修改，请先点底部「确认路线」保存，再提交任务';
    } else if (material.confirmedRoute == null) {
      icon = Icons.route_outlined;
      color = onSelected ?? theme.colorScheme.error;
      tip = '先确认路线';
      tapMessage = '先点右侧「采用建议」或「更换路线」选择采购/委外/自制，再提交任务';
    } else {
      icon = Icons.check_circle_outline_rounded;
      color = onSelected ?? theme.colorScheme.primary;
      tip = '路线已确认(${route?.label ?? ''})，可勾选提交';
    }
    return (icon: icon, color: color, tip: tip, tapMessage: tapMessage);
  }

  /// 行首第一列（固定宽）：只显示「路线确认状态」一个图标。
  /// 宽屏 56px，紧凑屏 44px（横向空间紧张时给物料名让位）。
  Widget _routeStateCell(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group,
    MaterialSupplyRoute? route, {
    required bool selected,
    bool compact = false,
  }) {
    final visual = _routeStateVisual(
      theme,
      material,
      group,
      route,
      selected: selected,
    );
    final child = SizedBox(
      width: compact ? 44 : 56,
      height: 48,
      child: Center(child: Icon(visual.icon, size: 24, color: visual.color)),
    );
    return Tooltip(
      message: visual.tip,
      child: Semantics(
        container: true,
        button: visual.tapMessage != null,
        label: visual.tip,
        child: visual.tapMessage == null
            ? child
            : InkWell(
                key: ValueKey(
                  'material-route-state-${material.materialLineId}',
                ),
                borderRadius: UtenRadius.smAll,
                onTap: _busy ? null : () => context.appInfo(visual.tapMessage!),
                child: child,
              ),
      ),
    );
  }

  /// 节点“本批生产需求”覆盖口径 =（需求 − demandSupplyGapQty）÷ 需求。
  /// 安全库存保护与公共补库在途在卡片上独立展示，不能再把安全库存缺口伪装
  /// 成本批生产需求未到货。不混用报工 fqty / 成品入库 iqty。
  ({double covered, double ratio})? _coverageOf(
    ProductionMaterialAnalysisMaterial material,
  ) {
    if (material.requiredQty <= 0) return null;
    final covered = (material.requiredQty - material.demandSupplyGapQty).clamp(
      0.0,
      material.requiredQty,
    );
    return (
      covered: covered,
      ratio: (covered / material.requiredQty).clamp(0.0, 1.0),
    );
  }

  /// 覆盖进度配色：已齐=主题色，0%=错误色，中间=tertiary。
  Color _coverageColor(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    double ratio,
  ) {
    if (material.demandSupplyGapQty <= 0) return theme.colorScheme.primary;
    return ratio <= 0 ? theme.colorScheme.error : theme.colorScheme.tertiary;
  }

  /// BOM 节点卡左侧状态栏：整栏底色 = 层级色（加明显），中间一条加粗的
  /// **竖向备料进度条**拉满整卡高度（自底向上填充，配色与旧备料进度条
  /// 同源）；鼠标悬停 Tooltip、点按在卡内浮出「备料 X% · 已备 A/B」数字，
  /// 点其它任意位置消失。本批无需补货的节点显示层级色细线，不表达进度。
  /// 状态栏独立整高，右侧内容不会侵入。2026-08-18 起移除栏顶路线状态图标
  /// （路线状态由数量行的状态文字承担），栏体只表达层级 + 进度。
  Widget _nodeStatusRail(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group,
    MaterialSupplyRoute? route, {
    required bool selected,
  }) {
    final bandColor = selected
        ? Colors.white
        : _levelBandColor(theme, material.level);
    final coverage = _coverageOf(material);
    final barColor = coverage == null
        ? bandColor.withValues(alpha: selected ? 0.9 : 0.6)
        : selected
        ? Colors.white
        : _coverageColor(theme, material, coverage.ratio);
    final progressLabel = coverage == null
        ? null
        : '备料 ${(coverage.ratio * 100).toStringAsFixed(0)}%'
              ' · 已备 ${_qty(coverage.covered)}/${_qty(material.requiredQty)}';
    return Container(
      width: 44,
      decoration: BoxDecoration(
        // 层级底色加明显（0.12 → 0.24），与右侧内容区一眼区分层级。
        color: bandColor.withValues(alpha: selected ? 0.16 : 0.24),
        border: Border(
          right: BorderSide(
            color: selected ? Colors.white24 : theme.colorScheme.outlineVariant,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
        child: coverage == null
            ? Center(
                child: Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: barColor,
                    borderRadius: UtenRadius.smAll,
                  ),
                ),
              )
            : Tooltip(
                message: progressLabel!,
                child: Semantics(
                  container: true,
                  button: true,
                  label: '备料进度$progressLabel，点按显示数字',
                  child: GestureDetector(
                    key: ValueKey(
                      'material-node-rail-progress-${material.materialLineId}',
                    ),
                    behavior: HitTestBehavior.opaque,
                    onTap: _busy
                        ? null
                        : () => setState(
                            () => _progressPeekLineId = material.materialLineId,
                          ),
                    // 整个 44px 状态栏都是点按热区；Stack 只把可见轨道固定
                    // 在中间 10px，并继承整卡紧高度。避免 loose Container 高度
                    // 退化为 0，也不用 IntrinsicHeight 不兼容的 double.infinity。
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned(
                          left: 17,
                          right: 17,
                          top: 0,
                          bottom: 0,
                          child: DecoratedBox(
                            key: ValueKey(
                              'material-node-rail-fill-${material.materialLineId}',
                            ),
                            decoration: _verticalRailProgressDecoration(
                              background: selected
                                  ? Colors.white24
                                  : barColor.withValues(alpha: 0.22),
                              fill: barColor,
                              ratio: coverage.ratio,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  BoxDecoration _verticalRailProgressDecoration({
    required Color background,
    required Color fill,
    required double ratio,
  }) {
    final progress = ratio.clamp(0.0, 1.0);
    return BoxDecoration(
      color: progress <= 0
          ? background
          : progress >= 1
          ? fill
          : null,
      gradient: progress <= 0 || progress >= 1
          ? null
          : LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [fill, fill, background, background],
              stops: [0, progress, progress, 1],
            ),
      borderRadius: UtenRadius.smAll,
    );
  }

  /// 勾选框统一点按入口。可执行节点只切换本地选择；路线确认、任务下达
  /// 都由旁边的显式操作或底部批量按钮完成。
  Future<void> _handleSupplyCheckbox(
    _MaterialGroup group,
    MaterialSupplyRoute? route,
    bool selected,
  ) async {
    if (_busy) return;
    final material = group.representative;
    if (!_canNotify) {
      context.appWarning('没有下达采购/委外/生产任务的权限');
      return;
    }
    if (route == null) {
      context.appInfo('该物料没有建议路线，请点右侧「选择路线」');
      return;
    }
    if (_routeBlockedBySafetyGap(group, route)) {
      context.appWarning('本版本仅采购路线支持公共安全补库；当前${route.label}路线不能继续下达');
      return;
    }
    if (_isExecutableSupplyGroup(group, route)) {
      _toggleSupplyGroup(route, group, !selected);
      return;
    }
    if (_dirtyRouteGroups.contains(group.key)) {
      context.appInfo('该物料的路线有未保存修改，请先保存路线');
      return;
    }
    if (material.confirmedRoute == null && material.sourceSuggestion == route) {
      context.appInfo('请先点右侧“采用${route.label}”确认路线，再勾选加入批量下达');
      return;
    }
    if (route == MaterialSupplyRoute.make && material.lowerLevelPending) {
      context.appInfo('下层物料未齐套，暂不能安排生产，请先处理下层缺料');
      return;
    }
    context.appInfo('当前节点暂不可选择，请展开节点详情查看原因');
  }

  Future<ProductionMaterialAnalysisView?> _notifyRoute(
    MaterialSupplyRoute route, {
    Set<String>? onlyGroupKeys,
  }) async {
    final analysis = _analysis;
    if (analysis == null || !_canNotify || _notifyingRoute != null) {
      return null;
    }
    final selected = _selectedSupplyGroups[route]!;
    final groups = _executableSupplyGroups(route)
        .where((group) {
          if (onlyGroupKeys != null) return onlyGroupKeys.contains(group.key);
          return selected.contains(group.key);
        })
        .toList(growable: false);
    if (groups.isEmpty) {
      context.appInfo('请先勾选要提交的${route.label}缺料');
      return null;
    }
    if (_dirtyRouteGroups.isNotEmpty) {
      context.appWarning('请先确认路线，再通知对应部门');
      return null;
    }
    final targets = <_SupplyNotificationTarget>[];
    final seenTargets = <String>{};
    for (final group in groups) {
      final actionGroupKey = group.representative.actionGroupKey;
      if (actionGroupKey != null) {
        final identity = 'GROUP|$actionGroupKey';
        if (seenTargets.add(identity)) {
          targets.add(
            _SupplyNotificationTarget(actionGroupKey: actionGroupKey),
          );
        }
        continue;
      }
      for (final path in group.paths) {
        final identity = 'LINE|${path.materialLineId}';
        if (seenTargets.add(identity)) {
          targets.add(
            _SupplyNotificationTarget(materialLineId: path.materialLineId),
          );
        }
      }
    }
    targets.sort((left, right) => left.identity.compareTo(right.identity));
    // 提交前确认每种料的数量：默认 = 缺口 − 在途，可改小（分批提交）。
    // 取消则整批不提交，不产生任何业务事实。
    final quantities = await _promptSupplyQuantities(route, targets);
    if (quantities == null || !mounted) return null;
    final quantityByIdentity = {
      for (final input in quantities)
        input.actionGroupKey != null
                ? 'GROUP|${input.actionGroupKey}'
                : 'LINE|${input.materialLineId}':
            input,
    };
    final batches = _chunked(targets);
    final preservedSelections = _supplySelectionSnapshot();
    var current = analysis;
    var completed = 0;
    setState(() {
      _notifyingRoute = route;
      _bulkOperationLabel = switch (route) {
        MaterialSupplyRoute.buy => '正在提交采购需求',
        MaterialSupplyRoute.subcontract => '正在提交委外需求',
        MaterialSupplyRoute.make => '正在创建自制备料任务',
      };
      _bulkOperationCompleted = 0;
      _bulkOperationTotal = targets.length;
    });
    try {
      for (final batch in batches) {
        final actionGroupKeys = batch
            .map((target) => target.actionGroupKey)
            .whereType<String>()
            .toList(growable: false);
        final materialLineIds = batch
            .map((target) => target.materialLineId)
            .whereType<String>()
            .toList(growable: false);
        final batchQuantities = [
          for (final target in batch)
            if (quantityByIdentity[target.identity] != null)
              quantityByIdentity[target.identity]!,
        ];
        final key = businessIdempotencyKey(
          'material-analysis-notify-chunk',
          [
            current.analysisId,
            current.version,
            current.fingerprint,
            route.wireName,
            ...actionGroupKeys,
            ...materialLineIds,
            for (final input in batchQuantities)
              '${input.actionGroupKey ?? input.materialLineId}:'
                  '${input.qty}:${input.safetyReplenishmentQty}',
          ].join('|'),
        );
        current = await ref
            .read(productionPlanRepositoryProvider)
            .notifyMaterialAnalysis(
              analysis: current,
              idempotencyKey: key,
              target: route,
              actionGroupKeys: actionGroupKeys,
              materialLineIds: materialLineIds,
              quantities: batchQuantities,
            );
        completed += batch.length;
        if (!mounted) return null;
        setState(() => _bulkOperationCompleted = completed);
      }
      if (!mounted) return null;
      setState(() {
        _notifyingRoute = null;
        _clearBulkOperation();
        _applyAnalysis(current);
        _restoreValidSupplySelections(preservedSelections);
      });
      final message = switch (route) {
        MaterialSupplyRoute.buy => '采购需求已提交并通知采购',
        MaterialSupplyRoute.subcontract => '委外需求已提交并通知委外',
        MaterialSupplyRoute.make => '自制备料任务已创建',
      };
      context.appSuccess(
        batches.length == 1
            ? '$message(${groups.length} 条)'
            : '$message(${groups.length} 条，分 ${batches.length} 批完成)',
      );
      return current;
    } catch (error) {
      if (!mounted) return null;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '提交${route.label}需求',
      )) {
        if (!mounted) return null;
        setState(() {
          _notifyingRoute = null;
          _clearBulkOperation();
        });
        return null;
      }
      if (!mounted) return null;
      setState(() {
        _notifyingRoute = null;
        _clearBulkOperation();
        _applyAnalysis(current);
        _restoreValidSupplySelections(preservedSelections);
      });
      final message = productionErrorMessage(error, fallback: '通知失败，请稍后重试');
      context.appError(
        completed == 0
            ? message
            : '已提交 $completed / ${targets.length} 项；未完成项仍保持勾选，可直接重试。$message',
        force: true,
      );
      return null;
    }
  }

  /// 「提交采购/委外/自制」前的数量确认：每个提交单元一行。
  ///
  /// 本批生产需求默认/上限来自 demandSupplyGapQty − 已在途需求；公共安全
  /// 库存补库仅 BUY 支持，并按 goods/color/unit 去重后作为固定数量显式回传。
  /// 前端绝不在确认后静默追加数量。取消返回 null，调用方整批放弃。
  Future<List<MaterialSupplyQuantityInput>?> _promptSupplyQuantities(
    MaterialSupplyRoute route,
    List<_SupplyNotificationTarget> targets,
  ) {
    final rawEntries = [
      for (final target in targets) _supplyQuantityEntry(target, route),
    ];
    final safetyGapByDimension = <String, double>{};
    for (final entry in rawEntries) {
      final previous = safetyGapByDimension[entry.dimensionKey] ?? 0;
      if (entry.safetyReplenishmentGapQty > previous) {
        safetyGapByDimension[entry.dimensionKey] =
            entry.safetyReplenishmentGapQty;
      }
    }
    final safetyDimensionsIncluded = <String>{};
    final entries = <_SupplyQuantityEntry>[];
    for (final entry in rawEntries) {
      final dimensionGap = safetyGapByDimension[entry.dimensionKey] ?? 0;
      final includeHere =
          route == MaterialSupplyRoute.buy &&
          dimensionGap > 0 &&
          safetyDimensionsIncluded.add(entry.dimensionKey);
      entries.add(
        entry.withSafetyReplenishment(
          includeHere ? dimensionGap : 0,
          deduplicatedElsewhere:
              route == MaterialSupplyRoute.buy &&
              dimensionGap > 0 &&
              !includeHere,
        ),
      );
    }
    return showDialog<List<MaterialSupplyQuantityInput>>(
      context: context,
      builder: (_) =>
          _SupplyQuantityDialog(route: route, entries: entries, qtyText: _qty),
    );
  }

  /// 组装一个提交单元的展示与口径数据。actionGroupKey 单元的缺口/在途
  /// 按整个操作组汇总（与服务端分组口径一致），不按本页单个勾选行。
  _SupplyQuantityEntry _supplyQuantityEntry(
    _SupplyNotificationTarget target,
    MaterialSupplyRoute route,
  ) {
    final materials =
        _analysis?.materials ?? const <ProductionMaterialAnalysisMaterial>[];
    final lines = target.actionGroupKey != null
        ? materials
              .where(
                (material) =>
                    material.actionable &&
                    material.actionGroupKey == target.actionGroupKey,
              )
              .toList(growable: false)
        : materials
              .where(
                (material) => material.materialLineId == target.materialLineId,
              )
              .toList(growable: false);
    final representative = lines.isEmpty ? null : lines.first;
    var demandGap = 0.0;
    var open = 0.0;
    var safetyStock = 0.0;
    var publicAvailable = 0.0;
    var openSafetySupply = 0.0;
    var safetyGap = 0.0;
    for (final material in lines) {
      if (material.demandSupplyGapQty > 0) {
        demandGap += material.demandSupplyGapQty;
      }
      if (material.safetyStockQty > safetyStock) {
        safetyStock = material.safetyStockQty;
      }
      final stock = _selectedWarehouseStock(material);
      if (stock != null) {
        if (stock.publicAvailableQty > publicAvailable) {
          publicAvailable = stock.publicAvailableQty;
        }
        if (stock.openSafetySupplyQty > openSafetySupply) {
          openSafetySupply = stock.openSafetySupplyQty;
        }
        if (stock.safetyReplenishmentGapQty > safetyGap) {
          safetyGap = stock.safetyReplenishmentGapQty;
        }
      }
      for (final notified in material.notifiedTargets) {
        if (notified.target != route) continue;
        final status = notified.status;
        if (status == 'CANCELLED' || status == 'DONE') continue;
        // 历史投影缺分摊量时保守按全额在途，防止重复全量提交。
        open +=
            notified.allocatedQty ??
            (material.demandSupplyGapQty > 0 ? material.demandSupplyGapQty : 0);
      }
    }
    final residual = demandGap - open;
    return _SupplyQuantityEntry(
      actionGroupKey: target.actionGroupKey,
      materialLineId: target.materialLineId,
      label: representative?.goodsName ?? representative?.goodsCode ?? '该物料',
      spec: representative?.spec,
      unitName: representative?.unitName,
      dimensionKey: representative == null
          ? target.identity
          : _materialDimensionKey(representative),
      openQty: open,
      maxQty: residual > 0 ? residual : 0,
      safetyStockQty: safetyStock,
      publicAvailableQty: publicAvailable,
      openSafetySupplyQty: openSafetySupply,
      safetyReplenishmentGapQty: safetyGap,
    );
  }

  /// A ready MAKE node is one staff action: create its auditable child demand,
  /// then immediately continue into the production-plan form. If the planner
  /// cancels the form, the child remains visible as "待安排生产" and no formal
  /// plan is fabricated.
  Future<void> _arrangeMakeProduction(_MaterialGroup group) async {
    final materialLineId = group.representative.materialLineId;
    final view = await _notifyRoute(
      MaterialSupplyRoute.make,
      onlyGroupKeys: {group.key},
    );
    if (!mounted || view == null) return;
    ProductionMaterialAnalysisMaterial? material;
    for (final candidate in view.materials) {
      if (candidate.materialLineId == materialLineId) {
        material = candidate;
        break;
      }
    }
    if (material == null) {
      context.appWarning('自制任务已创建，但节点已刷新，请从子件卡片继续安排生产');
      return;
    }
    final child = _makeChildProductOf(material);
    if (child == null) {
      context.appWarning('自制任务已创建，子件分析正在刷新，请稍后从本页继续安排生产');
      return;
    }
    if (!_canSelectProduct(child)) {
      context.appInfo('自制任务已创建；子件尚未齐套，已留在本页继续备料');
      return;
    }
    if (!_canGenerate) {
      context.appInfo('自制任务已创建；请由有生产计划权限的员工继续填写计划单');
      return;
    }
    await _openPlanForProduct(child);
  }

  List<ProductionMaterialAnalysisMaterial> _depth1MaterialsFor(
    ProductionMaterialAnalysisProduct product,
  ) {
    final analysis = _analysis;
    if (analysis == null) return const [];
    return analysis.materials
        .where(
          (material) =>
              material.analysisLineId == product.analysisLineId &&
              material.level == 1,
        )
        .toList(growable: false);
  }

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
    final progressPercent = progressRatio == null
        ? null
        : progressRatio >= 1
        ? 100
        : (progressRatio * 100).round().clamp(0, 99);
    return switch (status) {
      'SUBMITTED' => const _ProductExecutionStage(
        status: 'SUBMITTED',
        label: '计划审批中',
        detail: '审批通过后将进入执行排产，并生成对应领料任务',
        icon: Icons.hourglass_top_rounded,
      ),
      'APPROVED' => const _ProductExecutionStage(
        status: 'APPROVED',
        label: '计划已审核 · 待执行下达',
        detail: '进入生产计划确认执行子计划、车间分配与领料单',
        icon: Icons.verified_outlined,
      ),
      'WAITING' => const _ProductExecutionStage(
        status: 'WAITING',
        label: '执行计划待料',
        detail: '下游合格物料补齐后会重新进入可派工状态',
        icon: Icons.inventory_2_outlined,
      ),
      'READY' => const _ProductExecutionStage(
        status: 'READY',
        label: '已下达 · 待派工 / 仓库发料',
        detail: 'READY 只表示已预留并生成领料单，尚不代表可以开工',
        icon: Icons.assignment_turned_in_outlined,
      ),
      'DISPATCHED' => const _ProductExecutionStage(
        status: 'DISPATCHED',
        label: '已派工 · 等待开工',
        detail: '进入生产计划核对仓库发料进度；全部发料后确认开工',
        icon: Icons.groups_outlined,
      ),
      'IN_PROGRESS' => _ProductExecutionStage(
        status: 'IN_PROGRESS',
        label: progressPercent == null ? '生产执行中' : '生产执行中 $progressPercent%',
        icon: Icons.precision_manufacturing_outlined,
      ),
      'COMPLETED' => const _ProductExecutionStage(
        status: 'COMPLETED',
        label: '已完工入库',
        detail: '仓库实收入库已计入本生产计划完成量',
        icon: Icons.task_alt_rounded,
      ),
      _ => _ProductExecutionStage(
        status: status,
        label: status == 'TRANSFERRED' ? '本批已全部转生产' : '生产计划执行中',
        detail: '进入生产计划查看审批、领料、派工与完工进度',
        icon: Icons.account_tree_outlined,
      ),
    };
  }

  bool _productFullyTransferred(ProductionMaterialAnalysisProduct product) =>
      product.remainingQty <= 0.000001 &&
      _productExecutionStage(product) != null;

  Color _productExecutionColor(
    ThemeData theme,
    _ProductExecutionStage stage, {
    required bool selected,
  }) {
    if (selected) return Colors.white;
    return switch (stage.status) {
      'COMPLETED' => theme.colorScheme.primary,
      'IN_PROGRESS' || 'DISPATCHED' => theme.colorScheme.secondary,
      'SUBMITTED' || 'WAITING' => theme.colorScheme.tertiary,
      _ => theme.colorScheme.primary,
    };
  }

  /// Bottom-up readiness for a product/assembly card. readyNowQty > 0 means it
  /// can be planned now; otherwise the blocker is broken down by which
  /// depth-one materials are still short and whether they are self-make
  /// sub-assemblies (waiting on children to be built and received), procured
  /// (BUY) or subcontracted items.
  _ProductReadiness _productReadiness(
    ProductionMaterialAnalysisProduct product,
  ) {
    if (product.readyNowQty > 0) {
      return const _ProductReadiness(_ReadinessState.ready);
    }
    var make = 0, buy = 0, subcontract = 0, review = 0;
    for (final material in _depth1MaterialsFor(product)) {
      if (material.shortageQty <= 0) continue;
      switch (material.confirmedRoute ?? material.sourceSuggestion) {
        case MaterialSupplyRoute.make:
          make++;
        case MaterialSupplyRoute.buy:
          buy++;
        case MaterialSupplyRoute.subcontract:
          subcontract++;
        case null:
          review++;
      }
    }
    final state = make > 0
        ? _ReadinessState.waitingMake
        : (buy > 0 || subcontract > 0
              ? _ReadinessState.waitingSupply
              : _ReadinessState.waiting);
    return _ProductReadiness(
      state,
      make: make,
      buy: buy,
      subcontract: subcontract,
      review: review,
    );
  }

  bool _hasProductionMaterialChildren(
    ProductionMaterialAnalysisProduct product,
  ) {
    final authoritative = product.hasProductionMaterialChildren;
    if (authoritative != null) return authoritative;
    final analysis = _analysis;
    if (analysis == null) return true;
    return (_analysisIndexes(
              analysis,
            ).materialsByProduct[product.analysisLineId] ??
            const [])
        .isNotEmpty;
  }

  bool _canSelectProduct(ProductionMaterialAnalysisProduct product) {
    return product.readyNowQty > 0;
  }

  List<ProductionMaterialAnalysisProduct> get _selectableProducts =>
      (_analysis?.products ?? const [])
          .where(_canSelectProduct)
          .toList(growable: false);

  bool? get _productHeaderValue {
    final products = _selectableProducts;
    if (products.isEmpty) return false;
    final selectedCount = products
        .where(
          (product) => _selectedPlanLineIds.contains(product.analysisLineId),
        )
        .length;
    if (selectedCount == 0) return false;
    if (selectedCount == products.length) return true;
    return null;
  }

  void _toggleProduct(
    ProductionMaterialAnalysisProduct product,
    bool selected,
  ) {
    if (!_canSelectProduct(product) || _busy) return;
    setState(() {
      if (selected) {
        _selectedPlanLineIds.add(product.analysisLineId);
        final controller = _batchQtyControllers[product.analysisLineId];
        if (controller != null && controller.text.trim().isEmpty) {
          controller.text = _qty(product.readyNowQty);
        }
      } else {
        _selectedPlanLineIds.remove(product.analysisLineId);
      }
      _planPreview = null;
    });
  }

  Future<void> _openPlanForProduct(
    ProductionMaterialAnalysisProduct product,
  ) async {
    if (!_canSelectProduct(product) || _busy) return;
    setState(() {
      _selectedPlanLineIds
        ..clear()
        ..add(product.analysisLineId);
      final controller = _batchQtyControllers[product.analysisLineId];
      if (controller != null && controller.text.trim().isEmpty) {
        controller.text = _qty(product.readyNowQty);
      }
      _planPreview = null;
    });
    await _openPlanWizard();
  }

  void _toggleAllProducts(bool selected) {
    if (_busy) return;
    setState(() {
      if (selected) {
        for (final product in _selectableProducts) {
          _selectedPlanLineIds.add(product.analysisLineId);
          final controller = _batchQtyControllers[product.analysisLineId];
          if (controller != null && controller.text.trim().isEmpty) {
            controller.text = _qty(product.readyNowQty);
          }
        }
      } else {
        _selectedPlanLineIds.removeAll(
          _selectableProducts.map((product) => product.analysisLineId),
        );
      }
      _planPreview = null;
    });
  }

  List<MaterialAnalysisPlanItemInput>? _planItems() {
    final items = <MaterialAnalysisPlanItemInput>[];
    final products = {
      for (final product
          in _analysis?.products ?? const <ProductionMaterialAnalysisProduct>[])
        product.analysisLineId: product,
    };
    for (final analysisLineId in _selectedPlanLineIds) {
      final product = products[analysisLineId];
      final controller = _batchQtyControllers[analysisLineId];
      if (product == null ||
          controller == null ||
          !_canSelectProduct(product)) {
        context.appWarning('所选产品状态已变化，请重新勾选');
        return null;
      }
      final raw = controller.text.trim();
      final quantity = double.tryParse(raw);
      if (raw.isEmpty || quantity == null || !quantity.isFinite) {
        context.appWarning('请填写本批生产数量');
        return null;
      }
      if (quantity <= 0) {
        context.appWarning('本批生产数量必须大于 0');
        return null;
      }
      // The headline "最多可生产" is the cap. The server re-checks on preview
      // (its recomputed ready-now qty is authoritative), but blocking an
      // over-cap entry here avoids a pointless round-trip and a confusing
      // rejection deeper in the wizard.
      final maxQty = product.readyNowQty;
      if (quantity > maxQty) {
        context.appWarning('本批生产数量不能超过最多可生产 ${_qty(maxQty)} 个');
        return null;
      }
      items.add(
        MaterialAnalysisPlanItemInput(
          analysisLineId: analysisLineId,
          qty: quantity,
        ),
      );
    }
    if (items.isEmpty) {
      context.appWarning('请至少勾选一个可生产产品或自制备料项');
      return null;
    }
    return items;
  }

  Future<bool> _previewPlan(List<MaterialAnalysisPlanItemInput> items) async {
    final analysis = _analysis;
    final warehouseId = _warehouseId;
    if (analysis == null || warehouseId == null || _previewingPlan) {
      return false;
    }
    if (!_canGenerate) return false;
    if (_dirtyRouteGroups.isNotEmpty) {
      context.appWarning('请先确认物料路线');
      return false;
    }
    setState(() {
      _previewingPlan = true;
      _planPreview = null;
    });
    try {
      final preview = await ref
          .read(productionPlanRepositoryProvider)
          .previewMaterialAnalysisPlan(
            analysis: analysis,
            warehouseId: warehouseId,
            items: items,
          );
      if (!mounted) return false;
      setState(() {
        _previewingPlan = false;
        _planPreview = preview;
      });
      if (!preview.canGenerate) {
        context.appWarning('计划预览发现仍有不可生成批次，请按行内原因调整数量');
        return false;
      } else {
        context.appSuccess('计划预览通过，可提交生成');
        return true;
      }
    } catch (error) {
      if (!mounted) return false;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '生产计划预览',
      )) {
        if (!mounted) return false;
        setState(() => _previewingPlan = false);
        return false;
      }
      if (!mounted) return false;
      setState(() => _previewingPlan = false);
      context.appError(
        productionErrorMessage(error, fallback: '计划预览失败，请刷新分析后重试'),
        force: true,
      );
      return false;
    }
  }

  Future<void> _generatePlan(
    List<MaterialAnalysisPlanItemInput> items, {
    bool approveNow = false,
  }) async {
    final preview = _planPreview;
    final warehouseId = _warehouseId;
    if (preview == null || warehouseId == null || _generating) return;
    if (!preview.canGenerate) {
      context.appWarning('计划预览未通过，不能生成生产计划');
      return;
    }
    final key = businessIdempotencyKey(
      'material-analysis-generate-plan',
      [
        preview.analysisId,
        preview.version,
        preview.previewFingerprint,
        _dateText(_billDate),
        _dateText(_deliveryDate),
        approveNow,
        for (final item in items) item.toJson().toString(),
      ].join('|'),
    );
    setState(() => _generating = true);
    try {
      final result = await ref
          .read(productionPlanRepositoryProvider)
          .generateMaterialAnalysisPlan(
            preview: preview,
            warehouseId: warehouseId,
            idempotencyKey: key,
            billDate: _dateText(_billDate)!,
            deliveryDate: _dateText(_deliveryDate),
            departmentId: widget.seed.departmentId,
            workshopName: widget.seed.workshopName,
            workerId: widget.seed.workerId,
            approveNow: approveNow,
            items: items,
          );
      if (!mounted) return;
      setState(() {
        _generating = false;
        _applyAnalysis(result.analysis);
      });
      context.appSuccess(approveNow ? '生产计划已审核下达，物料提货单已生成' : '生产计划已生成并提交审批');
      await _showGeneratedPlans(result.plans);
    } catch (error) {
      if (!mounted) return;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '生成生产计划',
      )) {
        if (!mounted) return;
        setState(() => _generating = false);
        return;
      }
      if (!mounted) return;
      setState(() {
        _generating = false;
        _planPreview = null;
      });
      context.appError(
        productionErrorMessage(error, fallback: '库存或分析状态已变化，请重新计划预览'),
        force: true,
      );
    }
  }

  /// 打开可深链恢复的备料计划汇总单；当前视图只作为首帧快照，
  /// 硬刷新时汇总页按 analysisId 重新读取权威详情。
  Future<void> _openSummarySheet() async {
    final analysis = _analysis;
    if (analysis == null) return;
    await context.push(
      RoutePath.productionMaterialAnalysisSummary(analysis.analysisId),
      extra: analysis,
    );
  }

  Future<void> _openPlanWizard() async {
    if (!_canGenerate || _busy || _editingPriorities) return;
    if (_dirtyRouteGroups.isNotEmpty) {
      context.appWarning('请先确认物料路线');
      return;
    }
    final initialItems = _planItems();
    final analysis = _analysis;
    if (initialItems == null || analysis == null) return;
    final products = {
      for (final product in analysis.products) product.analysisLineId: product,
    };
    final masterNames = ref.read(masterNameServiceProvider);
    // 默认车间预填：读取正式排产确认学习出的偏好；seed 显式指定优先。
    // 接口失败降级为空表——向导照常打开，未预填的行在计划单上红色提示补填。
    Map<String, ({String departmentId, String? departmentName})>
    defaultWorkshops = const {};
    try {
      defaultWorkshops = await ref
          .read(productionPlanRepositoryProvider)
          .defaultWorkshops({
            for (final item in initialItems)
              if (products[item.analysisLineId]?.goodsId != null)
                products[item.analysisLineId]!.goodsId!,
          });
    } catch (_) {
      defaultWorkshops = const {};
    }
    if (!mounted) return;
    final result = await Navigator.of(context).push<ProductionPlanWizardResult>(
      MaterialPageRoute(
        builder: (_) => ProductionPlanWizardPage(
          canApprove: _permissions.contains(Perm.productionPlanApprove),
          entries: [
            for (final item in initialItems)
              ProductionPlanWizardEntry(
                product: products[item.analysisLineId]!,
                qty: item.qty,
                productNo: widget.seed.initialProductNoFor(
                  products[item.analysisLineId]!,
                ),
                billDate: _billDate,
                deliveryDate: _deliveryDate,
                departmentId:
                    widget.seed.departmentId ??
                    defaultWorkshops[products[item.analysisLineId]!.goodsId]
                        ?.departmentId,
                workshopName:
                    widget.seed.workshopName ??
                    defaultWorkshops[products[item.analysisLineId]!.goodsId]
                        ?.departmentName,
                workerId: widget.seed.workerId,
                workerName: widget.seed.workerId == null
                    ? null
                    : masterNames.employee(widget.seed.workerId) == '—'
                    ? null
                    : masterNames.employee(widget.seed.workerId),
              ),
          ],
        ),
      ),
    );
    if (!mounted || result == null || result.items.isEmpty) return;
    setState(() => _planSubmissionApproveNow = result.approveNow);
    try {
      final previewPassed = await _previewPlan(result.items);
      if (!mounted || !previewPassed) return;
      await _generatePlan(result.items, approveNow: result.approveNow);
    } finally {
      if (mounted && _planSubmissionApproveNow) {
        setState(() => _planSubmissionApproveNow = false);
      }
    }
  }

  /// 生成结果对话框：把「生产计划单 + 物料提货单（领料单）」摆在同一屏。
  /// - 已审核下达（approveNow）：列出随计划包自动生成的提货单，可直接打开；
  /// - 待审核：明说下一步——审核并正式下达后系统自动出提货单，仓库按单发料。
  Future<void> _openGeneratedPlanPrint(ProductionGeneratedPlanRef plan) async {
    final packageId = plan.packageId?.trim();
    if (packageId == null || packageId.isEmpty) {
      context.appWarning('当前生成结果没有可打印的确认计划包，请进入计划详情核对');
      return;
    }
    final repo = ref.read(productionPlanRepositoryProvider);
    await showProductionExecutionCardPrintPreview(
      context,
      loader: () => repo.productionWorkCards(plan.planId, packageId),
    );
  }

  Future<void> _showGeneratedPlans(
    List<ProductionGeneratedPlanRef> plans,
  ) async {
    final valid = plans.where((plan) => plan.planId.isNotEmpty).toList();
    if (valid.isEmpty || !mounted) return;
    if (valid.length == 1) {
      final action = await showDialog<_GeneratedPlanDialogAction>(
        context: context,
        builder: (dialogContext) {
          final plan = valid.single;
          final approved = plan.status == 'APPROVED';
          final printable =
              approved && plan.packageId?.trim().isNotEmpty == true;
          return AlertDialog(
            title: Text(
              approved && plan.drawDocuments.isNotEmpty
                  ? '计划单与提货单已生成'
                  : approved
                  ? '生产计划已审核下达'
                  : '生产计划已生成',
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.assignment_turned_in_outlined),
                    title: Text('生产计划单 ${plan.planNo ?? plan.planId}'),
                    subtitle: Text(approved ? '已审核下达' : '待审核'),
                  ),
                  if (plan.drawDocuments.isNotEmpty) ...[
                    const Divider(height: UtenSpacing.s16),
                    for (final draw in plan.drawDocuments)
                      ListTile(
                        key: ValueKey('generated-draw-${draw.drawId}'),
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.outbound_outlined),
                        title: Text('物料提货单(领料单)${draw.billNo ?? ''}'),
                        subtitle: const Text('仓库按单发料 · 点击打开'),
                        onTap: () {
                          Navigator.pop(dialogContext);
                          context.push(
                            RoutePath.stockDocDetail('DRAW', draw.drawId),
                          );
                        },
                      ),
                  ] else ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      approved
                          ? '本批没有下层领用物料，不生成领料单；'
                                '计划审核后直接进入派工、报工、FQC 与完工入库。'
                          : '计划审核并正式下达后，系统自动生成物料提货单(领料单)，'
                                '仓库按单发料；可在「生产计划详情」查看进度。',
                      style: Theme.of(dialogContext).textTheme.bodyMedium
                          ?.copyWith(
                            color: Theme.of(
                              dialogContext,
                            ).colorScheme.onSurfaceVariant,
                            height: 1.45,
                          ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('留在物料分析'),
              ),
              if (printable)
                OutlinedButton.icon(
                  key: ValueKey('generated-plan-print-${plan.planId}'),
                  onPressed: () => Navigator.pop(
                    dialogContext,
                    _GeneratedPlanDialogAction.print(plan),
                  ),
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('打印生产计划单'),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _GeneratedPlanDialogAction.view(plan),
                ),
                child: const Text('查看计划'),
              ),
            ],
          );
        },
      );
      if (!mounted || action == null) return;
      if (action.print) {
        await _openGeneratedPlanPrint(action.plan);
      } else {
        await context.push(RoutePath.productionPlanDetail(action.plan.planId));
      }
      return;
    }
    final action = await showDialog<_GeneratedPlanDialogAction>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('已生成生产计划'),
        children: [
          for (final plan in valid)
            ListTile(
              key: ValueKey('generated-plan-row-${plan.planId}'),
              onTap: () => Navigator.pop(
                dialogContext,
                _GeneratedPlanDialogAction.view(plan),
              ),
              leading: const Icon(Icons.assignment_turned_in_outlined),
              title: Text(plan.planNo ?? plan.planId),
              subtitle: Text(
                plan.status == 'APPROVED'
                    ? plan.drawDocuments.isNotEmpty
                          ? '已审核下达 · 提货单 ${plan.drawDocuments.length} 张'
                          : '已审核下达 · 本批无需领料'
                    : '待审核 · 审核下达后按需生成提货单',
              ),
              trailing:
                  plan.status == 'APPROVED' &&
                      plan.packageId?.trim().isNotEmpty == true
                  ? IconButton(
                      key: ValueKey('generated-plan-print-${plan.planId}'),
                      tooltip: '打印生产计划单',
                      onPressed: () => Navigator.pop(
                        dialogContext,
                        _GeneratedPlanDialogAction.print(plan),
                      ),
                      icon: const Icon(Icons.print_outlined),
                    )
                  : const Icon(Icons.chevron_right_rounded),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext),
            child: const ListTile(
              leading: Icon(Icons.arrow_back_rounded),
              title: Text('留在物料分析'),
            ),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action.print) {
      await _openGeneratedPlanPrint(action.plan);
    } else {
      await context.push(RoutePath.productionPlanDetail(action.plan.planId));
    }
  }

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

  Widget _candidateBody(ThemeData theme) {
    if (_error != null && _candidatePage == null) {
      return _errorState(_error!, _loadCandidates);
    }
    final page = _candidatePage;
    final lines = (page?.lines ?? const <MaterialAnalysisSalesCandidateLine>[])
        .where((line) => line.remainingQty == null || line.remainingQty! > 0)
        .toList(growable: false);
    if (context.breakpoint.isCompact) {
      return _compactCandidateBody(theme, page, lines);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _introCard(theme),
          const SizedBox(height: UtenSpacing.s8),
          _manualSourceCard(theme),
          const SizedBox(height: UtenSpacing.s8),
          _candidateToolbar(theme),
          const SizedBox(height: UtenSpacing.s8),
          if (_error != null)
            _inlineError(theme, _error!, () => _loadCandidates()),
          Expanded(
            child: MasterDataTableView<MaterialAnalysisSalesCandidateLine>(
              key: const Key('material-analysis-candidate-table'),
              columns: _candidateColumns,
              items: lines,
              selectable: _canManage,
              idOf: (line) =>
                  (line.remainingQty ?? 0) > 0 ? line.salesOrderItemId : null,
              selectedIds: _sourceQtyControllers.keys.toSet(),
              onSelectedIdsChanged: (ids) => _replaceCandidateIds(ids, lines),
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              isLoading: _loadingCandidates,
              emptyMessage: '暂无可分析的已审销售订单产品',
              currentPage: page?.page ?? _candidatePageNo,
              totalPages: page?.totalPages ?? 1,
              onPageChange: (value) => _loadCandidates(page: value),
            ),
          ),
          if (_sourceQtyControllers.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            _selectedSourceEditor(theme),
          ],
        ],
      ),
    );
  }

  Widget _candidateStartButton() {
    final selectedCount = _sourceQtyControllers.length + _manualSources.length;
    return UtenButton(
      key: const Key('material-analysis-start'),
      size: UtenButtonSize.large,
      icon: Icons.insights_outlined,
      isLoading: _previewingAnalysis,
      onPressed: !_canManage || selectedCount == 0 || _previewingAnalysis
          ? null
          : _startCandidateAnalysis,
      onDisabledTap: !_canManage
          ? () => context.appWarning('没有新建或刷新物料分析权限')
          : selectedCount == 0
          ? () => context.appWarning('请先选择销售产品或添加手工需求')
          : null,
      child: Text(selectedCount == 0 ? '联合分析所选产品' : '联合分析所选产品($selectedCount)'),
    );
  }

  Widget? _candidateFloatingAction() {
    if (!_canManage) return null;
    return UtenFloatingActionGroup(children: [_candidateStartButton()]);
  }

  Widget _compactCandidateBody(
    ThemeData theme,
    MaterialAnalysisSalesCandidatePage? page,
    List<MaterialAnalysisSalesCandidateLine> lines,
  ) => CustomScrollView(
    key: const Key('material-analysis-candidate-mobile-list'),
    slivers: [
      const SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s8)),
      SliverToBoxAdapter(child: _introCard(theme)),
      const SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s8)),
      SliverToBoxAdapter(child: _compactManualSourceSection(theme)),
      const SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s8)),
      SliverToBoxAdapter(child: _candidateToolbar(theme)),
      if (_loadingCandidates)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: UtenSpacing.s8),
            child: LinearProgressIndicator(),
          ),
        ),
      if (_error != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: _inlineError(theme, _error!, () => _loadCandidates()),
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s8)),
      if (lines.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(UtenSpacing.s20),
            child: Center(child: Text('暂无可分析的已审销售订单产品')),
          ),
        )
      else
        SliverList(
          delegate: SliverChildBuilderDelegate((_, index) {
            if (index.isOdd) {
              return const SizedBox(height: UtenSpacing.s8);
            }
            return _candidateMobileCard(theme, lines[index ~/ 2]);
          }, childCount: lines.length * 2 - 1),
        ),
      if (page != null)
        SliverToBoxAdapter(child: _compactCandidatePager(theme, page)),
      if (_sourceQtyControllers.isNotEmpty) ...[
        const SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s8)),
        SliverToBoxAdapter(child: _compactSelectedSourceSummary(theme)),
      ],
      const SliverToBoxAdapter(child: SizedBox(height: 96)),
    ],
  );

  Widget _compactManualSourceSection(ThemeData theme) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      OutlinedButton.icon(
        key: const Key('material-manual-source-toggle'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          alignment: Alignment.centerLeft,
          textStyle: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        onPressed: () =>
            setState(() => _manualSourceExpanded = !_manualSourceExpanded),
        icon: Icon(
          _manualSourceExpanded
              ? Icons.expand_less_rounded
              : Icons.add_business_outlined,
        ),
        label: Text(
          _manualSources.isEmpty
              ? '其他需求(返工 / 试制 / 样品 / 备库)'
              : '其他需求(已加入 ${_manualSources.length} 项)',
        ),
      ),
      if (!_manualSourceExpanded)
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s4),
          child: Text(
            '销售订单产品不用打开这里，直接在下方勾选。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      if (_manualSourceExpanded) ...[
        const SizedBox(height: UtenSpacing.s8),
        _manualSourceCard(theme),
      ],
    ],
  );

  Widget _compactSelectedSourceSummary(ThemeData theme) => Container(
    key: const Key('material-compact-selected-summary'),
    constraints: const BoxConstraints(minHeight: 64),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Row(
      children: [
        Icon(Icons.checklist_rounded, color: theme.colorScheme.primary),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '已选 ${_sourceQtyControllers.length} 个销售产品',
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '数量已按待排量预填，只需核对例外。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        OutlinedButton(
          key: const Key('material-compact-edit-selected-qty'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(88, 52),
            textStyle: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          onPressed: _showCompactSelectedSourceEditor,
          child: const Text('核对数量'),
        ),
      ],
    ),
  );

  Future<void> _showCompactSelectedSourceEditor() async {
    final entries = _sourceQtyControllers.entries.toList(growable: false);
    if (entries.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.9,
        child: Material(
          color: Theme.of(sheetContext).colorScheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Row(
                  children: [
                    const Icon(Icons.edit_note_rounded, size: 28),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '核对本次分析数量',
                            style: Theme.of(sheetContext).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          Text(
                            '共 ${entries.length} 项；默认值来自当前待排量，只修改例外。',
                            style: Theme.of(sheetContext).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  key: const Key('material-compact-selected-qty-list'),
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  itemCount: entries.length,
                  itemBuilder: (_, index) {
                    final entry = entries[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                      child: TextField(
                        key: Key('source-qty-${entry.key}'),
                        controller: entry.value,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText:
                              _selectedCandidateLabels[entry.key] ?? '所选产品',
                          helper: const UtenFieldMessage.helper('本次分析数量'),
                        ),
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('数量核对完成'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _introCard(ThemeData theme) => Container(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline_rounded, color: theme.colorScheme.primary),
        const SizedBox(width: UtenSpacing.s8),
        const Expanded(
          child: Text(
            '先选择销售订单产品和分析仓库。系统会一次加载完整组装树；'
            '结果默认显示完整 BOM，可搜索或切换“只看缺料”“待确认路线”。'
            '生产计划只从服务端确认可生产的批次数量生成。',
          ),
        ),
      ],
    ),
  );

  Widget _manualSourceCard(ThemeData theme) {
    final compact = context.breakpoint.isCompact;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.mdAll,
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.add_business_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '手工计划(返工 / 试制 / 样品 / 备库)',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '手工计划也必须先做物料分析；需求编号用于后续找回任务，来源原因会随分析留痕。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: compact ? double.infinity : 180,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('manual-source-${_manualSourceType ?? ''}'),
                    initialValue: _manualSourceType,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '来源类型 *'),
                    items: [
                      for (final entry in _manualSourceTypes.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: _busy || !_canManage
                        ? null
                        : (value) => setState(() => _manualSourceType = value),
                  ),
                ),
                SizedBox(
                  width: compact ? double.infinity : 220,
                  child: TextField(
                    key: const Key('manual-source-ref'),
                    controller: _manualSourceRef,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: '需求编号 *',
                      hintText: '例：RW-20260808-001',
                      helper: UtenFieldMessage.helper('同一需求请始终使用同一个编号'),
                    ),
                  ),
                ),
                SizedBox(
                  width: compact ? double.infinity : 280,
                  child: OutlinedButton.icon(
                    key: const Key('manual-source-goods'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 52),
                      alignment: Alignment.centerLeft,
                    ),
                    onPressed: _busy || !_canManage ? null : _pickManualGoods,
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: Text(
                      _manualGoods == null
                          ? '选择货品 *'
                          : '${_manualGoods!.code ?? ''} ${_manualGoods!.name ?? ''}'
                                .trim(),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                SizedBox(
                  width: compact ? double.infinity : 140,
                  child: TextField(
                    key: const Key('manual-source-qty'),
                    controller: _manualQty,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: '数量 *'),
                  ),
                ),
                SizedBox(
                  width: compact ? double.infinity : 220,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 52),
                    ),
                    onPressed: _busy || !_canManage
                        ? null
                        : _pickManualDeliveryDate,
                    icon: const Icon(Icons.event_outlined),
                    label: Text(
                      '需求日 ${_dateText(_manualDeliveryDate) ?? '未设置'}',
                    ),
                  ),
                ),
                SizedBox(
                  width: compact ? double.infinity : 300,
                  child: TextField(
                    key: const Key('manual-source-reason'),
                    controller: _manualReason,
                    decoration: const InputDecoration(
                      labelText: '来源原因 *',
                      hintText: '例：客诉返工、展会样品、安全备库',
                    ),
                  ),
                ),
                UtenButton(
                  key: const Key('manual-source-add'),
                  type: UtenButtonType.tonal,
                  size: UtenButtonSize.large,
                  icon: Icons.add_rounded,
                  onPressed: _busy || !_canManage ? null : _addManualSource,
                  child: const Text('加入分析'),
                ),
              ],
            ),
            if (_manualSources.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s8),
              for (final source in _manualSources)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.fact_check_outlined),
                  title: Text(
                    _manualSourceLabels[source.canonicalKey] ??
                        source.goodsId ??
                        '手工货品',
                  ),
                  subtitle: Text(
                    '${_manualSourceTypes[source.sourceType] ?? source.sourceType} · '
                    '${source.sourceRef} · ${_qty(source.requestedQty)} · '
                    '${source.sourceReason}',
                  ),
                  trailing: IconButton(
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: '移除手工来源',
                    onPressed: _busy ? null : () => _removeManualSource(source),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _candidateToolbar(ThemeData theme) => Wrap(
    spacing: UtenSpacing.s8,
    runSpacing: UtenSpacing.s8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      SizedBox(
        width: context.breakpoint.isCompact ? double.infinity : 320,
        child: TextField(
          controller: _candidateSearch,
          onChanged: _searchCandidates,
          decoration: const InputDecoration(
            labelText: '搜索销售单号或货品',
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
      ),
      SizedBox(width: 260, child: _warehouseField()),
    ],
  );

  Widget _warehouseField() {
    final entries = ref.watch(masterNameServiceProvider).warehouseEntries;
    return DropdownButtonFormField<String>(
      key: const Key('material-analysis-warehouse'),
      initialValue: entries.containsKey(_warehouseId) ? _warehouseId : null,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '分析仓库'),
      items: [
        for (final entry in entries.entries)
          DropdownMenuItem(value: entry.key, child: Text(entry.value)),
      ],
      onChanged: _busy ? null : _changeWarehouse,
    );
  }

  List<MasterColumnDef<MaterialAnalysisSalesCandidateLine>>
  get _candidateColumns => [
    MasterColumnDef(
      key: 'orderNo',
      label: '销售单号',
      width: 150,
      value: (line) => line.orderNo,
    ),
    MasterColumnDef(
      key: 'goods',
      label: '产品 / 规格',
      width: 250,
      value: (line) => [
        line.goodsCode,
        line.goodsName,
        line.spec,
      ].whereType<String>().where((value) => value.isNotEmpty).join(' · '),
    ),
    MasterColumnDef(
      key: 'remainingQty',
      label: '待排数量',
      width: 110,
      type: 'number',
      value: (line) => _qty(line.remainingQty),
    ),
    MasterColumnDef(
      key: 'deliveryDate',
      label: '交货日期',
      width: 120,
      type: 'date',
      value: (line) => _dateOnly(line.deliveryDate),
    ),
    MasterColumnDef(
      key: 'analysisStatus',
      label: '分析状态',
      width: 120,
      value: (line) => _analysisStatusText(line.analysisStatus),
    ),
  ];

  Widget _candidateMobileCard(
    ThemeData theme,
    MaterialAnalysisSalesCandidateLine line,
  ) {
    final selected = _candidateSelected(line);
    final selectable = _canManage && (line.remainingQty ?? 0) > 0;
    return Card(
      key: ValueKey('material-candidate-card-${line.salesOrderItemId}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: selectable ? () => _toggleCandidate(line, !selected) : null,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_canManage) ...[
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Checkbox(
                    value: selected,
                    onChanged: selectable
                        ? (value) => _toggleCandidate(line, value ?? false)
                        : null,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      line.goodsName ?? line.goodsCode ?? '未命名产品',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      [
                        line.orderNo,
                        line.goodsCode,
                        line.spec,
                        line.colorName,
                      ].whereType<String>().join(' · '),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '待排 ${_qty(line.remainingQty)} · 交货 ${_dateOnly(line.deliveryDate)} · '
                      '${_analysisStatusText(line.analysisStatus)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _compactCandidatePager(
    ThemeData theme,
    MaterialAnalysisSalesCandidatePage page,
  ) {
    final totalPages = page.totalPages > 0 ? page.totalPages : 1;
    final currentPage = page.page.clamp(1, totalPages);
    return Container(
      key: const Key('material-candidate-mobile-pagination'),
      constraints: const BoxConstraints(minHeight: 64),
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextButton.icon(
              key: const Key('material-candidate-prev-page'),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _loadingCandidates || currentPage <= 1
                  ? null
                  : () => _loadCandidates(page: currentPage - 1),
              icon: const Icon(Icons.chevron_left_rounded),
              label: const Text('上一页'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
            child: Text(
              '第 $currentPage / $totalPages 页\n共 ${page.total} 项',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              key: const Key('material-candidate-next-page'),
              style: TextButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _loadingCandidates || currentPage >= totalPages
                  ? null
                  : () => _loadCandidates(page: currentPage + 1),
              iconAlignment: IconAlignment.end,
              icon: const Icon(Icons.chevron_right_rounded),
              label: const Text('下一页'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectedSourceEditor(ThemeData theme) {
    final entries = _sourceQtyControllers.entries.toList(growable: false);
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '已选 ${entries.length} 个产品 · 数量已预填，只需修改例外',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Expanded(
            child: ListView.builder(
              itemCount: entries.length,
              itemBuilder: (_, index) {
                final entry = entries[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                  child: TextField(
                    key: Key('source-qty-${entry.key}'),
                    controller: entry.value,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: _selectedCandidateLabels[entry.key] ?? '所选产品',
                      helper: const UtenFieldMessage.helper('本次分析数量'),
                    ),
                  ),
                );
              },
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

  /// 合格到货只有进入本分析目标仓，才能参与当前备料计算。服务端的
  /// warehouseBreakdown 会返回本分析在每个仓的有效预留归属；这里按物料维度
  /// 去重后筛出非目标仓，避免同 SKU 在多个 BOM 兄弟节点上重复报数。
  List<_OffTargetWarehousePeg> _offTargetWarehousePegs(
    ProductionMaterialAnalysisView analysis,
  ) {
    final targetWarehouseId = analysis.warehouseId?.trim();
    if (targetWarehouseId == null || targetWarehouseId.isEmpty) return const [];

    final seenDimensions = <String>{};
    final result = <_OffTargetWarehousePeg>[];
    for (final material in analysis.materials) {
      final dimensionKey = _materialDimensionKey(material);
      if (!seenDimensions.add(dimensionKey)) continue;

      for (final stock in material.warehouseStocks) {
        if (stock.warehouseId == targetWarehouseId || stock.ownPeggedQty <= 0) {
          continue;
        }
        result.add(
          _OffTargetWarehousePeg(
            materialLabel: _goodsLabel(material),
            unitName: material.unitName,
            warehouseLabel:
                stock.warehouseName ?? stock.warehouseCode ?? stock.warehouseId,
            qty: stock.ownPeggedQty,
          ),
        );
      }
    }
    result.sort((left, right) {
      final byWarehouse = left.warehouseLabel.compareTo(right.warehouseLabel);
      return byWarehouse != 0
          ? byWarehouse
          : left.materialLabel.compareTo(right.materialLabel);
    });
    return List.unmodifiable(result);
  }

  String _materialDimensionKey(ProductionMaterialAnalysisMaterial material) {
    final materialKey = material.materialKey?.trim();
    if (materialKey?.isNotEmpty == true) return materialKey!;
    return [
      material.goodsId ?? material.materialLineId,
      material.colorId ?? 'NONE',
      material.unitId ?? 'NONE',
    ].join('|');
  }

  String _goodsLabel(ProductionMaterialAnalysisMaterial material) {
    final name = material.goodsName?.trim();
    final code = material.goodsCode?.trim();
    if (name?.isNotEmpty == true && code?.isNotEmpty == true) {
      return '$name($code)';
    }
    return name?.isNotEmpty == true
        ? name!
        : code?.isNotEmpty == true
        ? code!
        : '未命名物料';
  }

  Widget _offTargetWarehouseBanner(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
    List<_OffTargetWarehousePeg> pegs,
  ) {
    final targetWarehouse = analysis.warehouses
        .where((warehouse) => warehouse.warehouseId == analysis.warehouseId)
        .firstOrNull;
    final targetWarehouseLabel =
        targetWarehouse?.warehouseName ?? analysis.warehouseId ?? '当前分析仓';
    return Semantics(
      container: true,
      liveRegion: true,
      label: '合格到货在非分析仓，当前不计入备料',
      child: Container(
        key: const Key('material-analysis-off-target-warehouse-warning'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.55),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(
            color: theme.colorScheme.error.withValues(alpha: 0.55),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '合格到货在非分析仓，当前不计入备料',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '目标仓：$targetWarehouseLabel。以下数量已通过品质并绑定本分析，'
                    '但实际位于其它仓：',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  for (final peg in pegs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
                      child: Text(
                        '• ${peg.materialLabel}：${peg.warehouseLabel} '
                        '${_qty(peg.qty)}${peg.unitName?.isNotEmpty == true ? ' ${peg.unitName}' : ''}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          fontWeight: FontWeight.w700,
                          height: 1.45,
                        ),
                      ),
                    ),
                  Text(
                    '普通调拨不会迁移这笔分析绑定。请走收货红冲/更正流程，'
                    '并在目标仓重新登记、验收；处理后刷新分析。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      height: 1.45,
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

  /// 树顶筛选按钮（全部 BOM/只看缺料/待确认路线 + 按产品看/按物料汇总）。
  /// 与旁边搜索框等高（最小 48px）、纯文字无图标；选中态用主题深绿实底 +
  /// 白字——默认 ChoiceChip 的选中色偏淡，年长用户看不出当前选中了哪个视图。
  Widget _bomViewChip(
    ThemeData theme, {
    Key? key,
    required bool selected,
    required VoidCallback? onSelected,
    required String label,
  }) {
    final scheme = theme.colorScheme;
    final foreground = selected ? scheme.onPrimary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        key: key,
        color: selected ? scheme.primary : scheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
          ),
        ),
        child: InkWell(
          onTap: onSelected,
          canRequestFocus: onSelected != null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s16,
                vertical: UtenSpacing.s4,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 统一树顶部的批量选择栏：按路线（采购/委外/自制）全选当前可执行缺料。
  Widget _unifiedBomTreeHeader(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
    final chips = <Widget>[];
    for (final route in MaterialSupplyRoute.values) {
      final executable = _executableSupplyGroups(route);
      if (executable.isEmpty) continue;
      final selected = _selectedSupplyGroups[route]!;
      final selectedCount = executable
          .where((group) => selected.contains(group.key))
          .length;
      chips.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: Checkbox(
                key: Key('material-route-select-all-${route.wireName}'),
                tristate: true,
                value: _supplyHeaderValue(route),
                onChanged: !_canNotify || _busy
                    ? null
                    : (value) => _toggleAllSupplyGroups(route, value == true),
              ),
            ),
            _typeBadge(theme, route),
            const SizedBox(width: UtenSpacing.s4),
            Text(
              '${route.label}缺料 ${executable.length} · 已选 $selectedCount',
              style: theme.textTheme.bodySmall?.copyWith(
                color: _routeColor(theme, route),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }
    final projection = _bomFilterProjection(analysis);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 300,
                child: TextField(
                  key: const Key('material-bom-search'),
                  controller: _bomSearch,
                  onChanged: _scheduleBomSearch,
                  decoration: InputDecoration(
                    labelText: '查找产品或物料',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _bomKeyword.isEmpty
                        ? null
                        : IconButton(
                            constraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            tooltip: '清除查找',
                            onPressed: () {
                              _bomSearchDebounce?.cancel();
                              setState(() {
                                _bomSearch.clear();
                                _bomKeyword = '';
                                _bomProductVisibleLimit = _bomProductPageSize;
                              });
                            },
                            icon: const Icon(Icons.clear_rounded),
                          ),
                  ),
                ),
              ),
              for (final mode in _BomViewMode.values)
                _bomViewChip(
                  theme,
                  key: ValueKey('material-bom-view-${mode.name}'),
                  selected: _bomViewMode == mode,
                  onSelected: () => setState(() {
                    _bomViewMode = mode;
                    _bomProductVisibleLimit = _bomProductPageSize;
                  }),
                  label: '${mode.label} ${_bomModeCount(analysis, mode)}',
                ),
              // 排布切换：按产品看 BOM 树（默认）/ 按物料汇总缺料。
              // 多产品联合分析时物料行非常多，按物料汇总把同一物料跨产品
              // 聚成一行，是给采购/委外下单用的决策视图；任务身份不合并。
              _bomViewChip(
                theme,
                key: const ValueKey('material-bom-layout-product'),
                selected: !_bomAggregateByMaterial,
                onSelected: _bomAggregateByMaterial
                    ? () => setState(() => _bomAggregateByMaterial = false)
                    : null,
                label: '按产品看',
              ),
              _bomViewChip(
                theme,
                key: const ValueKey('material-bom-layout-material'),
                selected: _bomAggregateByMaterial,
                onSelected: _bomAggregateByMaterial
                    ? null
                    : () => setState(() => _bomAggregateByMaterial = true),
                label: '按物料汇总',
              ),
              Text(
                '筛选命中 ${projection.directMatchCount} 条；保留上级后共 '
                '${projection.visibleNodeCount} 条 / 全部 ${analysis.materials.length} 条',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            const Divider(height: 1),
            const SizedBox(height: UtenSpacing.s4),
            Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '批量选择(整次分析)',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                ...chips,
              ],
            ),
          ],
        ],
      ),
    );
  }

  int _bomModeCount(
    ProductionMaterialAnalysisView analysis,
    _BomViewMode mode,
  ) {
    final indexes = _analysisIndexes(analysis);
    return switch (mode) {
      _BomViewMode.shortage => indexes.shortageCount,
      _BomViewMode.unconfirmed => indexes.unconfirmedCount,
      _BomViewMode.all => analysis.materials.length,
    };
  }

  bool _bomModeMatches(ProductionMaterialAnalysisMaterial material) =>
      switch (_bomViewMode) {
        _BomViewMode.shortage => material.shortageQty > 0,
        _BomViewMode.unconfirmed =>
          material.shortageQty > 0 && material.confirmedRoute == null,
        _BomViewMode.all => true,
      };

  bool _bomTextMatches(
    ProductionMaterialAnalysisMaterial material,
    ProductionMaterialAnalysisProduct? product,
  ) {
    if (_bomKeyword.isEmpty) return true;
    return [
      product?.goodsCode,
      product?.goodsName,
      product?.orderNo,
      material.goodsCode,
      material.goodsName,
      material.spec,
      material.colorName,
    ].whereType<String>().any(
      (value) => value.toLowerCase().contains(_bomKeyword),
    );
  }

  void _scheduleBomSearch(String value) {
    _bomSearchDebounce?.cancel();
    _bomSearchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final keyword = value.trim().toLowerCase();
      if (keyword == _bomKeyword) return;
      setState(() {
        _bomKeyword = keyword;
        _bomProductVisibleLimit = _bomProductPageSize;
      });
    });
  }

  /// 只看缺料/待确认时仍把命中节点的祖先保留下来，员工能看懂它属于哪件产品、
  /// 哪条装配路径；祖先只是定位上下文，不会被误算为缺料或加入批量选择。
  List<ProductionMaterialAnalysisMaterial> _visibleBomNodes(
    List<ProductionMaterialAnalysisMaterial> nodes,
    ProductionMaterialAnalysisProduct? product,
  ) {
    if (_bomViewMode == _BomViewMode.all && _bomKeyword.isEmpty) return nodes;
    final byNodeKey = <String, ProductionMaterialAnalysisMaterial>{
      for (final node in nodes)
        if (node.nodeKey?.isNotEmpty == true) node.nodeKey!: node,
    };
    final visibleIds = <String>{};
    for (final node in nodes) {
      if (!_bomModeMatches(node) || !_bomTextMatches(node, product)) continue;
      ProductionMaterialAnalysisMaterial? current = node;
      while (current != null && visibleIds.add(current.materialLineId)) {
        final parentKey = current.parentNodeKey;
        current = parentKey == null ? null : byNodeKey[parentKey];
      }
    }
    return nodes
        .where((node) => visibleIds.contains(node.materialLineId))
        .toList(growable: false);
  }

  Color _routeColor(ThemeData theme, MaterialSupplyRoute? route) =>
      switch (route) {
        MaterialSupplyRoute.make => theme.colorScheme.primary,
        MaterialSupplyRoute.buy => theme.colorScheme.tertiary,
        MaterialSupplyRoute.subcontract => theme.colorScheme.secondary,
        null => theme.colorScheme.error,
      };

  Widget _bomTreeSliver(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
    if (_bomAggregateByMaterial) {
      return _materialAggregateSliver(theme, analysis);
    }
    final indexes = _analysisIndexes(analysis);
    final groupByLine = indexes.groupsByLine;
    final projection = _bomFilterProjection(analysis);
    final entries = <_BomTreeEntry>[];
    final matchingProducts = [
      for (final product in analysis.products)
        if (projection.nodesByProduct[product.analysisLineId]?.isNotEmpty ==
            true)
          product,
    ];
    final visibleProducts = matchingProducts
        .take(_bomProductVisibleLimit)
        .toList(growable: false);
    for (final product in visibleProducts) {
      final nodes = projection.nodesByProduct[product.analysisLineId]!;
      entries.add(_BomProductEntry(product));
      if (_collapsedBomProducts.contains(product.analysisLineId)) continue;
      final parentKeys = {
        for (final node in nodes)
          if (node.parentNodeKey?.isNotEmpty == true) node.parentNodeKey!,
      };
      for (final material in _orderedBomNodes(nodes)) {
        final group = groupByLine[material.materialLineId];
        if (group == null) continue;
        entries.add(
          _BomMaterialEntry(
            material,
            group,
            parentKeys.contains(material.nodeKey),
          ),
        );
      }
    }
    final remainingProducts = matchingProducts.length - visibleProducts.length;
    if (remainingProducts > 0) {
      entries.add(_BomLoadMoreEntry(remainingProducts));
    }
    final knownProductIds = analysis.products
        .map((product) => product.analysisLineId)
        .toSet();
    final unassigned = [
      for (final entry in projection.nodesByProduct.entries)
        if (entry.key == null || !knownProductIds.contains(entry.key))
          ...entry.value,
    ];
    if (unassigned.isNotEmpty) {
      entries.add(const _BomOrphanEntry());
      final parentKeys = {
        for (final node in unassigned)
          if (node.parentNodeKey?.isNotEmpty == true) node.parentNodeKey!,
      };
      for (final material in _orderedBomNodes(unassigned)) {
        final group = groupByLine[material.materialLineId];
        if (group != null) {
          entries.add(
            _BomMaterialEntry(
              material,
              group,
              parentKeys.contains(material.nodeKey),
            ),
          );
        }
      }
    }
    if (entries.isEmpty) entries.add(const _BomEmptyEntry());
    return SliverList(
      key: const Key('material-bom-tree'),
      delegate: SliverChildBuilderDelegate((_, index) {
        final entry = entries[index];
        return switch (entry) {
          _BomEmptyEntry() => _bomEmptyState(theme),
          _BomProductEntry(:final product) => _bomProductRoot(theme, product),
          _BomOrphanEntry() => _bomOrphanHeader(theme),
          _BomLoadMoreEntry(:final remainingProducts) => _bomLoadMore(
            theme,
            remainingProducts,
          ),
          _BomMaterialEntry(
            :final material,
            :final group,
            :final hasChildren,
          ) =>
            _unifiedBomNodeRow(
              theme,
              material,
              group,
              hasChildren: hasChildren,
            ),
        };
      }, childCount: entries.length),
    );
  }

  // ===== 按物料汇总缺料视图 =====
  //
  // 多产品联合分析（十几个、二十几个产品）时 BOM 节点可能上千行，
  // 平铺没法看。这里把同一物料跨产品的所有 BOM 路径聚成一行：
  // 行上看总需求/现货/总缺口/涉及产品数，展开后逐路径看「哪个产品、
  // 哪个父件各要多少」（pegging 明细）并直接勾选。聚合只是展示投影，
  // 勾选与下达仍写回各自的逐路径节点任务，合单不合账。

  /// 同一物料的稳定聚合键：货品 UUID + 颜色 + 单位；缺 UUID 时退回
  /// 编码/名称组合，避免把不同颜色或不同单位误并成一行。
  String _aggregateKeyOf(ProductionMaterialAnalysisMaterial material) {
    final goods =
        material.goodsId ??
        'CODE|${material.goodsCode ?? material.goodsName ?? material.materialLineId}';
    return '$goods|${material.colorId ?? material.colorName ?? ''}'
        '|${material.unitId ?? material.unitName ?? ''}';
  }

  List<_MaterialAggregate> _materialAggregates(
    ProductionMaterialAnalysisView analysis,
    _MaterialAnalysisIndexes indexes,
  ) {
    final byKey = <String, List<ProductionMaterialAnalysisMaterial>>{};
    for (final material in analysis.materials) {
      if (!_bomModeMatches(material)) continue;
      final product = indexes.productsById[material.analysisLineId];
      if (!_bomTextMatches(material, product)) continue;
      byKey.putIfAbsent(_aggregateKeyOf(material), () => []).add(material);
    }
    final aggregates = [
      for (final entry in byKey.entries)
        _MaterialAggregate(key: entry.key, paths: entry.value),
    ];
    // 缺口最大的排最前，让计划员先处理最卡脖子的料。
    aggregates.sort((a, b) {
      final byShortage = b.totalShortage.compareTo(a.totalShortage);
      if (byShortage != 0) return byShortage;
      return (a.goodsCode ?? a.goodsName ?? a.key).compareTo(
        b.goodsCode ?? b.goodsName ?? b.key,
      );
    });
    return aggregates;
  }

  Widget _materialAggregateSliver(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
    final indexes = _analysisIndexes(analysis);
    final aggregates = _materialAggregates(analysis, indexes);
    if (aggregates.isEmpty) {
      return SliverToBoxAdapter(
        child: Container(
          key: const Key('material-aggregate-empty'),
          margin: const EdgeInsets.only(top: UtenSpacing.s8),
          padding: const EdgeInsets.all(UtenSpacing.s20),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
            borderRadius: UtenRadius.mdAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              const Expanded(child: Text('当前筛选下没有缺料物料。可切换「全部 BOM」或清除查找。')),
            ],
          ),
        ),
      );
    }
    return SliverList(
      key: const Key('material-aggregate-list'),
      delegate: SliverChildBuilderDelegate((_, index) {
        if (index == 0) {
          return _materialAggregateIntro(theme, aggregates.length);
        }
        return _materialAggregateRow(theme, aggregates[index - 1], indexes);
      }, childCount: aggregates.length + 1),
    );
  }

  Widget _materialAggregateIntro(ThemeData theme, int count) => Container(
    key: const Key('material-aggregate-intro'),
    margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.summarize_outlined, color: theme.colorScheme.primary),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            '按物料汇总：共 $count 种物料。同一物料在多个产品里的缺口合成一行，'
            '缺口最大的排最前；点展开能看到每个产品各要多少。'
            '勾选和提交仍按每条装配路径分别记账，不会重复领料。',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
        ),
      ],
    ),
  );

  Widget _materialAggregateRow(
    ThemeData theme,
    _MaterialAggregate aggregate,
    _MaterialAnalysisIndexes indexes,
  ) {
    final expanded = _expandedMaterialAggregates.contains(aggregate.key);
    final ratio = aggregate.coverageRatio;
    final hasShortage = aggregate.totalShortage > 0;
    final route = aggregate.uniformSuggestion;
    final barColor = !hasShortage
        ? theme.colorScheme.primary
        : ratio <= 0
        ? theme.colorScheme.error
        : theme.colorScheme.tertiary;
    return Container(
      key: ValueKey('material-aggregate-${aggregate.key}'),
      margin: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: hasShortage
            ? theme.colorScheme.error.withValues(alpha: 0.08)
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(
          color: hasShortage
              ? theme.colorScheme.error.withValues(alpha: 0.5)
              : theme.colorScheme.outlineVariant,
          width: hasShortage ? 1.4 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                key: ValueKey('material-aggregate-toggle-${aggregate.key}'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                tooltip: expanded ? '收起各产品明细' : '展开各产品明细',
                onPressed: () => setState(() {
                  if (!_expandedMaterialAggregates.add(aggregate.key)) {
                    _expandedMaterialAggregates.remove(aggregate.key);
                  }
                }),
                icon: Icon(
                  expanded
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${aggregate.goodsName ?? aggregate.goodsCode ?? '未命名物料'}'
                      '${aggregate.spec?.isNotEmpty == true ? '(${aggregate.spec})' : ''}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      [
                        aggregate.goodsCode,
                        aggregate.colorName,
                        aggregate.unitName == null
                            ? null
                            : '单位 ${aggregate.unitName}',
                      ].whereType<String>().join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (route != null)
                _typeBadge(theme, route)
              else
                Tooltip(
                  message: '各路径的建议或确认路线不一致，展开后逐条查看',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s8,
                      vertical: UtenSpacing.s4,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: UtenRadius.smAll,
                      border: Border.all(color: theme.colorScheme.outline),
                    ),
                    child: Text(
                      '路线不一',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Wrap(
            spacing: UtenSpacing.s16,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '共需 ${_qty(aggregate.totalRequired)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '现货 ${_qty(aggregate.warehouseStock)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: aggregate.warehouseStock <= 0
                      ? theme.colorScheme.error
                      : null,
                  fontWeight: aggregate.warehouseStock <= 0
                      ? FontWeight.w700
                      : FontWeight.normal,
                ),
              ),
              Text(
                hasShortage ? '共缺 ${_qty(aggregate.totalShortage)}' : '已齐',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: hasShortage ? theme.colorScheme.error : null,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                '${aggregate.productCount} 个产品要用',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: UtenRadius.smAll,
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 10,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(barColor),
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                '备料 ${(ratio * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: hasShortage && ratio <= 0
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          if (expanded) ...[
            const SizedBox(height: UtenSpacing.s8),
            const Divider(height: 1),
            for (final material in aggregate.paths)
              _materialAggregatePathRow(theme, material, indexes),
          ],
        ],
      ),
    );
  }

  /// 汇总行展开后的单条 BOM 路径：哪个产品、哪个父件要这件料、要多少、
  /// 缺多少。选择控件与 BOM 树完全同款，路线确认、下层齐套、权限等
  /// 门禁一处生效，两处一致。
  Widget _materialAggregatePathRow(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialAnalysisIndexes indexes,
  ) {
    final group = indexes.groupsByLine[material.materialLineId];
    if (group == null) return const SizedBox.shrink();
    final product = indexes.productsById[material.analysisLineId];
    final route = _routeDraft[group.key] ?? material.sourceSuggestion;
    final selected =
        route != null &&
        (_selectedSupplyGroups[route]?.contains(group.key) ?? false);
    final status = _materialStatus(theme, group);
    final foreground = selected ? Colors.white : null;
    return Container(
      key: ValueKey('material-aggregate-path-${material.materialLineId}'),
      margin: const EdgeInsets.only(top: UtenSpacing.s12),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: selected
            ? UtenColors.deepGreen
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.smAll,
        border: Border.all(
          color: selected
              ? UtenColors.deepGreen
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _routeStateCell(
                theme,
                material,
                group,
                route,
                selected: selected,
              ),
              const SizedBox(width: UtenSpacing.s4),
              SizedBox(
                width: 48,
                height: 48,
                child: group.actionable
                    ? _nodeSelectionControl(
                        theme,
                        material,
                        group,
                        route,
                        selected,
                      )
                    : null,
              ),
              const SizedBox(width: UtenSpacing.s4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product?.goodsName ?? product?.goodsCode ?? '未归属产品',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '路径：${_pathLabel(material)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: foreground ?? theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              _nodeDetailsToggle(theme, group, foreground: foreground),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s16,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '需 ${_qty(material.requiredQty)}',
                style: TextStyle(color: foreground),
              ),
              Text(
                '配 ${_qty(material.allocatedAvailableQty)}',
                style: TextStyle(color: foreground),
              ),
              Text(
                material.shortageQty > 0
                    ? '缺 ${_qty(material.shortageQty)}'
                    : '已齐',
                style: TextStyle(
                  color: selected
                      ? Colors.white
                      : material.shortageQty > 0
                      ? theme.colorScheme.error
                      : null,
                  fontWeight: FontWeight.w700,
                ),
              ),
              // 已下达供给任务的路径状态可点：弹出供给全链路进度。
              if (_notifiedTargetOf(material) != null)
                InkWell(
                  key: ValueKey(
                    'material-supply-progress-${material.materialLineId}',
                  ),
                  borderRadius: UtenRadius.smAll,
                  onTap: () => _showSupplyProgress(group),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _statusLabel(
                        theme,
                        selected
                            ? _StatusView(
                                status.label,
                                status.icon,
                                Colors.white,
                              )
                            : status,
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.open_in_new_rounded,
                        size: 14,
                        color: selected ? Colors.white : status.color,
                      ),
                    ],
                  ),
                )
              else
                _statusLabel(
                  theme,
                  selected
                      ? _StatusView(status.label, status.icon, Colors.white)
                      : status,
                ),
            ],
          ),
          _borrowBadges(theme, material, selected: selected),
          if (_expandedPathGroups.contains(group.key))
            _nodeDetails(theme, group),
        ],
      ),
    );
  }

  Widget _bomEmptyState(ThemeData theme) => Container(
    key: const Key('material-bom-empty-filter'),
    margin: const EdgeInsets.only(top: UtenSpacing.s8),
    padding: const EdgeInsets.all(UtenSpacing.s20),
    decoration: BoxDecoration(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Row(
      children: [
        Icon(
          Icons.check_circle_outline_rounded,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: UtenSpacing.s8),
        const Expanded(child: Text('当前条件下没有物料任务。可切换“全部”或清除查找查看完整 BOM。')),
      ],
    ),
  );

  Widget _bomLoadMore(ThemeData theme, int remainingProducts) => Padding(
    padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
    child: Align(
      child: OutlinedButton.icon(
        key: const Key('material-bom-show-more-products'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(240, 52),
          textStyle: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        onPressed: () =>
            setState(() => _bomProductVisibleLimit += _bomProductPageSize),
        icon: const Icon(Icons.expand_more_rounded),
        label: Text('继续显示下一批产品(还有 $remainingProducts 个)'),
      ),
    ),
  );

  Widget _bomOrphanHeader(ThemeData theme) => Container(
    constraints: const BoxConstraints(minHeight: 52),
    margin: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.4)),
    ),
    child: Row(
      children: [
        Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
        const SizedBox(width: UtenSpacing.s8),
        const Expanded(child: Text('未归属产品的 BOM 节点，请检查分析数据')),
      ],
    ),
  );

  List<ProductionMaterialAnalysisMaterial> _orderedBomNodes(
    List<ProductionMaterialAnalysisMaterial> nodes,
  ) {
    final byNodeKey = <String, ProductionMaterialAnalysisMaterial>{
      for (final node in nodes)
        if (node.nodeKey?.isNotEmpty == true) node.nodeKey!: node,
    };
    final children = <String, List<ProductionMaterialAnalysisMaterial>>{};
    final roots = <ProductionMaterialAnalysisMaterial>[];
    for (final node in nodes) {
      final parentKey = node.parentNodeKey;
      if (parentKey == null ||
          parentKey.isEmpty ||
          parentKey == node.nodeKey ||
          !byNodeKey.containsKey(parentKey)) {
        roots.add(node);
      } else {
        children.putIfAbsent(parentKey, () => []).add(node);
      }
    }
    int compare(
      ProductionMaterialAnalysisMaterial left,
      ProductionMaterialAnalysisMaterial right,
    ) {
      final byLevel = left.level.compareTo(right.level);
      if (byLevel != 0) return byLevel;
      return (left.goodsCode ?? left.goodsName ?? left.materialLineId)
          .compareTo(
            right.goodsCode ?? right.goodsName ?? right.materialLineId,
          );
    }

    roots.sort(compare);
    for (final values in children.values) {
      values.sort(compare);
    }
    final result = <ProductionMaterialAnalysisMaterial>[];
    final visited = <String>{};
    void hide(ProductionMaterialAnalysisMaterial node) {
      if (!visited.add(node.materialLineId)) return;
      final key = node.nodeKey;
      if (key == null) return;
      for (final child
          in children[key] ?? const <ProductionMaterialAnalysisMaterial>[]) {
        hide(child);
      }
    }

    void visit(ProductionMaterialAnalysisMaterial node) {
      if (!visited.add(node.materialLineId)) return;
      result.add(node);
      final key = node.nodeKey;
      if (key == null) return;
      if (_collapsedBomBranches.contains(key)) {
        for (final child
            in children[key] ?? const <ProductionMaterialAnalysisMaterial>[]) {
          hide(child);
        }
        return;
      }
      for (final child
          in children[key] ?? const <ProductionMaterialAnalysisMaterial>[]) {
        visit(child);
      }
    }

    for (final root in roots) {
      visit(root);
    }
    final remaining =
        nodes.where((node) => !visited.contains(node.materialLineId)).toList()
          ..sort(compare);
    for (final node in remaining) {
      visit(node);
    }
    return result;
  }

  Widget _bomProductRoot(
    ThemeData theme,
    ProductionMaterialAnalysisProduct product,
  ) {
    final collapsed = _collapsedBomProducts.contains(product.analysisLineId);
    return Container(
      key: ValueKey('material-bom-product-${product.analysisLineId}'),
      constraints: const BoxConstraints(minHeight: 60),
      margin: const EdgeInsets.only(
        top: UtenSpacing.s12,
        bottom: UtenSpacing.s8,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s12,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            key: ValueKey(
              'material-bom-product-toggle-${product.analysisLineId}',
            ),
            tooltip: collapsed ? '展开该产品 BOM' : '折叠该产品 BOM',
            onPressed: () => setState(() {
              if (!_collapsedBomProducts.add(product.analysisLineId)) {
                _collapsedBomProducts.remove(product.analysisLineId);
              }
            }),
            icon: Icon(
              collapsed
                  ? Icons.chevron_right_rounded
                  : Icons.expand_more_rounded,
            ),
          ),
          Icon(
            product.sourceType == 'MAKE_COMPONENT'
                ? Icons.precision_manufacturing_outlined
                : Icons.inventory_2_outlined,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              product.goodsName ?? product.goodsCode ?? '未命名产品',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// BOM 节点卡（紧凑版式）。固定为「左状态栏 + 中内容区 + 右操作区」：
  ///
  /// - 左侧 44px 状态栏整卡等高：顶部路线状态图标，下面一条加粗的竖向
  ///   备料进度条（自底向上填充；悬停出 Tooltip、点按浮出数字进度，
  ///   点其它位置消失）；内容区再高也不侵入状态栏。
  /// - 中内容区两行：①标题行——路线角标 + 标题（独占一行不被挤压，过长
  ///   省略号）+ 右侧「层级 N · 编号 · 颜色」（层级按层着色）与「详情」；
  ///   ②数量行——需 / 配 / 现货 /「已备/需求（%）」（替代旧「缺 X」，
  ///   颜色与进度条同源）+ 权威状态，右端是选择框（门禁图标同位）。
  /// - 右操作区整卡等高：唯一主动作（采用建议/提交/继续提交…）撑满卡高，
  ///   与内容区以竖分隔线分开；无动作时整区不出现。
  /// - 层级用「整卡左缩进阶梯 + 状态栏竖线 + 层级 N 文字色」三处冗余
  ///   表达，替代旧版行内缩进 + 色带（旧版把内容挤得很乱）。
  Widget _unifiedBomNodeRow(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group, {
    required bool hasChildren,
  }) {
    final route = _routeDraft[group.key] ?? material.sourceSuggestion;
    final actionable = group.actionable;
    final selected =
        route != null &&
        (_selectedSupplyGroups[route]?.contains(group.key) ?? false);
    final status = _materialStatus(theme, group);
    final displayStatus = selected
        ? _StatusView(status.label, status.icon, Colors.white)
        : status;
    final shortage = material.shortageQty > 0;
    // 备货完成（本批需求被现货/合格入库全覆盖）的节点收成单行紧凑卡：
    // [路线][层级 N] 名称（编号） …… [已完成]，整卡浅绿成功态。
    // 点右侧「详情」图标仍可展开看路径与现货；已齐节点不参与勾选与下达。
    if (material.requiredQty > 0 && material.shortageQty <= 0) {
      return _stockedNodeCollapsedCard(
        theme,
        material,
        group,
        route,
        hasChildren: hasChildren,
      );
    }
    final warehouseStock = _selectedWarehouseStock(material);
    final exactPeggedQty = material.exactPeggedQty;
    final publicAvailableQty =
        warehouseStock?.publicAvailableQty ?? material.availableQty;
    final openSafetySupplyQty = warehouseStock?.openSafetySupplyQty ?? 0;
    final safetyReplenishmentGapQty =
        warehouseStock?.safetyReplenishmentGapQty ?? 0;
    final foreground = selected ? Colors.white : null;
    final onSurfaceVar = selected
        ? Colors.white70
        : theme.colorScheme.onSurfaceVariant;
    final coverage = _coverageOf(material);
    final coverageColor = coverage == null
        ? null
        : selected
        ? Colors.white
        : _coverageColor(theme, material, coverage.ratio);
    // 标题 = 物料名（编号）；规格/颜色收进右侧元信息。
    final title = material.goodsName ?? material.goodsCode ?? '未命名物料';
    final titleWithCode =
        material.goodsName != null && material.goodsCode != null
        ? '${material.goodsName}(${material.goodsCode})'
        : title;
    final branchCollapsed =
        material.nodeKey != null &&
        _collapsedBomBranches.contains(material.nodeKey);
    final action = _nodePrimaryAction(theme, group, route, selected: selected);
    // 路线操作移到右操作区：主动作在上、「更换路线」在下（已确认路线显深绿）。
    final routeButton = _nodeRouteButton(
      theme,
      group,
      route,
      selected: selected,
    );
    // 已下达供给任务的节点：状态文字可点，弹出全链路进度（下单/财务/收货/质检/入库）。
    final supplyNotified = _notifiedTargetOf(material) != null;
    Widget statusWidget = _statusLabel(theme, displayStatus);
    if (supplyNotified) {
      statusWidget = InkWell(
        key: ValueKey('material-supply-progress-${material.materialLineId}'),
        borderRadius: UtenRadius.smAll,
        onTap: _busy ? null : () => _showSupplyProgress(group),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: statusWidget),
              const SizedBox(width: 2),
              Icon(
                Icons.open_in_new_rounded,
                size: 14,
                color: displayStatus.color,
              ),
            ],
          ),
        ),
      );
    }
    final peeking =
        coverage != null && _progressPeekLineId == material.materialLineId;
    // 右侧元信息：规格 · 颜色（层级徽章已挪到标题行，编号并入标题）。
    // 宽屏在标题右侧，窄屏挪进数量行。
    final metaParts = [
      material.spec,
      material.colorName,
    ].whereType<String>().toList(growable: false);
    final metaText = metaParts.isEmpty
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  metaParts.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: onSurfaceVar,
                  ),
                ),
              ),
            ],
          );
    final coverageStat = coverage == null
        ? null
        : Text(
            '${_qty(coverage.covered)}'
            '/${_qty(material.requiredQty)}'
            '(${(coverage.ratio * 100).toStringAsFixed(0)}%)',
            maxLines: 1,
            style: TextStyle(color: coverageColor, fontWeight: FontWeight.w700),
          );
    final statWidgets = <Widget>[
      Text(
        '需 ${_qty(material.requiredQty)}',
        style: TextStyle(color: foreground),
      ),
      Text(
        '本批已保障 ${_qty(coverage?.covered ?? 0)}',
        key: ValueKey('material-batch-available-${material.materialLineId}'),
        style: TextStyle(
          color: selected ? Colors.white : theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
      if (exactPeggedQty > 0)
        Text(
          '本节点合格入库绑定 ${_qty(exactPeggedQty)}',
          key: ValueKey('material-exact-pegged-${material.materialLineId}'),
          style: TextStyle(
            color: selected ? Colors.white : theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
      Text(
        '公共可用 ${_qty(publicAvailableQty)}',
        key: ValueKey('material-public-available-${material.materialLineId}'),
        style: TextStyle(color: foreground),
      ),
      if (material.safetyStockQty > 0)
        Text(
          '安全保护 ${_qty(material.safetyStockQty)}',
          key: ValueKey(
            'material-safety-protection-${material.materialLineId}',
          ),
          style: TextStyle(
            color: selected ? Colors.white : theme.colorScheme.secondary,
            fontWeight: FontWeight.w700,
          ),
        ),
      if (warehouseStock != null)
        Text(
          '公共补库在途 ${_qty(openSafetySupplyQty)}',
          key: ValueKey('material-open-safety-${material.materialLineId}'),
          style: TextStyle(color: foreground),
        ),
      if (safetyReplenishmentGapQty > 0)
        Text(
          '公共补库待补 ${_qty(safetyReplenishmentGapQty)}',
          key: ValueKey('material-safety-gap-${material.materialLineId}'),
          style: TextStyle(
            color: selected ? Colors.white : theme.colorScheme.error,
            fontWeight: FontWeight.w700,
          ),
        ),
      ?coverageStat,
    ];
    final selectionControl = actionable
        ? SizedBox(
            width: 48,
            height: 48,
            child: _nodeSelectionControl(
              theme,
              material,
              group,
              route,
              selected,
            ),
          )
        : null;
    return Container(
      key: ValueKey(
        'material-bom-node-${material.nodeKey ?? material.materialLineId}',
      ),
      margin: EdgeInsets.only(
        top: UtenSpacing.s4,
        bottom: UtenSpacing.s4,
        // 层级阶梯：每层 16px、最多 5 层，整卡右移而不是挤压卡内内容。
        left: (material.level - 1).clamp(0, 5) * 16.0,
      ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: selected
            ? UtenColors.deepGreen
            : shortage
            ? theme.colorScheme.error.withValues(alpha: 0.1)
            : status.color.withValues(alpha: 0.05),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(
          color: selected
              ? UtenColors.deepGreen
              : shortage
              ? theme.colorScheme.error.withValues(alpha: 0.55)
              : theme.colorScheme.outlineVariant,
          width: selected || shortage ? 1.4 : 1,
        ),
      ),
      child: LayoutBuilder(
        builder: (_, cardConstraints) {
          // 窄卡（手机 + 深层阶梯缩进后）放不下整高操作区与标题行元信息：
          // 元信息挪进数量行、详情收成图标、选择框与动作并入数量行换行排布。
          final narrow = cardConstraints.maxWidth < 560;
          return Stack(
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _nodeStatusRail(
                      theme,
                      material,
                      group,
                      route,
                      selected: selected,
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s8,
                          UtenSpacing.s12,
                          UtenSpacing.s8,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                if (hasChildren && material.nodeKey != null)
                                  SizedBox(
                                    width: 40,
                                    height: 40,
                                    child: IconButton(
                                      key: ValueKey(
                                        'material-bom-branch-toggle-${material.nodeKey}',
                                      ),
                                      tooltip: branchCollapsed
                                          ? '展开下级物料'
                                          : '折叠下级物料',
                                      onPressed: () => setState(() {
                                        final key = material.nodeKey!;
                                        if (!_collapsedBomBranches.add(key)) {
                                          _collapsedBomBranches.remove(key);
                                        }
                                      }),
                                      icon: Icon(
                                        branchCollapsed
                                            ? Icons.chevron_right_rounded
                                            : Icons.expand_more_rounded,
                                        color: foreground ?? onSurfaceVar,
                                      ),
                                    ),
                                  )
                                else
                                  const SizedBox(width: UtenSpacing.s4),
                                _typeBadge(
                                  theme,
                                  route,
                                  onColor: selected ? Colors.white : null,
                                ),
                                const SizedBox(width: UtenSpacing.s4),
                                _levelBadge(
                                  theme,
                                  material.level,
                                  onColor: selected ? Colors.white : null,
                                ),
                                const SizedBox(width: UtenSpacing.s8),
                                Expanded(
                                  flex: 2,
                                  child: Text(
                                    titleWithCode,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      color: foreground,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                if (!narrow && metaText != null) ...[
                                  const SizedBox(width: UtenSpacing.s8),
                                  Flexible(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 240,
                                      ),
                                      child: metaText,
                                    ),
                                  ),
                                ],
                                _nodeDetailsToggle(
                                  theme,
                                  group,
                                  foreground: foreground,
                                  compact: narrow,
                                ),
                              ],
                            ),
                            const SizedBox(height: UtenSpacing.s4),
                            if (narrow)
                              Wrap(
                                spacing: UtenSpacing.s16,
                                runSpacing: UtenSpacing.s8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  ...statWidgets,
                                  ?metaText,
                                  statusWidget,
                                  ?selectionControl,
                                  ?action,
                                  ?routeButton,
                                ],
                              )
                            else
                              Row(
                                children: [
                                  Expanded(
                                    child: Wrap(
                                      spacing: UtenSpacing.s16,
                                      runSpacing: UtenSpacing.s4,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [...statWidgets, statusWidget],
                                    ),
                                  ),
                                  if (selectionControl != null) ...[
                                    const SizedBox(width: UtenSpacing.s4),
                                    selectionControl,
                                  ],
                                ],
                              ),
                            _borrowBadges(theme, material, selected: selected),
                            if (_expandedPathGroups.contains(group.key))
                              _nodeDetails(theme, group),
                          ],
                        ),
                      ),
                    ),
                    if ((action != null || routeButton != null) && !narrow)
                      Container(
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color: selected
                                  ? Colors.white24
                                  : theme.colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: UtenSpacing.s8,
                        ),
                        // 右操作区：主动作在上、「更换路线」在下，垂直居中；
                        // 不用 double.infinity/stretch（Row 内水平无界会断言失败），按钮按内容宽度右对齐。
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            ?action,
                            if (action != null && routeButton != null)
                              const SizedBox(height: UtenSpacing.s8),
                            ?routeButton,
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (peeking)
                Positioned(
                  left: 52,
                  top: UtenSpacing.s4,
                  child: IgnorePointer(
                    child: Container(
                      key: ValueKey(
                        'material-node-progress-peek-${material.materialLineId}',
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s8,
                        vertical: UtenSpacing.s4,
                      ),
                      decoration: BoxDecoration(
                        color: selected ? Colors.white : UtenColors.deepGreen,
                        borderRadius: UtenRadius.smAll,
                        boxShadow: UtenElevation.mid(
                          isDark: theme.brightness == Brightness.dark,
                        ),
                      ),
                      child: Text(
                        '备料 ${(coverage.ratio * 100).toStringAsFixed(0)}%'
                        ' · 已备 ${_qty(coverage.covered)}'
                        '/${_qty(material.requiredQty)}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: selected ? UtenColors.deepGreen : Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 备货完成节点的折叠卡：单行 [路线][层级 N] 名称（编号） …… [已完成]。
  /// 整卡浅绿成功态（主题绿浅底 + 绿描边），只保留第一行身份与「详情」入口；
  /// 数量行与操作区收起，但左侧保留 100% 满格深色轨道，老员工无需展开也能
  /// 一眼确认备料已经完成。
  Widget _stockedNodeCollapsedCard(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group,
    MaterialSupplyRoute? route, {
    required bool hasChildren,
  }) {
    final title = material.goodsName ?? material.goodsCode ?? '未命名物料';
    final titleWithCode =
        material.goodsName != null && material.goodsCode != null
        ? '${material.goodsName}(${material.goodsCode})'
        : title;
    final branchCollapsed =
        material.nodeKey != null &&
        _collapsedBomBranches.contains(material.nodeKey);
    final levelColor = _levelBandColor(theme, material.level);
    final exactPeggedQty = material.exactPeggedQty;
    return Container(
      key: ValueKey(
        'material-bom-node-${material.nodeKey ?? material.materialLineId}',
      ),
      margin: EdgeInsets.only(
        top: UtenSpacing.s4,
        bottom: UtenSpacing.s4,
        // 层级阶梯与展开卡一致（每层 16px、最多 5 层），折叠后层级位置不漂移。
        left: (material.level - 1).clamp(0, 5) * 16.0,
      ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
        ),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              label: '备料进度100%，已完成',
              child: Container(
                width: 44,
                decoration: BoxDecoration(
                  color: levelColor.withValues(alpha: 0.24),
                  border: Border(
                    right: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 17,
                    vertical: UtenSpacing.s8,
                  ),
                  child: DecoratedBox(
                    key: ValueKey(
                      'material-node-rail-fill-${material.materialLineId}',
                    ),
                    decoration: _verticalRailProgressDecoration(
                      background: theme.colorScheme.primary.withValues(
                        alpha: 0.22,
                      ),
                      fill: theme.colorScheme.primary,
                      ratio: 1,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s12,
                  UtenSpacing.s4,
                  UtenSpacing.s12,
                  UtenSpacing.s4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        if (hasChildren && material.nodeKey != null)
                          SizedBox(
                            width: 40,
                            height: 40,
                            child: IconButton(
                              key: ValueKey(
                                'material-bom-branch-toggle-${material.nodeKey}',
                              ),
                              tooltip: branchCollapsed ? '展开下级物料' : '折叠下级物料',
                              onPressed: () => setState(() {
                                final key = material.nodeKey!;
                                if (!_collapsedBomBranches.add(key)) {
                                  _collapsedBomBranches.remove(key);
                                }
                              }),
                              icon: Icon(
                                branchCollapsed
                                    ? Icons.chevron_right_rounded
                                    : Icons.expand_more_rounded,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        else
                          const SizedBox(width: UtenSpacing.s4),
                        _typeBadge(theme, route),
                        const SizedBox(width: UtenSpacing.s4),
                        _levelBadge(theme, material.level),
                        const SizedBox(width: UtenSpacing.s8),
                        Expanded(
                          child: Text(
                            titleWithCode,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        _nodeDetailsToggle(theme, group, compact: true),
                        const SizedBox(width: UtenSpacing.s4),
                        _stockedDoneBadge(theme),
                      ],
                    ),
                    if (exactPeggedQty > 0)
                      Padding(
                        padding: const EdgeInsets.only(
                          left: UtenSpacing.s4,
                          bottom: UtenSpacing.s4,
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _miniBadge(
                            theme,
                            label: '本节点合格入库绑定 ${_qty(exactPeggedQty)}',
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    if (_expandedPathGroups.contains(group.key))
                      _nodeDetails(theme, group),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 折叠卡右侧的「已完成」徽章：深绿实底白字（只读，示意备货已齐）。
  Widget _stockedDoneBadge(ThemeData theme) {
    return Semantics(
      label: '备货已完成',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s8,
          vertical: UtenSpacing.s4,
        ),
        decoration: const BoxDecoration(
          color: UtenColors.deepGreen,
          borderRadius: UtenRadius.pillAll,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.check_circle_rounded,
              size: 16,
              color: Colors.white,
            ),
            const SizedBox(width: UtenSpacing.s4),
            Text(
              '已完成',
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 节点「更换路线」按钮（右操作区下位）。已确认路线显深绿实底并带当前
  /// 路线名（点按仍可更换）；无建议路线时作主入口「选择路线」；其余为描边
  /// 「更换路线」。点击弹出路线选择面板，选中立即保存（偏离建议须填原因），
  /// 保存成功后按钮即变深绿。已下达任务/无需补货/已齐套的节点不再改路线。
  Widget? _nodeRouteButton(
    ThemeData theme,
    _MaterialGroup group,
    MaterialSupplyRoute? route, {
    required bool selected,
  }) {
    final material = group.representative;
    if (!group.actionable || !_canRoute) return null;
    if (_notifiedTargetOf(material) != null) return null;
    if (material.requiredQty <= 0 || material.shortageQty <= 0) return null;
    final confirmed = material.confirmedRoute;
    if (confirmed != null && !_dirtyRouteGroups.contains(group.key)) {
      return FilledButton.icon(
        key: ValueKey('material-route-change-${material.materialLineId}'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 40),
          backgroundColor: selected ? Colors.white : UtenColors.deepGreen,
          foregroundColor: selected ? UtenColors.deepGreen : Colors.white,
        ),
        onPressed: _busy ? null : () => _pickRoute(group),
        icon: const Icon(Icons.alt_route_rounded, size: 18),
        label: Text('路线 · ${confirmed.label}'),
      );
    }
    if (confirmed == null && material.sourceSuggestion == null) {
      return OutlinedButton.icon(
        key: ValueKey('material-route-pick-${material.materialLineId}'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 40),
          foregroundColor: selected ? Colors.white : null,
        ),
        onPressed: _busy ? null : () => _pickRoute(group),
        icon: const Icon(Icons.alt_route_rounded, size: 18),
        label: const Text('选择路线'),
      );
    }
    return OutlinedButton.icon(
      key: ValueKey('material-route-change-${material.materialLineId}'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 40),
        foregroundColor: selected ? Colors.white : null,
      ),
      onPressed: _busy ? null : () => _pickRoute(group),
      icon: const Icon(Icons.alt_route_rounded, size: 18),
      label: const Text('更换路线'),
    );
  }

  /// 路线选择面板：列出采购/委外/自制三条路线，标注服务端建议与当前已确认
  /// 路线。选中与建议一致的路线直接保存；偏离建议先填覆盖原因再保存。
  Future<void> _pickRoute(_MaterialGroup group) async {
    if (_busy || !_canRoute || !group.actionable) return;
    final material = group.representative;
    final suggestion = material.sourceSuggestion;
    final confirmed = material.confirmedRoute;
    final chosen = await showModalBottomSheet<MaterialSupplyRoute>(
      context: context,
      builder: (sheetContext) {
        final sheetTheme = Theme.of(sheetContext);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s16,
                  UtenSpacing.s16,
                  UtenSpacing.s16,
                  UtenSpacing.s8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '选择供料路线',
                      style: sheetTheme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      material.goodsName ?? material.goodsCode ?? '当前物料',
                      style: sheetTheme.textTheme.bodySmall?.copyWith(
                        color: sheetTheme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              for (final option in MaterialSupplyRoute.values)
                ListTile(
                  leading: Icon(switch (option) {
                    MaterialSupplyRoute.buy => Icons.shopping_cart_outlined,
                    MaterialSupplyRoute.subcontract =>
                      Icons.precision_manufacturing_outlined,
                    MaterialSupplyRoute.make => Icons.factory_outlined,
                  }),
                  title: Text(option.label),
                  trailing: Wrap(
                    spacing: UtenSpacing.s8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (option == suggestion)
                        _miniBadge(
                          sheetTheme,
                          label: '建议',
                          color: sheetTheme.colorScheme.tertiary,
                        ),
                      if (option == confirmed)
                        Icon(
                          Icons.check_circle_rounded,
                          size: 18,
                          color: sheetTheme.colorScheme.primary,
                        ),
                    ],
                  ),
                  onTap: () => Navigator.of(sheetContext).pop(option),
                ),
              const SizedBox(height: UtenSpacing.s8),
            ],
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;
    if (chosen == confirmed && !_dirtyRouteGroups.contains(group.key)) {
      context.appInfo('路线未变化，当前已是${chosen.label}');
      return;
    }
    String? reason;
    if (suggestion == null || suggestion != chosen) {
      // 偏离服务端建议（或无建议）时必须填写覆盖原因（服务端契约）。
      reason = await _promptRouteReason(group, chosen);
      if (reason == null || !mounted) return;
    }
    await _persistRouteChoice(group, chosen, reason);
  }

  /// 立即保存单条路线选择（与「采用建议」同一接口与幂等键口径），成功后
  /// 整树刷新为最新分析视图，「更换路线」按钮随即显示深绿已确认态。
  Future<void> _persistRouteChoice(
    _MaterialGroup group,
    MaterialSupplyRoute route,
    String? reason,
  ) async {
    final analysis = _analysis;
    if (analysis == null || !_canRoute || !group.actionable || _busy) return;
    final actionGroupKey = group.representative.actionGroupKey;
    final decision = actionGroupKey == null
        ? MaterialRouteDecision(
            materialLineId: group.representative.materialLineId,
            route: route,
            reason: reason,
          )
        : MaterialRouteDecision(
            actionGroupKey: actionGroupKey,
            route: route,
            reason: reason,
          );
    final key = businessIdempotencyKey(
      'material-analysis-route-node',
      '${analysis.analysisId}|${analysis.version}|${analysis.fingerprint}|'
          '${actionGroupKey ?? group.representative.materialLineId}|'
          '${route.wireName}|${reason ?? ''}',
    );
    final preservedSelections = _supplySelectionSnapshot();
    setState(() => _savingRoutes = true);
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .updateMaterialAnalysisRoutes(
            analysis: analysis,
            idempotencyKey: key,
            decisions: [decision],
          );
      if (!mounted) return;
      setState(() {
        _savingRoutes = false;
        _applyAnalysis(view);
        _restoreValidSupplySelections(preservedSelections);
      });
      context.appSuccess('已确认${route.label}路线');
    } catch (error) {
      if (!mounted) return;
      setState(() => _savingRoutes = false);
      context.appError(
        productionErrorMessage(error, fallback: '路线确认失败，请刷新后重试'),
        force: true,
      );
    }
  }

  /// 已下达供给任务的节点状态可点：弹出该物料的供给全链路进度
  /// （提交需求 → 下单 → 财务批准 → 仓库收货 → 品质验收 → 入库）。
  Future<void> _showSupplyProgress(_MaterialGroup group) async {
    final analysis = _analysis;
    if (analysis == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _SupplyProgressDialog(
        analysisId: analysis.analysisId,
        material: group.representative,
      ),
    );
  }

  /// 层级色板：相邻层级色相明显拉开（青/蓝/橙/紫/品红/橄榄），白底与浅红
  /// 缺料底上都清晰可读。整卡阶梯缩进、状态栏竖线、「层级 N」徽章共用
  /// 同一色板，三处冗余表达层级。注意不要再退回主题
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

  // ===== 现货层借用（调货） =====
  //
  // 同一分析内把某条直接组件路径已分配的现货覆盖量调给另一产品的同物料
  // 路径。只改分析软分配与齐套投影；服务端逐笔留痕（谁、多少、从哪到哪、
  // 原因、时间），借出/借入双方行上都可见，正式下达前可撤销。

  /// 借用双向徽标：借出方显示"已被调走 · 调给 X"，借入方显示"已调入 ·
  /// 来自 Y"。生效数为 0 时显示"暂未生效"，避免把申请量当成已调量。
  Widget _borrowBadges(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material, {
    required bool selected,
  }) {
    if (material.borrowRefs.isEmpty && material.crossReallocationRefs.isEmpty) {
      return const SizedBox.shrink();
    }
    final chips = <Widget>[];
    for (final ref in material.borrowRefs) {
      final inbound = ref.isInbound;
      final effective = ref.qty > 0;
      final color = selected
          ? theme.colorScheme.onPrimary
          : !effective
          ? theme.colorScheme.onSurfaceVariant
          : inbound
          ? theme.colorScheme.primary
          : theme.colorScheme.tertiary;
      final label = !effective
          ? '调拨申请 ${_qty(ref.requestedQty)} 件暂未生效'
          : inbound
          ? '已调入 ${_qty(ref.qty)} 件 · 来自 ${ref.counterpartProduct ?? '其它产品'}'
          : '已被调走 ${_qty(ref.qty)} 件 · 调给 ${ref.counterpartProduct ?? '其它产品'}';
      chips.add(
        Semantics(
          label: label,
          child: Container(
            key: ValueKey(
              'material-borrow-ref-${ref.direction}-${material.materialLineId}-${ref.borrowId}',
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s8,
              vertical: UtenSpacing.s4,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: effective ? 0.12 : 0.07),
              borderRadius: UtenRadius.smAll,
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  inbound
                      ? Icons.call_received_rounded
                      : Icons.call_made_rounded,
                  size: 16,
                  color: color,
                ),
                const SizedBox(width: UtenSpacing.s4),
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    for (final allocation in material.crossReallocationRefs) {
      final inbound = allocation.isInbound;
      final label = _crossReallocationChipLabel(allocation);
      final color = selected
          ? theme.colorScheme.onPrimary
          : inbound
          ? theme.colorScheme.primary
          : theme.colorScheme.tertiary;
      chips.add(
        Semantics(
          label: label,
          child: Container(
            key: ValueKey(
              'material-cross-reallocation-ref-${allocation.direction}-'
              '${material.materialLineId}-${allocation.id}',
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s8,
              vertical: UtenSpacing.s4,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: UtenRadius.smAll,
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  inbound
                      ? Icons.move_to_inbox_outlined
                      : Icons.outbox_outlined,
                  size: 16,
                  color: color,
                ),
                const SizedBox(width: UtenSpacing.s4),
                Flexible(
                  child: Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s4),
      child: Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s4,
        children: chips,
      ),
    );
  }

  /// 客户端预检（服务端仍逐项硬校验）：直接组件层、有已分配现货、
  /// 无在途任务、非发货参考，且有重新分配权限。
  bool _canBorrowOut(ProductionMaterialAnalysisMaterial material) {
    if (!_canReallocate || _busy) return false;
    if (material.level != 1) return false;
    if (material.requiredQty <= 0 || material.allocatedAvailableQty <= 0) {
      return false;
    }
    if (_notifiedTargetOf(material) != null) return false;
    final stage = material.controlStage?.trim().toUpperCase();
    return stage != 'SHIP' && stage != 'REFERENCE';
  }

  /// 跨计划让料复用同一物料维度预检，但不受分析内借用的“已下达”门禁限制：
  /// 服务端会以两份分析的当前快照和精确 entitlement 再次校验。
  bool _canCrossReallocateOut(ProductionMaterialAnalysisMaterial material) {
    if (!_canCrossReallocate || _busy) return false;
    if (material.level != 1) return false;
    if (material.requiredQty <= 0 || material.allocatedAvailableQty <= 0) {
      return false;
    }
    final stage = material.controlStage?.trim().toUpperCase();
    return stage != 'SHIP' && stage != 'REFERENCE';
  }

  /// 可调入路径：同一物料（货品+颜色+单位）、其它产品、直接组件层、
  /// 仍有缺口、无在途任务。客户端只列候选，数量与合法性由服务端复核。
  List<ProductionMaterialAnalysisMaterial> _borrowCandidates(
    ProductionMaterialAnalysisMaterial from,
  ) {
    final analysis = _analysis;
    if (analysis == null) return const [];
    return analysis.materials
        .where(
          (candidate) =>
              candidate.materialLineId != from.materialLineId &&
              candidate.analysisLineId != from.analysisLineId &&
              candidate.level == 1 &&
              candidate.goodsId == from.goodsId &&
              candidate.colorId == from.colorId &&
              candidate.unitId == from.unitId &&
              candidate.shortageQty > 0 &&
              _notifiedTargetOf(candidate) == null,
        )
        .toList(growable: false);
  }

  Future<void> _showBorrowDialog(
    ProductionMaterialAnalysisMaterial material,
  ) async {
    final analysis = _analysis;
    if (analysis == null || !_canBorrowOut(material)) return;
    final candidates = _borrowCandidates(material);
    if (candidates.isEmpty) {
      context.appInfo('当前分析内没有其它产品缺这种料；可使用“跨计划让料”查找其它分析');
      return;
    }
    final indexes = _analysisIndexes(analysis);
    final request = await showDialog<_BorrowRequestDraft>(
      context: context,
      builder: (_) => _BorrowDialog(
        from: material,
        candidates: candidates,
        productsById: indexes.productsById,
        pathLabelOf: _pathLabel,
        qtyText: _qty,
      ),
    );
    if (request == null || !mounted) return;
    await _submitBorrow(material, request);
  }

  Future<void> _showCrossReallocationDialog(
    ProductionMaterialAnalysisMaterial material,
  ) async {
    final analysis = _analysis;
    if (analysis == null || !_canCrossReallocateOut(material)) return;
    final indexes = _analysisIndexes(analysis);
    final product = indexes.productsById[material.analysisLineId];
    final productLabel = product?.goodsName?.trim().isNotEmpty == true
        ? product!.goodsName!.trim()
        : product?.goodsCode?.trim().isNotEmpty == true
        ? product!.goodsCode!.trim()
        : product?.sourceRef?.trim().isNotEmpty == true
        ? product!.sourceRef!.trim()
        : '当前计划产品';
    setState(() => _borrowing = true);
    try {
      final view = await showMaterialReallocationDialog(
        context: context,
        repository: ref.read(productionPlanRepositoryProvider),
        sourceAnalysis: analysis,
        sourceMaterial: material,
        sourceProductLabel: productLabel,
        sourcePathLabel: _pathLabel(material),
        qtyText: _qty,
        onSourceRebased: (latest) {
          if (!mounted) return;
          setState(() => _applyAnalysis(latest));
        },
      );
      if (!mounted) return;
      setState(() {
        _borrowing = false;
        if (view != null) _applyAnalysis(view);
      });
      if (view != null) {
        context.appSuccess('跨计划让料已生效；本计划已标记优先待补，接受计划无需返还');
      }
    } finally {
      if (mounted && _borrowing) setState(() => _borrowing = false);
    }
  }

  Future<void> _submitBorrow(
    ProductionMaterialAnalysisMaterial from,
    _BorrowRequestDraft request,
  ) async {
    final analysis = _analysis;
    if (analysis == null || _borrowing) return;
    final key = businessIdempotencyKey(
      'material-analysis-borrow',
      [
        analysis.analysisId,
        analysis.version,
        analysis.fingerprint,
        from.materialLineId,
        request.toMaterialLineId,
        request.qty.toString(),
        request.reason,
      ].join('|'),
    );
    setState(() => _borrowing = true);
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .createMaterialAnalysisBorrow(
            analysis: analysis,
            idempotencyKey: key,
            fromMaterialLineId: from.materialLineId,
            toMaterialLineId: request.toMaterialLineId,
            qty: request.qty,
            reason: request.reason,
          );
      if (!mounted) return;
      setState(() {
        _borrowing = false;
        _applyAnalysis(view);
      });
      context.appSuccess('已调拨 ${_qty(request.qty)} 件，齐套结果已由服务端重新计算');
    } catch (error) {
      if (!mounted) return;
      setState(() => _borrowing = false);
      context.appError(
        productionErrorMessage(error, fallback: '调拨失败，请刷新后重试'),
        force: true,
      );
    }
  }

  Future<void> _revokeBorrow(MaterialBorrowRef borrowRef) async {
    final analysis = _analysis;
    if (analysis == null || !_canReallocate || _busy) return;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _RequiredReasonDialog(
        title: '撤销这笔借用',
        fieldKey: Key('borrow-revoke-reason'),
        initialValue: '',
        helperMessage: '撤销后借出方恢复分配、借入方重新出现缺口。请填写撤销原因。',
        confirmLabel: '确认撤销',
      ),
    );
    if (reason == null || !mounted) return;
    final key = businessIdempotencyKey(
      'material-analysis-borrow-revoke',
      [
        analysis.analysisId,
        analysis.version,
        analysis.fingerprint,
        borrowRef.borrowId,
        reason,
      ].join('|'),
    );
    setState(() => _borrowing = true);
    try {
      final view = await ref
          .read(productionPlanRepositoryProvider)
          .revokeMaterialAnalysisBorrow(
            analysis: analysis,
            borrowId: borrowRef.borrowId,
            idempotencyKey: key,
            reason: reason,
          );
      if (!mounted) return;
      setState(() {
        _borrowing = false;
        _applyAnalysis(view);
      });
      context.appSuccess('借用已撤销，齐套结果已由服务端重新计算');
    } catch (error) {
      if (!mounted) return;
      setState(() => _borrowing = false);
      context.appError(
        productionErrorMessage(error, fallback: '撤销借用失败，请刷新后重试'),
        force: true,
      );
    }
  }

  Future<void> _revokeCrossReallocation(
    MaterialCrossReallocationRef allocation,
  ) async {
    final analysis = _analysis;
    if (analysis == null || !_canCrossReallocate || _busy) return;
    final counterpartVersion = allocation.counterpartVersion;
    final counterpartFingerprint = allocation.counterpartFingerprint;
    if (counterpartVersion == null ||
        counterpartVersion <= 0 ||
        counterpartFingerprint?.isNotEmpty != true) {
      context.appInfo('缺少接受计划的最新版本信息，请刷新物料分析后重试');
      return;
    }
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _RequiredReasonDialog(
        title: '撤销跨计划让料',
        fieldKey: Key('cross-reallocation-revoke-reason'),
        initialValue: '',
        helperMessage: '撤销会重新计算两份计划的物料覆盖。请填写业务原因。',
        confirmLabel: '确认撤销',
      ),
    );
    if (reason == null || !mounted) return;

    final currentIsSource = allocation.isOutbound;
    final sourceAnalysisId = currentIsSource
        ? analysis.analysisId
        : allocation.counterpartAnalysisId;
    final sourceVersion = currentIsSource
        ? analysis.version
        : counterpartVersion;
    final sourceFingerprint = currentIsSource
        ? analysis.fingerprint
        : counterpartFingerprint!;
    final targetAnalysisId = currentIsSource
        ? allocation.counterpartAnalysisId
        : analysis.analysisId;
    final targetVersion = currentIsSource
        ? counterpartVersion
        : analysis.version;
    final targetFingerprint = currentIsSource
        ? counterpartFingerprint!
        : analysis.fingerprint;
    final key = businessIdempotencyKey(
      'material-analysis-cross-reallocation-revoke',
      [
        sourceAnalysisId,
        sourceVersion,
        sourceFingerprint,
        targetAnalysisId,
        targetVersion,
        targetFingerprint,
        allocation.id,
        reason,
      ].join('|'),
    );

    setState(() => _borrowing = true);
    try {
      final sourceView = await ref
          .read(productionPlanRepositoryProvider)
          .revokeMaterialCrossReallocation(
            sourceAnalysisId: sourceAnalysisId,
            sourceVersion: sourceVersion,
            sourceFingerprint: sourceFingerprint,
            targetAnalysisId: targetAnalysisId,
            targetVersion: targetVersion,
            targetFingerprint: targetFingerprint,
            crossReallocationId: allocation.id,
            reason: reason,
            idempotencyKey: key,
          );
      if (!mounted) return;
      final currentView = currentIsSource
          ? sourceView
          : await ref
                .read(productionPlanRepositoryProvider)
                .materialAnalysisDetail(analysis.analysisId);
      if (!mounted) return;
      setState(() {
        _borrowing = false;
        _applyAnalysis(currentView);
      });
      context.appSuccess('跨计划让料已撤销，两份计划的物料覆盖已重新计算');
    } catch (error) {
      if (!mounted) return;
      setState(() => _borrowing = false);
      context.appError(
        productionErrorMessage(error, fallback: '撤销跨计划让料失败，请刷新后重试'),
        force: true,
      );
    }
  }

  String _crossReallocationCounterpart(
    MaterialCrossReallocationRef allocation,
  ) {
    final label = allocation.counterpartLabel?.trim();
    if (label?.isNotEmpty == true) return label!;
    final product = allocation.counterpartProduct?.trim();
    return product?.isNotEmpty == true ? product! : '其它计划';
  }

  String _crossReallocationChipLabel(MaterialCrossReallocationRef allocation) {
    final counterpart = _crossReallocationCounterpart(allocation);
    if (allocation.isReversed) {
      return '跨计划让料已撤销 · 权益已恢复 · $counterpart';
    }
    if (allocation.isCancelled) {
      if (allocation.currentEffectiveQty > 0) {
        return allocation.isInbound
            ? '关系已关闭 · 当前仍保留 ${_qty(allocation.currentEffectiveQty)} 件 · 来自 $counterpart'
            : '关系已关闭 · 对方仍保留 ${_qty(allocation.currentEffectiveQty)} 件 · 给 $counterpart';
      }
      return '关系已关闭 · 当前权益已释放 · $counterpart';
    }
    if (allocation.isInbound) {
      return '已接受 ${_qty(allocation.qty)} 件 · 来自 $counterpart · 无需返还';
    }
    if (allocation.priorityOpenQty > 0) {
      return '已让料 ${_qty(allocation.qty)} 件 · 给 $counterpart · '
          '优先待补 ${_qty(allocation.priorityOpenQty)} 件';
    }
    if (allocation.priorityFulfilledQty > 0) {
      return '已让料 ${_qty(allocation.qty)} 件 · 给 $counterpart · '
          '已优先补齐 ${_qty(allocation.priorityFulfilledQty)} 件';
    }
    return '已让料 ${_qty(allocation.qty)} 件 · 给 $counterpart';
  }

  String _crossReallocationHeadline(MaterialCrossReallocationRef allocation) {
    final counterpart = _crossReallocationCounterpart(allocation);
    if (allocation.isReversed) return '跨计划让料已撤销 · 权益已恢复';
    if (allocation.isCancelled) {
      if (allocation.currentEffectiveQty <= 0) {
        return '让料关系已关闭 · 当前权益已释放';
      }
      return allocation.isInbound
          ? '让料关系已关闭 · 当前保留 ${_qty(allocation.currentEffectiveQty)} 件 · 来自 $counterpart'
          : '让料关系已关闭 · $counterpart 仍保留 ${_qty(allocation.currentEffectiveQty)} 件';
    }
    return allocation.isInbound
        ? '已接受 ${_qty(allocation.qty)} 件 · 来自 $counterpart'
        : '已让料 ${_qty(allocation.qty)} 件 · 接受计划 $counterpart';
  }

  String _crossReallocationExplanation(
    MaterialCrossReallocationRef allocation,
  ) {
    if (allocation.isReversed) {
      return '本次让料已撤销；双方当前权益已按事件恢复。';
    }
    if (allocation.isCancelled) {
      if (allocation.currentEffectiveQty <= 0) {
        return '当前受益切片已释放；记录仅保留用于审计。';
      }
      return allocation.isInbound
          ? '来源分析已取消；仍有效的受益切片继续保留给本计划。'
          : '关系已关闭；仍有效的受益切片继续保留给接受计划。';
    }
    if (allocation.isInbound) {
      return '接受计划无需返还；来源计划保留原始需求。';
    }
    if (allocation.priorityOpenQty > 0) {
      return '优先待补 ${_qty(allocation.priorityOpenQty)} 件'
          '${allocation.priorityFulfilledQty > 0 ? ' · 已优先补齐 ${_qty(allocation.priorityFulfilledQty)} 件' : ''}';
    }
    if (allocation.priorityFulfilledQty > 0) {
      return '已优先补齐 ${_qty(allocation.priorityFulfilledQty)} 件';
    }
    return '后续本计划来源的合格入库会优先补本计划。';
  }

  /// 节点详情内的借用区：逐笔借用明细（可撤销）+ 调出入口。
  Widget _nodeBorrowSection(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
  ) {
    final refs = material.borrowRefs;
    final crossRefs = material.crossReallocationRefs;
    final canBorrowOut = _canBorrowOut(material);
    final canCrossReallocateOut = _canCrossReallocateOut(material);
    if (refs.isEmpty &&
        crossRefs.isEmpty &&
        !canBorrowOut &&
        !canCrossReallocateOut) {
      return const SizedBox.shrink();
    }
    return Container(
      key: ValueKey('material-borrow-section-${material.materialLineId}'),
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.3),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final ref in refs)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      ref.isInbound
                          ? '借入 ${_qty(ref.qty)} 件 · 来自 ${ref.counterpartProduct ?? '其它产品'}'
                                '${ref.reason?.isNotEmpty == true ? ' · 原因：${ref.reason}' : ''}'
                          : '借出 ${_qty(ref.qty)} 件 · 调给 ${ref.counterpartProduct ?? '其它产品'}'
                                '${ref.reason?.isNotEmpty == true ? ' · 原因：${ref.reason}' : ''}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  if (_canReallocate)
                    UtenButton(
                      key: ValueKey('material-borrow-revoke-${ref.borrowId}'),
                      size: UtenButtonSize.large,
                      type: UtenButtonType.ghost,
                      icon: Icons.undo_rounded,
                      onPressed: _busy ? null : () => _revokeBorrow(ref),
                      child: const Text('撤销'),
                    ),
                ],
              ),
            ),
          for (final allocation in crossRefs)
            Container(
              key: ValueKey(
                'material-cross-reallocation-detail-${allocation.id}',
              ),
              margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
              padding: const EdgeInsets.all(UtenSpacing.s8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: UtenRadius.smAll,
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _crossReallocationHeadline(allocation),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    _crossReallocationExplanation(allocation),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (allocation.reason?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Text('业务原因：${allocation.reason}'),
                  ],
                  if (allocation.isOutbound &&
                      allocation.replenishmentRefs.isNotEmpty) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      '补齐来源',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    for (final replenishment in allocation.replenishmentRefs)
                      Text('• ${replenishment.displayLabel}'),
                  ],
                  const SizedBox(height: UtenSpacing.s8),
                  if (_canCrossReallocate && allocation.canRevoke)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: UtenButton(
                        key: ValueKey(
                          'material-cross-reallocation-revoke-${allocation.id}',
                        ),
                        size: UtenButtonSize.large,
                        type: UtenButtonType.ghost,
                        icon: Icons.undo_rounded,
                        onPressed: _busy
                            ? null
                            : () => _revokeCrossReallocation(allocation),
                        child: const Text('撤销跨计划让料'),
                      ),
                    )
                  else if (!allocation.canRevoke)
                    Semantics(
                      label:
                          '当前不可撤销：'
                          '${allocation.revokeBlockedReason ?? '当前业务阶段已锁定'}',
                      child: Text(
                        '不可撤销：'
                        '${allocation.revokeBlockedReason ?? '当前业务阶段已锁定'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    Text(
                      '当前账号无撤销权限',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          if (canBorrowOut || canCrossReallocateOut)
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                if (canBorrowOut)
                  UtenButton(
                    key: ValueKey(
                      'material-borrow-start-${material.materialLineId}',
                    ),
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.swap_horiz_rounded,
                    onPressed: _busy ? null : () => _showBorrowDialog(material),
                    child: const Text('分析内调给产品'),
                  ),
                if (canCrossReallocateOut)
                  UtenButton(
                    key: ValueKey(
                      'material-cross-reallocation-start-${material.materialLineId}',
                    ),
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.compare_arrows_rounded,
                    onPressed: _busy
                        ? null
                        : () => _showCrossReallocationDialog(material),
                    child: const Text('跨计划让料'),
                  ),
              ],
            ),
        ],
      ),
    );
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
      return '下一步：勾选要处理的红色缺料，再用底部按钮提交采购、委外或安排自制生产。';
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

  /// MAKE 路线已确认但直接子层级尚未齐套时，服务端按 ADR-057 不会提前
  /// 创建真实 MAKE_COMPONENT。这里把同一服务端快照投影成只读待办卡，
  /// 让任务持续可见；它不进入产品选择、计划预览、预留或库存事实。
  List<_PendingMakeCandidate> _pendingMakeCandidates(
    ProductionMaterialAnalysisView analysis,
  ) {
    final indexes = _analysisIndexes(analysis);
    final result = <_PendingMakeCandidate>[];
    for (final material in analysis.materials) {
      if (material.confirmedRoute != MaterialSupplyRoute.make ||
          material.shortageQty <= 0) {
        continue;
      }
      final hasActiveMakeTask = material.notifiedTargets.any(
        (target) =>
            target.target == MaterialSupplyRoute.make &&
            target.status?.toUpperCase() != 'CANCELLED',
      );
      if (hasActiveMakeTask || _makeChildProductOf(material) != null) continue;

      final nodeKey = material.nodeKey;
      final directShortages = nodeKey == null
          ? const <ProductionMaterialAnalysisMaterial>[]
          : analysis.materials
                .where(
                  (child) =>
                      child.analysisLineId == material.analysisLineId &&
                      child.parentNodeKey == nodeKey &&
                      child.hardGate != false &&
                      !_isNonProductionStage(child.controlStage) &&
                      child.shortageQty > 0,
                )
                .toList(growable: false);
      final kindCount = directShortages
          .map(_materialKindIdentity)
          .toSet()
          .length;
      final unconfirmedCount = directShortages
          .where((child) => child.confirmedRoute == null)
          .length;
      final path = material.path
          .where((segment) => !_looksLikeUuid(segment))
          .toList(growable: false);
      final parentProduct = material.analysisLineId == null
          ? null
          : indexes.productsById[material.analysisLineId];
      final parentLabel =
          material.parentLabel ??
          (path.length > 1 ? path[path.length - 2] : null) ??
          parentProduct?.goodsName ??
          parentProduct?.goodsCode;
      result.add(
        _PendingMakeCandidate(
          material: material,
          group: indexes.groupsByLine[material.materialLineId],
          parentLabel: parentLabel,
          shortageKindCount: kindCount,
          shortagePathCount: directShortages.length,
          unconfirmedPathCount: unconfirmedCount,
        ),
      );
    }
    result.sort((left, right) {
      final readiness = (left.material.lowerLevelPending ? 1 : 0).compareTo(
        right.material.lowerLevelPending ? 1 : 0,
      );
      if (readiness != 0) return readiness;
      return left.material.materialLineId.compareTo(
        right.material.materialLineId,
      );
    });
    return result;
  }

  bool _isNonProductionStage(String? stage) {
    final normalized = stage?.trim().toUpperCase();
    return normalized == 'SHIP' || normalized == 'REFERENCE';
  }

  String _materialKindIdentity(ProductionMaterialAnalysisMaterial material) {
    final key = material.materialKey?.trim();
    if (key?.isNotEmpty == true) return key!;
    final dimension = [
      material.goodsId,
      material.colorId,
      material.unitId,
    ].whereType<String>().join('|');
    return dimension.isEmpty ? material.materialLineId : dimension;
  }

  bool _canArrangePendingMakeCandidate(_PendingMakeCandidate candidate) {
    final group = candidate.group;
    return !candidate.material.lowerLevelPending &&
        group != null &&
        _isExecutableSupplyGroup(group, MaterialSupplyRoute.make);
  }

  Widget _productSection(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
    final pendingMakeCandidates = _pendingMakeCandidates(analysis);
    final visiblePendingMake = pendingMakeCandidates
        .take(_pendingMakeVisibleLimit)
        .toList(growable: false);
    final remainingPendingMake =
        pendingMakeCandidates.length - visiblePendingMake.length;
    final pendingMakeAllBlocked =
        pendingMakeCandidates.isNotEmpty &&
        pendingMakeCandidates.every(
          (candidate) => !_canArrangePendingMakeCandidate(candidate),
        );
    final pendingMakeSectionAccent = pendingMakeAllBlocked
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final pendingMakeSectionForeground = pendingMakeAllBlocked
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSurface;
    final byId = {
      for (final product in analysis.products) product.analysisLineId: product,
    };
    final ordered = [
      for (final id in _priorityDraft)
        if (byId[id] != null) byId[id]!,
    ];
    for (final product in analysis.products) {
      if (!ordered.contains(product)) ordered.add(product);
    }
    // Bottom-up visibility: surface plan-ready products (readyNowQty > 0)
    // first so the planner sees what can be built now. List.sort 不承诺稳定性，
    // 因此显式用排产优先序作第二排序键，避免刷新后同层产品乱跳。
    final originalOrder = {
      for (var index = 0; index < ordered.length; index++)
        ordered[index].analysisLineId: index,
    };
    ordered.sort((a, b) {
      final ar = a.readyNowQty > 0 ? 0 : 1;
      final br = b.readyNowQty > 0 ? 0 : 1;
      final readiness = ar.compareTo(br);
      if (readiness != 0) return readiness;
      return originalOrder[a.analysisLineId]!.compareTo(
        originalOrder[b.analysisLineId]!,
      );
    });
    final readyCount = ordered
        .where((product) => product.readyNowQty > 0)
        .length;
    final visibleProducts = ordered
        .take(_productVisibleLimit)
        .toList(growable: false);
    final remainingProducts = ordered.length - visibleProducts.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: Checkbox(
                key: const Key('material-analysis-product-select-all'),
                tristate: true,
                value: _productHeaderValue,
                onChanged: _busy || _selectableProducts.isEmpty
                    ? null
                    : (value) => _toggleAllProducts(value == true),
                semanticLabel: '全选当前可生产产品和自制备料项',
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '可排产产品 / 自制件',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    '可生产 $readyCount · 待备料 ${ordered.length - readyCount} · '
                    '待自制 ${pendingMakeCandidates.length} · '
                    '已选 ${_selectedPlanLineIds.length}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (_canAdjustPriorities && analysis.products.length > 1)
              UtenButton(
                key: const Key('material-analysis-priority-edit'),
                type: UtenButtonType.ghost,
                icon: Icons.swap_vert_rounded,
                onPressed: _busy || _editingPriorities
                    ? null
                    : _beginPriorityEdit,
                child: const Text('调整物料优先顺序'),
              ),
          ],
        ),
        if (_editingPriorities) ...[
          const SizedBox(height: UtenSpacing.s8),
          _priorityEditor(theme, byId),
        ],
        if (pendingMakeCandidates.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          Container(
            key: const Key('material-analysis-pending-make-section'),
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: pendingMakeAllBlocked
                  ? theme.colorScheme.errorContainer.withValues(alpha: 0.22)
                  : theme.colorScheme.surfaceContainerLow,
              borderRadius: UtenRadius.mdAll,
              border: Border.all(
                color: pendingMakeAllBlocked
                    ? theme.colorScheme.error.withValues(alpha: 0.42)
                    : theme.colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      pendingMakeAllBlocked
                          ? Icons.do_not_disturb_on_outlined
                          : Icons.account_tree_outlined,
                      color: pendingMakeSectionAccent,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            pendingMakeAllBlocked
                                ? '已确认自制 · 下层未齐套'
                                : '已确认自制 · 下层备料',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: pendingMakeSectionForeground,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            '路线已经保存，但这些自制件尚未形成真实子任务。'
                            '卡片持续显示阻断原因；直接子层级齐套后才可安排生产。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: pendingMakeAllBlocked
                                  ? theme.colorScheme.onErrorContainer
                                  : theme.colorScheme.onSurfaceVariant,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s8),
                UtenResponsiveGrid(
                  itemCount: visiblePendingMake.length,
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  itemBuilder: (context, index, itemWidth) =>
                      _pendingMakeCard(theme, visiblePendingMake[index]),
                ),
                if (remainingPendingMake > 0) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Align(
                    child: UtenButton(
                      key: const Key(
                        'material-analysis-show-more-pending-make',
                      ),
                      type: UtenButtonType.tonal,
                      icon: Icons.expand_more_rounded,
                      onPressed: () =>
                          setState(() => _pendingMakeVisibleLimit += 20),
                      child: Text('继续显示待自制件(还有 $remainingPendingMake 个)'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: UtenSpacing.s8),
        // 卡片高度随缺料摘要、计划入口、选中态输入框变化：Wrap 按行对齐会让
        // 矮卡片下方留白，瀑布流按列独立堆叠，各列高度互不影响。
        UtenResponsiveGrid(
          itemCount: visibleProducts.length,
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          itemBuilder: (context, index, itemWidth) =>
              _productCard(theme, visibleProducts[index]),
        ),
        if (remainingProducts > 0) ...[
          const SizedBox(height: UtenSpacing.s8),
          Align(
            child: UtenButton(
              key: const Key('material-analysis-show-more-products'),
              type: UtenButtonType.tonal,
              icon: Icons.expand_more_rounded,
              onPressed: () => setState(() => _productVisibleLimit += 60),
              child: Text('继续显示下一批(还有 $remainingProducts 个)'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _pendingMakeCard(ThemeData theme, _PendingMakeCandidate candidate) {
    final material = candidate.material;
    final waiting = material.lowerLevelPending;
    final group = candidate.group;
    final canArrange = _canArrangePendingMakeCandidate(candidate);
    final blocked = !canArrange;
    final accent = blocked
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final statusSurface = blocked
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.primaryContainer;
    final onStatusSurface = blocked
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onPrimaryContainer;
    final description = waiting
        ? candidate.shortageKindCount > 0
              ? '下层还缺 ${candidate.shortageKindCount} 种物料'
                    '${candidate.shortagePathCount > candidate.shortageKindCount ? ' · 共 ${candidate.shortagePathCount} 条 BOM 路径' : ''}'
                    '${candidate.unconfirmedPathCount > 0 ? ' · 其中 ${candidate.unconfirmedPathCount} 条路线待确认' : ''}'
              : '下层物料尚未齐套，请继续处理下方 BOM 缺口'
        : canArrange
        ? '直接子层级已经齐套，可以创建真实自制子任务并填写生产计划'
        : '当前快照尚未满足自制任务执行门槛，请刷新后再试';
    final statusLabel = waiting
        ? '下层备料中'
        : canArrange
        ? '下层已齐套'
        : '暂不可安排';
    final meta = [
      material.goodsCode,
      material.spec,
      if (material.unitName?.isNotEmpty == true)
        '本批缺口 ${_qty(material.shortageQty)} ${material.unitName}',
    ].whereType<String>().join(' · ');
    return Semantics(
      container: true,
      label:
          '待自制子件 ${material.goodsName ?? material.goodsCode ?? material.materialLineId}，'
          '$description',
      child: Card(
        key: ValueKey(
          'material-analysis-pending-make-${material.materialLineId}',
        ),
        margin: EdgeInsets.zero,
        elevation: 0,
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: UtenRadius.mdAll,
          side: BorderSide(color: accent.withValues(alpha: 0.5)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: canArrange ? '下层已齐套，可安排生产' : '$statusLabel，不可排产',
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: statusSurface.withValues(alpha: 0.5),
                          borderRadius: UtenRadius.smAll,
                          border: Border.all(
                            color: accent.withValues(alpha: 0.42),
                          ),
                        ),
                        child: Icon(
                          blocked
                              ? Icons.do_not_disturb_on_outlined
                              : Icons.precision_manufacturing_outlined,
                          color: accent,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          material.goodsName ?? material.goodsCode ?? '待自制子件',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          candidate.parentLabel == null
                              ? '自制路线已确认'
                              : '用于组装 ${candidate.parentLabel}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s8,
                      vertical: UtenSpacing.s4,
                    ),
                    decoration: BoxDecoration(
                      color: statusSurface.withValues(alpha: 0.5),
                      borderRadius: UtenRadius.smAll,
                    ),
                    child: Text(
                      statusLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  meta,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: UtenSpacing.s8),
              Container(
                key: ValueKey(
                  'material-analysis-pending-make-status-${material.materialLineId}',
                ),
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: statusSurface.withValues(alpha: 0.5),
                  borderRadius: UtenRadius.smAll,
                  border: Border.all(color: accent.withValues(alpha: 0.45)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      canArrange ? '下层已齐套 · 可安排生产' : '暂不可生产 · $description',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      waiting
                          ? '这是一张待办展示卡，不是生产计划；请在下方 BOM 继续处理子层级。'
                          : canArrange
                          ? '点击安排后才会创建真实 MAKE_COMPONENT；取消计划表单不会伪造正式计划。'
                          : '当前状态不开放安排生产；刷新后仍会由服务端重新校验。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: onStatusSurface,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              if (!waiting) ...[
                const SizedBox(height: UtenSpacing.s8),
                UtenButton(
                  key: ValueKey(
                    'material-analysis-pending-make-arrange-${material.materialLineId}',
                  ),
                  icon: Icons.precision_manufacturing_outlined,
                  isLoading: _notifyingRoute == MaterialSupplyRoute.make,
                  onPressed: canArrange && _canNotify && !_busy
                      ? () => _arrangeMakeProduction(group!)
                      : null,
                  onDisabledTap: _busy
                      ? null
                      : () {
                          if (!_canNotify) {
                            context.appWarning('没有安排自制生产的权限');
                          } else {
                            context.appWarning('自制节点状态已变化，请刷新后重试');
                          }
                        },
                  child: const Text('安排生产'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _priorityEditor(
    ThemeData theme,
    Map<String, ProductionMaterialAnalysisProduct> products,
  ) => Container(
    key: const Key('material-analysis-priority-editor'),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '生产优先级',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          '优先产品先模拟分配共享可用库存；这里只调整分析顺序，不创建正式库存预留。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        SizedBox(
          height: (_priorityDraft.length * 56.0).clamp(56.0, 480.0),
          child: Scrollbar(
            child: ListView.builder(
              key: const Key('material-analysis-priority-list'),
              itemExtent: 56,
              itemCount: _priorityDraft.length,
              itemBuilder: (_, index) => Container(
                key: ValueKey('material-priority-${_priorityDraft[index]}'),
                padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      foregroundColor: theme.colorScheme.onPrimaryContainer,
                      child: Text('${index + 1}'),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        products[_priorityDraft[index]]?.goodsName ??
                            products[_priorityDraft[index]]?.goodsCode ??
                            _priorityDraft[index],
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      key: ValueKey('material-priority-up-$index'),
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      tooltip: '提高优先级',
                      onPressed: index == 0 || _savingPriorities
                          ? null
                          : () => _movePriority(index, -1),
                      icon: const Icon(Icons.arrow_upward_rounded),
                    ),
                    IconButton(
                      key: ValueKey('material-priority-down-$index'),
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      tooltip: '降低优先级',
                      onPressed:
                          index == _priorityDraft.length - 1 ||
                              _savingPriorities
                          ? null
                          : () => _movePriority(index, 1),
                      icon: const Icon(Icons.arrow_downward_rounded),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            UtenButton(
              key: const Key('material-analysis-priority-cancel'),
              type: UtenButtonType.ghost,
              onPressed: _savingPriorities ? null : _cancelPriorityEdit,
              child: const Text('取消'),
            ),
            UtenButton(
              key: const Key('material-analysis-priority-save'),
              icon: Icons.check_rounded,
              isLoading: _savingPriorities,
              onPressed: _savingPriorities ? null : _savePriorities,
              child: const Text('确认优先顺序'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _productCard(
    ThemeData theme,
    ProductionMaterialAnalysisProduct product,
  ) {
    final selectable = _canSelectProduct(product);
    final selected = _selectedPlanLineIds.contains(product.analysisLineId);
    final executionStage = _productExecutionStage(product);
    final fullyTransferred = _productFullyTransferred(product);
    final foreground = selected ? Colors.white : null;
    final secondaryForeground = selected
        ? Colors.white70
        : theme.colorScheme.onSurfaceVariant;
    return Card(
      key: ValueKey('material-analysis-product-${product.analysisLineId}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: selected ? UtenColors.deepGreen : null,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.mdAll,
        side: BorderSide(
          color: selected
              ? UtenColors.deepGreen
              : theme.colorScheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: fullyTransferred
                      ? Semantics(
                          label: executionStage!.label,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: selected
                                  ? Colors.white.withValues(alpha: 0.16)
                                  : _productExecutionColor(
                                      theme,
                                      executionStage,
                                      selected: false,
                                    ).withValues(alpha: 0.12),
                              borderRadius: UtenRadius.smAll,
                              border: Border.all(
                                color: selected
                                    ? Colors.white54
                                    : _productExecutionColor(
                                        theme,
                                        executionStage,
                                        selected: false,
                                      ).withValues(alpha: 0.45),
                              ),
                            ),
                            child: Center(
                              child: Icon(
                                executionStage.icon,
                                color: _productExecutionColor(
                                  theme,
                                  executionStage,
                                  selected: selected,
                                ),
                              ),
                            ),
                          ),
                        )
                      : Checkbox(
                          key: ValueKey(
                            'material-analysis-product-select-${product.analysisLineId}',
                          ),
                          value: selected,
                          onChanged: !selectable || _busy
                              ? null
                              : (value) =>
                                    _toggleProduct(product, value == true),
                          fillColor: selected
                              ? const WidgetStatePropertyAll(Colors.white)
                              : null,
                          checkColor: selected ? UtenColors.deepGreen : null,
                          semanticLabel:
                              '选择${product.goodsName ?? product.goodsCode ?? '当前产品'}填写生产计划单',
                        ),
                ),
                const SizedBox(width: UtenSpacing.s4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.goodsName ?? product.goodsCode ?? '未命名产品',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (product.sourceType == 'MAKE_COMPONENT')
                        Text(
                          product.parentGoodsName == null
                              ? '自制备料任务'
                              : '自制备料任务 · 用于组装 ${product.parentGoodsName}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: selected
                                ? Colors.white
                                : theme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            Text(
              [
                product.orderNo ?? product.sourceRef,
                product.goodsCode,
                product.spec,
              ].whereType<String>().join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: secondaryForeground,
              ),
            ),
            if (selected && product.sourceReason?.trim().isNotEmpty == true)
              Text(
                '来源原因：${product.sourceReason}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: secondaryForeground,
                ),
              ),
            const SizedBox(height: UtenSpacing.s8),
            _productShortageSummary(theme, product, selected: selected),
            _producibleHeadline(theme, product, selected: selected),
            _readinessBlockerHint(theme, product, selected: selected),
            if (product.latestPlanId != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              if (_canViewPlans)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    key: ValueKey(
                      'material-analysis-product-plan-${product.analysisLineId}',
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: selected ? Colors.white : null,
                      side: selected
                          ? const BorderSide(color: Colors.white70)
                          : null,
                    ),
                    onPressed: _busy
                        ? null
                        : () => context.push(
                            RoutePath.productionPlanDetail(
                              product.latestPlanId!,
                            ),
                          ),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: Text(
                      product.latestPlanNo == null
                          ? '进入生产计划'
                          : '进入生产计划 · ${product.latestPlanNo}',
                    ),
                  ),
                )
              else
                Semantics(
                  label: '没有查看生产计划权限',
                  child: Row(
                    children: [
                      Icon(
                        Icons.lock_outline_rounded,
                        size: 18,
                        color: secondaryForeground,
                      ),
                      const SizedBox(width: UtenSpacing.s4),
                      Expanded(
                        child: Text(
                          '当前账号无查看生产计划权限，请由计划负责人继续处理',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: secondaryForeground,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (selected) ...[
              const SizedBox(height: UtenSpacing.s4),
              _readinessReference(theme, product, selected: selected),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                key: Key('batch-qty-${product.analysisLineId}'),
                controller: _batchQtyControllers[product.analysisLineId],
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() => _planPreview = null),
                style: TextStyle(color: selected ? UtenColors.docInk : null),
                decoration: InputDecoration(
                  labelText: '本批生产数量',
                  helper: UtenFieldMessage.helper(
                    '最多 ${_qty(product.readyNowQty)} 个',
                  ),
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 产品卡缺口摘要：种类按服务端 materialKey/货色单位去重，同时保留
  /// BOM 路径数，避免同一种共享物料在多路径出现时被误写成多种料。
  /// 这里只统计服务端 shortage 快照，不重算任何可生产数量。
  Widget _productShortageSummary(
    ThemeData theme,
    ProductionMaterialAnalysisProduct product, {
    required bool selected,
  }) {
    final analysis = _analysis;
    if (analysis == null) return const SizedBox.shrink();
    if (_productFullyTransferred(product)) return const SizedBox.shrink();
    final nodes =
        _analysisIndexes(analysis).materialsByProduct[product.analysisLineId] ??
        const <ProductionMaterialAnalysisMaterial>[];
    final shortageNodes = nodes
        .where((node) => node.shortageQty > 0)
        .toList(growable: false);
    if (shortageNodes.isEmpty) return const SizedBox.shrink();
    final shortageKindCount = shortageNodes
        .map(_materialKindIdentity)
        .toSet()
        .length;
    final unconfirmed = shortageNodes
        .where((node) => node.confirmedRoute == null)
        .length;
    final foreground = selected ? Colors.white : theme.colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, size: 20, color: foreground),
          const SizedBox(width: UtenSpacing.s4),
          Expanded(
            child: Text(
              '还缺 $shortageKindCount 种物料'
              '${shortageNodes.length > shortageKindCount ? ' · 共 ${shortageNodes.length} 条 BOM 路径' : ''}'
              '${unconfirmed > 0 ? ' · 其中 $unconfirmed 条路线待确认' : ''}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _transferredProductHeadline(
    ThemeData theme,
    ProductionMaterialAnalysisProduct product,
    _ProductExecutionStage stage, {
    required bool selected,
  }) {
    final accent = _productExecutionColor(theme, stage, selected: selected);
    final detail = stage.detail?.trim();
    return Container(
      key: ValueKey(
        'material-analysis-product-execution-${product.analysisLineId}',
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s12,
      ),
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withValues(alpha: 0.14)
            : accent.withValues(alpha: 0.10),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(
          color: selected ? Colors.white54 : accent.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(stage.icon, color: accent, size: 24),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  stage.label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: selected
                        ? Colors.white
                        : theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(
              detail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: selected
                    ? Colors.white70
                    : theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Single authoritative headline: how many products can actually be built
  /// and put into warehouse ([readyNowQty], which the server persists as the
  /// finish-stage complete-kit quantity). START-stage readiness is deliberately
  /// NOT used here — showing "可开工" while finish is zero is what misleads
  /// planners into thinking production can start. When nothing can be produced,
  /// the headline says so plainly and the card stays unselectable.
  Widget _producibleHeadline(
    ThemeData theme,
    ProductionMaterialAnalysisProduct product, {
    required bool selected,
  }) {
    final executionStage = _productExecutionStage(product);
    if (_productFullyTransferred(product) && executionStage != null) {
      return _transferredProductHeadline(
        theme,
        product,
        executionStage,
        selected: selected,
      );
    }
    final maxQty = product.readyNowQty;
    final producible = maxQty > 0;
    final directMake = producible && !_hasProductionMaterialChildren(product);
    final ratio = product.readinessRatio.clamp(0.0, 1.0);
    final onSurface = selected ? Colors.white : theme.colorScheme.onSurface;
    final accent = selected
        ? Colors.white
        : producible
        ? theme.colorScheme.primary
        : theme.colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withValues(alpha: 0.14)
            : producible
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
            : theme.colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(
          color: selected
              ? Colors.white54
              : producible
              ? theme.colorScheme.primary.withValues(alpha: 0.45)
              : theme.colorScheme.error.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                producible
                    ? Icons.check_circle_rounded
                    : Icons.do_not_disturb_on_outlined,
                color: accent,
                size: 22,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  directMake
                      ? '无下层物料，可直接自制 ${_qty(maxQty)} 个'
                      : producible
                      ? '最多可生产 ${_qty(maxQty)} 个'
                      : '整套物料未齐，暂不可生产',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                directMake ? '无需领料' : '齐套 ${(ratio * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          if (directMake)
            Text(
              key: ValueKey(
                'material-analysis-direct-make-${product.analysisLineId}',
              ),
              '无需备料齐套，可直接填写生产计划；审核下达后不会生成空领料单。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: selected
                    ? Colors.white70
                    : theme.colorScheme.onPrimaryContainer,
              ),
            )
          else ...[
            if (!producible) ...[
              Text(
                '“最多可生产”是整套齐套量；单项合格到货会在下方物料卡显示。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected
                      ? Colors.white70
                      : theme.colorScheme.onErrorContainer,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
            ],
            // 齐套进度条：与右侧「齐套 X%」同源（服务端 readinessRatio），
            // 大字 + 条形双通道表达，不只靠颜色，方便现场一眼看出还差多少。
            Semantics(
              label: '齐套进度 ${(ratio * 100).toStringAsFixed(0)}%',
              child: ClipRRect(
                borderRadius: UtenRadius.smAll,
                child: LinearProgressIndicator(
                  key: ValueKey(
                    'material-analysis-product-progress-${product.analysisLineId}',
                  ),
                  value: ratio,
                  minHeight: 10,
                  backgroundColor: selected
                      ? Colors.white24
                      : theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(accent),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The other two stage quantities are kept (ADR-029 §5.2 forbids merging the
  /// three into one fuzzy number) but demoted to a single small reference line,
  /// with "可开工" relabelled to "开工段就绪" so it can no longer be read as
  /// "you may start production". Neither value caps the batch input.
  /// Explains WHY a non-ready product is blocked and what unblocks it, so the
  /// planner can follow the bottom-up chain without guessing. Hidden once the
  /// product is plan-ready (the headline already says "最多可生产 X 个").
  Widget _readinessBlockerHint(
    ThemeData theme,
    ProductionMaterialAnalysisProduct product, {
    required bool selected,
  }) {
    if (product.readyNowQty > 0 || _productFullyTransferred(product)) {
      return const SizedBox.shrink();
    }
    final readiness = _productReadiness(product);
    final parts = <String>[];
    if (readiness.make > 0) parts.add('自制子件 ${readiness.make}');
    if (readiness.buy > 0) parts.add('采购 ${readiness.buy}');
    if (readiness.subcontract > 0) parts.add('委外 ${readiness.subcontract}');
    if (readiness.review > 0) parts.add('待判断路线 ${readiness.review}');
    if (parts.isEmpty) parts.add('物料未齐');
    final hint = readiness.state == _ReadinessState.waitingMake
        ? '先排产并入库下级自制件，本件可完工会自动上调'
        : '已通知对应部门，等合格到货后刷新';
    final accent = selected ? Colors.white70 : theme.colorScheme.error;
    final message = '等待：${parts.join(' · ')} · $hint';
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s4),
      child: Semantics(
        container: true,
        label: '生产阻断：$message',
        child: Text(
          key: ValueKey(
            'material-analysis-product-blocker-${product.analysisLineId}',
          ),
          message,
          style: theme.textTheme.bodySmall?.copyWith(
            color: accent,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _readinessReference(
    ThemeData theme,
    ProductionMaterialAnalysisProduct product, {
    required bool selected,
  }) {
    final secondary = selected
        ? Colors.white70
        : theme.colorScheme.onSurfaceVariant;
    final startQty = product.readyStartQty ?? product.readyNowQty;
    final shipQty =
        product.readyShipQty ?? product.readyFinishQty ?? product.readyNowQty;
    return Text(
      '参考：开工段就绪 ${_qty(startQty)} · 含包装可发 ${_qty(shipQty)}'
      '(仅反映备料进度，不计入本批上限)',
      style: theme.textTheme.bodySmall?.copyWith(color: secondary),
    );
  }

  Widget _nodeDetailsToggle(
    ThemeData theme,
    _MaterialGroup group, {
    Color? foreground,
    bool compact = false,
  }) {
    final material = group.representative;
    final expanded = _expandedPathGroups.contains(group.key);
    void toggleDetails() => setState(() {
      if (!_expandedPathGroups.add(group.key)) {
        _expandedPathGroups.remove(group.key);
      }
    });

    return Semantics(
      button: true,
      expanded: expanded,
      excludeSemantics: true,
      label:
          '${expanded ? '收起' : '展开'}'
          '${material.goodsName ?? material.goodsCode ?? '当前物料'}详情',
      onTap: toggleDetails,
      child: compact
          ? IconButton(
              key: ValueKey(
                'material-node-details-toggle-${material.materialLineId}',
              ),
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              tooltip: expanded ? '收起详情' : '详情',
              onPressed: toggleDetails,
              icon: Icon(
                expanded
                    ? Icons.expand_less_rounded
                    : Icons.info_outline_rounded,
                size: 20,
                color: foreground,
              ),
            )
          : TextButton.icon(
              key: ValueKey(
                'material-node-details-toggle-${material.materialLineId}',
              ),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 40),
                padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
                foregroundColor: foreground,
              ),
              onPressed: toggleDetails,
              icon: Icon(
                expanded
                    ? Icons.expand_less_rounded
                    : Icons.info_outline_rounded,
                size: 18,
              ),
              label: Text(expanded ? '收起' : '详情'),
            ),
    );
  }

  Widget _nodeDetails(ThemeData theme, _MaterialGroup group) {
    final material = group.representative;
    final exactPeggedQty = material.exactPeggedQty;
    final warehouseStock = _selectedWarehouseStock(material);
    final coverage = _coverageOf(material);
    final detailFacts = <String>[
      if (coverage != null) '本批已保障 ${_qty(coverage.covered)}',
      if (exactPeggedQty > 0) '本节点合格入库绑定 ${_qty(exactPeggedQty)}',
      if (material.reservedQty > 0) '已预留 ${_qty(material.reservedQty)}',
      if (warehouseStock != null)
        '公共可用 ${_qty(warehouseStock.publicAvailableQty)}',
      if (material.safetyStockQty > 0) '安全保护 ${_qty(material.safetyStockQty)}',
      if (warehouseStock != null)
        '公共补库在途 ${_qty(warehouseStock.openSafetySupplyQty)}',
      if ((warehouseStock?.safetyReplenishmentGapQty ?? 0) > 0)
        '公共补库待补 ${_qty(warehouseStock!.safetyReplenishmentGapQty)}',
      if (material.inboundQty > 0) '本批供给预计在途 ${_qty(material.inboundQty)}',
      if (material.unitName?.isNotEmpty == true) '单位 ${material.unitName}',
      _materialStageLabel(material),
    ];
    return Container(
      key: ValueKey('material-node-details-${material.materialLineId}'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
            children: [
              for (final fact in detailFacts)
                Text(fact, style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          for (final path in group.paths)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s4),
                  Expanded(
                    child: Text(
                      '路径：${_pathLabel(path)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: UtenSpacing.s4),
          // 2026-08-18 起路线选择与建议不再放在详情里：路线操作收进右侧
          // 操作区（采用建议 / 更换路线按钮），详情只保留高级字段与路径。
          if (!group.actionable)
            _inactiveNodeHint(theme, material, selected: false),
          _nodeBorrowSection(theme, material),
        ],
      ),
    );
  }

  Widget _inactiveNodeHint(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material, {
    required bool selected,
  }) => Text(
    material.requiredQty <= 0
        ? '本批无需补货'
        : material.shortageQty <= 0
        ? '库存已覆盖'
        : '当前节点只读',
    style: theme.textTheme.bodySmall?.copyWith(
      color: selected ? Colors.white70 : theme.colorScheme.onSurfaceVariant,
    ),
  );

  /// 节点唯一主动作。返回 null 表示该节点当前没有可显示的动作，
  /// 卡片右侧的整高操作区随之整体隐藏。
  Widget? _nodePrimaryAction(
    ThemeData theme,
    _MaterialGroup group,
    MaterialSupplyRoute? route, {
    required bool selected,
  }) {
    final material = group.representative;
    final notified = _notifiedTargetOf(material);
    if (notified != null) {
      if (notified.target == MaterialSupplyRoute.make) {
        final child = _makeChildProductOf(material);
        if (child != null &&
            child.planExecutionStatus == null &&
            _canSelectProduct(child)) {
          return FilledButton.tonalIcon(
            key: ValueKey(
              'material-arrange-production-${material.materialLineId}',
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: selected ? UtenColors.deepGreen : null,
              backgroundColor: selected ? Colors.white : null,
            ),
            onPressed: _canGenerate && !_busy
                ? () => _openPlanForProduct(child)
                : null,
            icon: const Icon(Icons.factory_outlined),
            label: const Text('安排生产'),
          );
        }
      }
      final child = notified.target == MaterialSupplyRoute.make
          ? _makeChildProductOf(material)
          : null;
      final latestPlanId = child?.latestPlanId;
      if (latestPlanId != null) {
        return TextButton.icon(
          key: ValueKey('material-view-plan-${material.materialLineId}'),
          style: TextButton.styleFrom(
            minimumSize: const Size(48, 48),
            foregroundColor: selected ? Colors.white : null,
          ),
          onPressed: () =>
              context.push(RoutePath.productionPlanDetail(latestPlanId)),
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: Text(child?.latestPlanNo ?? '查看计划'),
        );
      }
      // 分批提交的补交入口：上一批在途、缺口未闭合时可直接再提交余量。
      final notifiedRoute = notified.target;
      if (notifiedRoute != null &&
          _routeBlockedBySafetyGap(group, notifiedRoute)) {
        return _disabledNodeAction(
          selected ? Colors.white70 : theme.colorScheme.error,
          Icons.policy_outlined,
          '仅采购可补安全库存',
        );
      }
      if (notifiedRoute != null &&
          notifiedRoute != MaterialSupplyRoute.make &&
          _hasSupplySubmitQty(group, notifiedRoute)) {
        return FilledButton.tonalIcon(
          key: ValueKey('material-topup-${material.materialLineId}'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            foregroundColor: selected ? UtenColors.deepGreen : null,
            backgroundColor: selected ? Colors.white : null,
          ),
          onPressed: _canNotify && !_busy
              ? () => _notifyRoute(notifiedRoute, onlyGroupKeys: {group.key})
              : null,
          icon: const Icon(Icons.playlist_add_rounded),
          label: Text('继续提交${notifiedRoute.label}'),
        );
      }
      return null;
    }
    if (material.requiredQty <= 0) {
      return null;
    }
    if (material.shortageQty <= 0) {
      return null;
    }
    if (!group.actionable) {
      return null;
    }
    if (material.confirmedRoute == null) {
      final suggestion = material.sourceSuggestion;
      // 无建议路线：主动作让位给右操作区的「选择路线」按钮（弹路线面板），
      // 这里不再重复提供入口。
      if (suggestion == null) {
        return null;
      }
      return OutlinedButton.icon(
        key: ValueKey('material-adopt-route-${material.materialLineId}'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: selected ? UtenColors.deepGreen : null,
          backgroundColor: selected ? Colors.white : null,
        ),
        onPressed: _canRoute && !_busy
            ? () => _confirmSuggestedRoute(group)
            : null,
        icon: const Icon(Icons.check_circle_outline_rounded),
        label: Text('采用${suggestion.label}'),
      );
    }
    if (route == null || _dirtyRouteGroups.contains(group.key)) {
      return _disabledNodeAction(
        selected ? Colors.white70 : theme.colorScheme.tertiary,
        Icons.save_outlined,
        '请先保存路线',
      );
    }
    if (route == MaterialSupplyRoute.make && material.lowerLevelPending) {
      return null;
    }
    if (_routeBlockedBySafetyGap(group, route)) {
      return _disabledNodeAction(
        selected ? Colors.white70 : theme.colorScheme.error,
        Icons.policy_outlined,
        '仅采购可补安全库存',
      );
    }
    final label = switch (route) {
      MaterialSupplyRoute.buy => '提交采购',
      MaterialSupplyRoute.subcontract => '提交委外',
      MaterialSupplyRoute.make => '安排生产',
    };
    return FilledButton.tonalIcon(
      key: ValueKey('material-node-action-${material.materialLineId}'),
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: selected ? UtenColors.deepGreen : null,
        backgroundColor: selected ? Colors.white : null,
      ),
      onPressed: _canNotify && !_busy && _isExecutableSupplyGroup(group, route)
          ? route == MaterialSupplyRoute.make
                ? () => _arrangeMakeProduction(group)
                : () => _notifyRoute(route, onlyGroupKeys: {group.key})
          : null,
      icon: Icon(
        route == MaterialSupplyRoute.make
            ? Icons.precision_manufacturing_outlined
            : Icons.notifications_active_outlined,
      ),
      label: Text(label),
    );
  }

  Widget _disabledNodeAction(Color color, IconData icon, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: UtenSpacing.s4),
      Flexible(
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );

  _StatusView _materialStatus(ThemeData theme, _MaterialGroup group) {
    final material = group.representative;
    if (!group.actionable) {
      if (material.requiredQty <= 0) {
        return _StatusView(
          '本批无需补货',
          Icons.info_outline_rounded,
          theme.colorScheme.onSurfaceVariant,
        );
      }
      if (material.shortageQty <= 0) {
        return _StatusView(
          '本层库存已齐',
          Icons.check_circle_outline_rounded,
          theme.colorScheme.primary,
        );
      }
      return _StatusView(
        '当前节点只读',
        Icons.lock_outline_rounded,
        theme.colorScheme.tertiary,
      );
    }
    final notified = _notifiedTargetOf(material);
    final covered = material.shortageQty <= 0;
    final demandGap = _groupDemandSupplyGapQty(group);
    final safetyGap = _groupSafetyReplenishmentGapQty(group);
    final openSafety = _groupOpenSafetySupplyQty(group);
    // shortageQty 是最终齐套阻断；demandSupplyGapQty 与公共安全补库必须分层，
    // 不能再把“安全库存未补”写成“本批物料未到”。
    if (notified != null) {
      final route = notified.target;
      if (route != null && _routeBlockedBySafetyGap(group, route)) {
        return _StatusView(
          '本批需求 ${demandGap <= 0 ? '已覆盖' : '还差 ${_qty(demandGap)}'}'
          ' · 本版本仅采购路线支持公共安全补库',
          Icons.policy_outlined,
          theme.colorScheme.error,
        );
      }
      if (route == MaterialSupplyRoute.make) {
        if (covered) {
          return _StatusView(
            '已完工',
            Icons.check_circle_outline_rounded,
            theme.colorScheme.primary,
          );
        }
        final child = _makeChildProductOf(material);
        final executionStatus = child?.planExecutionStatus;
        if (executionStatus == 'COMPLETED') {
          return _StatusView(
            '已完工入库',
            Icons.check_circle_outline_rounded,
            theme.colorScheme.primary,
          );
        }
        final approved = child?.approvedQty ?? 0;
        final submitted = child?.submittedQty ?? 0;
        final label = switch (executionStatus) {
          'IN_PROGRESS' => '生产中',
          'DISPATCHED' => '已派工 · 待开工',
          'READY' || 'APPROVED' => '待领料 / 开工',
          'WAITING' => '计划待料',
          'SUBMITTED' => '计划审批中',
          _ when approved > 0 => '生产计划已下达',
          _ when submitted > 0 => '计划审批中',
          _ => '待安排生产',
        };
        return _StatusView(
          label,
          Icons.precision_manufacturing_outlined,
          executionStatus == 'IN_PROGRESS' || approved > 0
              ? theme.colorScheme.secondary
              : theme.colorScheme.primary,
        );
      }
      if (covered) {
        return _StatusView(
          '已齐套(库存已覆盖)',
          Icons.check_circle_outline_rounded,
          theme.colorScheme.primary,
        );
      }
      // 2026-08-18 起状态文字不再带单据编号（点击状态可弹出全链路进度，
      // 单号在进度弹窗里按步骤展示）。
      // 分批提交：上一批仍在途且剩余缺口未闭合时，明说「当前在途 / 还差」，
      // DONE 只代表历史任务已经完成，不能被「已提交 0」误读为从未下达；
      // 该行可继续勾选补交，不会被误认为已全部下单。
      final residual = _residualSubmitQty(
        group,
        route ?? MaterialSupplyRoute.buy,
      );
      if (route != null && residual > 0) {
        final safetySuffix = safetyGap > 0
            ? ' · 安全补库待补 ${_qty(safetyGap)}'
            : '';
        return _StatusView(
          '需求在途 ${_qty(_openSubmittedQty(group, route))} · '
          '本批还差 ${_qty(residual)}$safetySuffix',
          Icons.timelapse_rounded,
          route == MaterialSupplyRoute.subcontract
              ? theme.colorScheme.secondary
              : theme.colorScheme.tertiary,
        );
      }
      if (route == MaterialSupplyRoute.buy && safetyGap > 0) {
        return _StatusView(
          '本批需求已覆盖 · 公共补库在途 ${_qty(openSafety)} · '
          '待补 ${_qty(safetyGap)}',
          Icons.shield_outlined,
          theme.colorScheme.tertiary,
        );
      }
      return _StatusView(
        route == MaterialSupplyRoute.subcontract ? '等待委外入库' : '等待采购入库',
        Icons.local_shipping_outlined,
        route == MaterialSupplyRoute.subcontract
            ? theme.colorScheme.secondary
            : theme.colorScheme.tertiary,
      );
    }
    // 未通知：先看路线是否确认（ADR-029 §6.1 硬门槛）。
    if (material.confirmedRoute == null) {
      return _StatusView(
        '路线待确认',
        Icons.help_outline_rounded,
        theme.colorScheme.error,
      );
    }
    if (material.lowerLevelPending) {
      return _StatusView(
        '待齐套 · 下层 ${material.expectedReadyDate ?? '日期待定'}',
        Icons.do_not_disturb_on_outlined,
        theme.colorScheme.error,
      );
    }
    final confirmedRoute = material.confirmedRoute;
    if (confirmedRoute != null &&
        _routeBlockedBySafetyGap(group, confirmedRoute)) {
      return _StatusView(
        '本版本仅采购路线支持公共安全补库',
        Icons.policy_outlined,
        theme.colorScheme.error,
      );
    }
    if (demandGap > 0) {
      return _StatusView(
        '本批需求待通知 ${_qty(demandGap)}',
        Icons.notifications_active_outlined,
        theme.colorScheme.tertiary,
      );
    }
    if (confirmedRoute == MaterialSupplyRoute.buy && safetyGap > 0) {
      return _StatusView(
        '本批需求已覆盖 · 待提交公共安全补库 ${_qty(safetyGap)}',
        Icons.shield_outlined,
        theme.colorScheme.tertiary,
      );
    }
    if (material.shortageQty > 0) {
      return _StatusView(
        '本批需求已覆盖 · 安全保护处理中',
        Icons.shield_outlined,
        theme.colorScheme.tertiary,
      );
    }
    return _StatusView(
      '已齐套',
      Icons.check_circle_outline_rounded,
      theme.colorScheme.primary,
    );
  }

  /// 该物料组当前有效的「已下达通知」目标（跳过已撤销 CANCELLED）。
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

  /// 解析自制通知对应的 MAKE_COMPONENT 子产品（用于 待生产/生产中/已完工 推导）。
  /// 主路径：notifiedTargets 中 PREPLAN_MAKE_TASK 的 documentId == 子产品 analysisLineId；
  /// 回退：sourceType==MAKE_COMPONENT && parentAnalysisLineId==本料 analysisLineId && goodsId 相同。
  ProductionMaterialAnalysisProduct? _makeChildProductOf(
    ProductionMaterialAnalysisMaterial material,
  ) {
    final analysis = _analysis;
    if (analysis == null) return null;
    String? childId;
    for (final target in material.notifiedTargets) {
      if (target.target == MaterialSupplyRoute.make &&
          target.documentType == 'PREPLAN_MAKE_TASK') {
        childId = target.documentId;
        break;
      }
    }
    for (final product in analysis.products) {
      if (product.sourceType != 'MAKE_COMPONENT') continue;
      if (childId != null && product.analysisLineId == childId) return product;
      if (product.parentAnalysisLineId == material.analysisLineId &&
          product.goodsId == material.goodsId) {
        return product;
      }
    }
    return null;
  }

  /// 物料类型三色角标（采购/委外/自制/待定）。与「层级 N」徽章同一套
  /// 外观（小胶囊：浅底 + 描边 + 彩色加粗字，上下内边距 2），仅颜色不同。
  Widget _typeBadge(
    ThemeData theme,
    MaterialSupplyRoute? route, {
    Color? onColor,
  }) {
    final (label, color) = switch (route) {
      MaterialSupplyRoute.make => ('自制', theme.colorScheme.primary),
      MaterialSupplyRoute.buy => ('采购', theme.colorScheme.tertiary),
      MaterialSupplyRoute.subcontract => ('委外', theme.colorScheme.secondary),
      null => ('待定', theme.colorScheme.error),
    };
    return _miniBadge(theme, label: label, color: color, onColor: onColor);
  }

  /// 「层级 N」徽章：与路线角标同款小胶囊，颜色取层级色板（与整卡阶梯
  /// 缩进、状态栏底色共用同一色板，三处冗余表达层级）。
  Widget _levelBadge(ThemeData theme, int level, {Color? onColor}) {
    return _miniBadge(
      theme,
      label: '层级 $level',
      color: _levelBandColor(theme, level),
      onColor: onColor,
    );
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

  Widget _statusLabel(ThemeData theme, _StatusView status) => Row(
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
  );

  String get _planActionLabel {
    final analysis = _analysis;
    if (analysis == null || _selectedPlanLineIds.isEmpty) {
      return '生成生产计划';
    }
    final selected = analysis.products
        .where(
          (product) => _selectedPlanLineIds.contains(product.analysisLineId),
        )
        .toList(growable: false);
    final childCount = selected
        .where((product) => product.sourceType == 'MAKE_COMPONENT')
        .length;
    if (childCount == selected.length) return '安排子件生产';
    if (childCount == 0) return '生成总装计划';
    return '生成生产计划';
  }

  /// 底部悬浮动作区的按钮集合（按需出现，见 §3.5）。
  List<Widget> _bottomActionButtons() {
    if (_isFqcReplenishmentOnly) return const <Widget>[];
    return <Widget>[
      for (final route in MaterialSupplyRoute.values)
        if (_canNotify && _selectedExecutableCount(route) > 0)
          UtenButton(
            key: Key('material-analysis-notify-${route.wireName}'),
            type: UtenButtonType.tonal,
            size: UtenButtonSize.large,
            icon: Icons.notifications_active_outlined,
            isLoading: _notifyingRoute == route,
            onPressed: _busy ? null : () => _notifyRoute(route),
            child: Text(_notifyLabel(route)),
          ),
      if (_canRoute && _unconfirmedSuggestedRouteCount > 0)
        UtenButton(
          key: const Key('material-analysis-accept-routes'),
          type: UtenButtonType.success,
          size: UtenButtonSize.large,
          isLoading: _savingRoutes,
          onPressed: _busy ? null : _acceptAllSuggestedRoutes,
          child: Text('采纳建议路线($_unconfirmedSuggestedRouteCount)'),
        ),
      if (_dirtyRouteGroups.isNotEmpty)
        UtenButton(
          type: UtenButtonType.tonal,
          size: UtenButtonSize.large,
          icon: Icons.rule_folder_outlined,
          isLoading: _savingRoutes,
          onPressed: !_canRoute || _busy ? null : _saveRoutes,
          child: Text('确认路线(${_dirtyRouteGroups.length})'),
        ),
      if (_selectedPlanLineIds.isNotEmpty)
        UtenButton(
          key: const Key('material-analysis-generate'),
          size: UtenButtonSize.large,
          icon: Icons.description_outlined,
          isLoading: _generating || _previewingPlan,
          onPressed: !_canGenerate || _busy || _editingPriorities
              ? null
              : _openPlanWizard,
          onDisabledTap: !_canGenerate
              ? () => context.appWarning('没有生成生产计划权限')
              : _editingPriorities
              ? () => context.appWarning('请先确认或取消生产优先级调整')
              : null,
          child: Text('$_planActionLabel(${_selectedPlanLineIds.length})'),
        ),
    ];
  }

  /// 右下角悬浮动作区：背景透明、不占布局空间（原来是一条白色吸底栏，
  /// 会挡住后面的卡片内容）。按钮各自带悬浮阴影，宽屏横排、窄屏竖排靠右。
  Widget? _floatingActions() {
    final buttons = _bottomActionButtons();
    if (buttons.isEmpty) return null;
    return UtenFloatingActionGroup(children: buttons);
  }

  Widget _planPreviewCard(
    ThemeData theme,
    ProductionMaterialPlanPreview preview,
  ) {
    final color = preview.canGenerate
        ? theme.colorScheme.primary
        : theme.colorScheme.error;
    return Container(
      key: const Key('material-analysis-plan-preview-result'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _statusLabel(
            theme,
            _StatusView(
              preview.canGenerate ? '计划预览通过' : '计划预览未通过',
              preview.canGenerate
                  ? Icons.verified_outlined
                  : Icons.gpp_maybe_outlined,
              color,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          for (final item in preview.items)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
              child: Row(
                children: [
                  Icon(
                    item.canGenerate
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 18,
                    color: item.canGenerate
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                  const SizedBox(width: UtenSpacing.s4),
                  Expanded(
                    child: Text(
                      '批次 ${item.analysisLineId}：选择 ${_qty(item.selectedQty)} · '
                      '服务端可生产 ${_qty(item.readyNowQty)}'
                      '${item.reason == null ? '' : ' · ${item.reason}'}',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _factChip(ThemeData theme, IconData icon, String label) => Container(
    constraints: const BoxConstraints(maxWidth: 280),
    padding: const EdgeInsets.symmetric(
      horizontal: UtenSpacing.s8,
      vertical: UtenSpacing.s8,
    ),
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: UtenSpacing.s4),
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
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

  Widget _serverRefreshBanner(ThemeData theme, String message) => Container(
    key: const Key('material-analysis-server-refresh-notice'),
    padding: const EdgeInsets.fromLTRB(
      UtenSpacing.s12,
      UtenSpacing.s8,
      UtenSpacing.s4,
      UtenSpacing.s8,
    ),
    decoration: BoxDecoration(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.55),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(
        color: theme.colorScheme.secondary.withValues(alpha: 0.4),
      ),
    ),
    child: Row(
      children: [
        Icon(Icons.sync_rounded, color: theme.colorScheme.secondary),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        IconButton(
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          tooltip: '关闭更新提示',
          onPressed: () => setState(() => _serverRefreshNotice = null),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
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
    var shortageCount = 0;
    var unconfirmedCount = 0;
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
      if (material.shortageQty > 0) {
        shortageCount++;
        if (material.confirmedRoute == null) unconfirmedCount++;
      }
    }
    final indexes = _MaterialAnalysisIndexes(
      productsById: productsById,
      materialsByProduct: materialsByProduct,
      groups: groups,
      groupsByLine: groupsByLine,
      shortageCount: shortageCount,
      unconfirmedCount: unconfirmedCount,
    );
    _indexCacheAnalysis = analysis;
    _indexCache = indexes;
    return indexes;
  }

  List<_MaterialGroup> _materialGroups(
    ProductionMaterialAnalysisView analysis,
  ) => _analysisIndexes(analysis).groups;

  _BomFilterProjection _bomFilterProjection(
    ProductionMaterialAnalysisView analysis,
  ) {
    if (identical(_bomProjectionAnalysis, analysis) &&
        _bomProjectionMode == _bomViewMode &&
        _bomProjectionKeyword == _bomKeyword &&
        _bomProjectionCache != null) {
      return _bomProjectionCache!;
    }
    final indexes = _analysisIndexes(analysis);
    final nodesByProduct =
        <String?, List<ProductionMaterialAnalysisMaterial>>{};
    var directMatches = 0;
    var visibleNodes = 0;
    for (final entry in indexes.materialsByProduct.entries) {
      final product = entry.key == null
          ? null
          : indexes.productsById[entry.key];
      directMatches += entry.value.where((material) {
        return _bomModeMatches(material) && _bomTextMatches(material, product);
      }).length;
      final visible = _visibleBomNodes(entry.value, product);
      if (visible.isNotEmpty) nodesByProduct[entry.key] = visible;
      visibleNodes += visible.length;
    }
    final projection = _BomFilterProjection(
      nodesByProduct: nodesByProduct,
      directMatchCount: directMatches,
      visibleNodeCount: visibleNodes,
    );
    _bomProjectionAnalysis = analysis;
    _bomProjectionMode = _bomViewMode;
    _bomProjectionKeyword = _bomKeyword;
    _bomProjectionCache = projection;
    return projection;
  }

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
}

final class _PendingMakeCandidate {
  const _PendingMakeCandidate({
    required this.material,
    required this.group,
    required this.parentLabel,
    required this.shortageKindCount,
    required this.shortagePathCount,
    required this.unconfirmedPathCount,
  });

  final ProductionMaterialAnalysisMaterial material;
  final _MaterialGroup? group;
  final String? parentLabel;
  final int shortageKindCount;
  final int shortagePathCount;
  final int unconfirmedPathCount;
}

final class _PendingRouteDecision {
  const _PendingRouteDecision({required this.groupKey, required this.decision});

  final String groupKey;
  final MaterialRouteDecision decision;

  String get identity =>
      '${decision.actionGroupKey ?? decision.materialLineId}|'
      '${decision.route.wireName}|${decision.reason ?? ''}';
}

final class _SupplyNotificationTarget {
  const _SupplyNotificationTarget({this.actionGroupKey, this.materialLineId})
    : assert(actionGroupKey != null || materialLineId != null);

  final String? actionGroupKey;
  final String? materialLineId;

  String get identity =>
      actionGroupKey == null ? 'LINE|$materialLineId' : 'GROUP|$actionGroupKey';
}

final class _MaterialAnalysisIndexes {
  const _MaterialAnalysisIndexes({
    required this.productsById,
    required this.materialsByProduct,
    required this.groups,
    required this.groupsByLine,
    required this.shortageCount,
    required this.unconfirmedCount,
  });

  final Map<String, ProductionMaterialAnalysisProduct> productsById;
  final Map<String?, List<ProductionMaterialAnalysisMaterial>>
  materialsByProduct;
  final List<_MaterialGroup> groups;
  final Map<String, _MaterialGroup> groupsByLine;
  final int shortageCount;
  final int unconfirmedCount;
}

final class _BomFilterProjection {
  const _BomFilterProjection({
    required this.nodesByProduct,
    required this.directMatchCount,
    required this.visibleNodeCount,
  });

  final Map<String?, List<ProductionMaterialAnalysisMaterial>> nodesByProduct;
  final int directMatchCount;
  final int visibleNodeCount;
}

sealed class _BomTreeEntry {
  const _BomTreeEntry();
}

final class _BomEmptyEntry extends _BomTreeEntry {
  const _BomEmptyEntry();
}

final class _BomProductEntry extends _BomTreeEntry {
  const _BomProductEntry(this.product);

  final ProductionMaterialAnalysisProduct product;
}

final class _BomOrphanEntry extends _BomTreeEntry {
  const _BomOrphanEntry();
}

final class _BomLoadMoreEntry extends _BomTreeEntry {
  const _BomLoadMoreEntry(this.remainingProducts);

  final int remainingProducts;
}

final class _BomMaterialEntry extends _BomTreeEntry {
  const _BomMaterialEntry(this.material, this.group, this.hasChildren);

  final ProductionMaterialAnalysisMaterial material;
  final _MaterialGroup group;
  final bool hasChildren;
}

class _OffTargetWarehousePeg {
  const _OffTargetWarehousePeg({
    required this.materialLabel,
    required this.warehouseLabel,
    required this.qty,
    this.unitName,
  });

  final String materialLabel;
  final String warehouseLabel;
  final double qty;
  final String? unitName;
}

class _ProductExecutionStage {
  const _ProductExecutionStage({
    required this.status,
    required this.label,
    this.detail,
    required this.icon,
  });

  final String status;
  final String label;
  final String? detail;
  final IconData icon;
}

enum _ReadinessState { ready, waitingMake, waitingSupply, waiting }

enum _BomViewMode {
  all('全部 BOM'),
  shortage('只看缺料'),
  unconfirmed('待确认路线');

  const _BomViewMode(this.label);

  final String label;
}

class _ProductReadiness {
  const _ProductReadiness(
    this.state, {
    this.make = 0,
    this.buy = 0,
    this.subcontract = 0,
    this.review = 0,
  });

  final _ReadinessState state;
  final int make;
  final int buy;
  final int subcontract;
  final int review;
}

class _MaterialGroup {
  const _MaterialGroup({required this.key, required this.paths});

  final String key;
  final List<ProductionMaterialAnalysisMaterial> paths;

  ProductionMaterialAnalysisMaterial get representative => paths.first;
  bool get actionable => representative.actionable;
}

/// 按物料汇总视图的一行：同一物料跨产品、跨 BOM 路径的展示投影。
/// 仅用于汇总展示与选择入口；任务身份仍是 [paths] 里的逐路径节点，
/// 合计数字只是各路径服务端事实的加总，客户端不重新分配库存。
class _MaterialAggregate {
  const _MaterialAggregate({required this.key, required this.paths});

  final String key;
  final List<ProductionMaterialAnalysisMaterial> paths;

  ProductionMaterialAnalysisMaterial get representative => paths.first;
  String? get goodsName => representative.goodsName;
  String? get goodsCode => representative.goodsCode;
  String? get spec => representative.spec;
  String? get colorName => representative.colorName;
  String? get unitName => representative.unitName;

  double get totalRequired =>
      paths.fold(0.0, (sum, item) => sum + item.requiredQty);
  double get totalShortage =>
      paths.fold(0.0, (sum, item) => sum + item.shortageQty);

  /// 现货是同一目标仓共享池快照，同料各路径应一致；取最大值防御脏数据。
  double get warehouseStock => paths.fold(
    0.0,
    (max, item) => item.availableQty > max ? item.availableQty : max,
  );

  int get productCount =>
      paths.map((item) => item.analysisLineId).toSet().length;

  double get coverageRatio => totalRequired <= 0
      ? 1
      : ((totalRequired - totalShortage) / totalRequired).clamp(0.0, 1.0);

  /// 所有路径的确认路线（未确认时取建议路线）一致时返回该路线，
  /// 否则返回 null，界面显示「路线不一」并引导展开逐条查看。
  MaterialSupplyRoute? get uniformSuggestion {
    final routes = paths
        .map((item) => item.confirmedRoute ?? item.sourceSuggestion)
        .toSet();
    return routes.length == 1 ? routes.first : null;
  }
}

class _StatusView {
  const _StatusView(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;
}

/// 数量确认对话框里的一行：一个提交单元（操作组或单行物料）。
/// maxQty = 本批生产需求缺口 − 已在途需求；公共安全库存补库是固定、显式、
/// 按 goods/color/unit 去重后的第二数量切片。
final class _SupplyQuantityEntry {
  const _SupplyQuantityEntry({
    required this.actionGroupKey,
    required this.materialLineId,
    required this.label,
    required this.dimensionKey,
    required this.openQty,
    required this.maxQty,
    required this.safetyStockQty,
    required this.publicAvailableQty,
    required this.openSafetySupplyQty,
    required this.safetyReplenishmentGapQty,
    this.safetyReplenishmentQty = 0,
    this.safetyDeduplicatedElsewhere = false,
    this.spec,
    this.unitName,
  });

  final String? actionGroupKey;
  final String? materialLineId;
  final String label;
  final String dimensionKey;
  final String? spec;
  final String? unitName;
  final double openQty;
  final double maxQty;
  final double safetyStockQty;
  final double publicAvailableQty;
  final double openSafetySupplyQty;
  final double safetyReplenishmentGapQty;
  final double safetyReplenishmentQty;
  final bool safetyDeduplicatedElsewhere;

  double totalQty(double demandQty) => demandQty + safetyReplenishmentQty;

  _SupplyQuantityEntry withSafetyReplenishment(
    double qty, {
    required bool deduplicatedElsewhere,
  }) => _SupplyQuantityEntry(
    actionGroupKey: actionGroupKey,
    materialLineId: materialLineId,
    label: label,
    dimensionKey: dimensionKey,
    spec: spec,
    unitName: unitName,
    openQty: openQty,
    maxQty: maxQty,
    safetyStockQty: safetyStockQty,
    publicAvailableQty: publicAvailableQty,
    openSafetySupplyQty: openSafetySupplyQty,
    safetyReplenishmentGapQty: safetyReplenishmentGapQty,
    safetyReplenishmentQty: qty,
    safetyDeduplicatedElsewhere: deduplicatedElsewhere,
  );

  MaterialSupplyQuantityInput toInput(double qty) =>
      MaterialSupplyQuantityInput(
        actionGroupKey: actionGroupKey,
        materialLineId: materialLineId,
        qty: qty,
        safetyReplenishmentQty: safetyReplenishmentQty,
      );
}

/// 提交采购/委外/自制前的数量确认对话框（适老化）：
/// 大字体、−/＋ 大按钮、默认按剩余缺口全量、可改小分批提交。
/// 确认前用大白话写清「提交后干什么」。客户端只收集输入，服务端逐项复核。
class _SupplyQuantityDialog extends StatefulWidget {
  const _SupplyQuantityDialog({
    required this.route,
    required this.entries,
    required this.qtyText,
  });

  final MaterialSupplyRoute route;
  final List<_SupplyQuantityEntry> entries;
  final String Function(double?) qtyText;

  @override
  State<_SupplyQuantityDialog> createState() => _SupplyQuantityDialogState();
}

class _SupplyQuantityDialogState extends State<_SupplyQuantityDialog> {
  final _formKey = GlobalKey<FormState>();
  late final List<TextEditingController> _controllers;
  late final List<FocusNode> _focusNodes;

  String get _routeLabel => widget.route.label;

  @override
  void initState() {
    super.initState();
    _controllers = [
      for (final entry in widget.entries)
        TextEditingController(text: widget.qtyText(entry.maxQty)),
    ];
    _focusNodes = [for (final _ in widget.entries) FocusNode()];
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    for (final focusNode in _focusNodes) {
      focusNode.dispose();
    }
    super.dispose();
  }

  double? _qtyAt(int index) => double.tryParse(_controllers[index].text.trim());

  void _step(int index, int delta) {
    final entry = widget.entries[index];
    final current = _qtyAt(index) ?? entry.maxQty;
    var next = current + delta;
    if (next < 0) next = 0;
    if (next > entry.maxQty) next = entry.maxQty;
    setState(() {
      _controllers[index].text = widget.qtyText(next);
    });
  }

  double get _demandTotalQty {
    var total = 0.0;
    for (var index = 0; index < widget.entries.length; index++) {
      final qty = _qtyAt(index);
      if (qty != null && qty >= 0) total += qty;
    }
    return total;
  }

  double get _safetyTotalQty => widget.entries.fold(
    0.0,
    (sum, entry) => sum + entry.safetyReplenishmentQty,
  );

  double get _totalQty => _demandTotalQty + _safetyTotalQty;

  bool get _hasUnsupportedSafetyGap =>
      widget.route != MaterialSupplyRoute.buy &&
      widget.entries.any((entry) => entry.safetyReplenishmentGapQty > 0);

  String? _validateQty(int index) {
    final entry = widget.entries[index];
    final qty = _qtyAt(index);
    if (qty == null) return '请输入有效数量';
    if (qty < 0) return '本批生产需求不能小于 0';
    if (qty > entry.maxQty + 0.0001) {
      return '最多提交 ${widget.qtyText(entry.maxQty)}'
          '(本批需求缺口 − 已在途需求)';
    }
    if (qty <= 0 && entry.safetyReplenishmentQty <= 0) {
      return '本批生产需求与公共安全库存补库不能同时为 0';
    }
    return null;
  }

  void _submit() {
    if (_hasUnsupportedSafetyGap) return;
    final valid = _formKey.currentState?.validate() ?? false;
    if (!valid) {
      for (var index = 0; index < widget.entries.length; index++) {
        if (_validateQty(index) != null) {
          _focusNodes[index].requestFocus();
          break;
        }
      }
      return;
    }
    Navigator.pop(context, [
      for (var index = 0; index < widget.entries.length; index++)
        widget.entries[index].toInput(_qtyAt(index)!),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaSize = MediaQuery.sizeOf(context);
    return AlertDialog(
      key: const Key('supply-quantity-dialog'),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s24,
      ),
      title: Text('确认提交数量 · $_routeLabel'),
      content: SizedBox(
        // AlertDialog 会对 content 做 intrinsic 测量：宽高都必须有界，
        // 懒加载列表（viewport）不能被 intrinsic 测量。
        width: (mediaSize.width - 64).clamp(280.0, 620.0),
        height: (mediaSize.height - 200).clamp(340.0, 620.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '“本批生产需求”可以改小；“公共安全库存补库”由当前公共库存'
                '与在途补库计算并固定显示。确认后只提交屏幕上这两项，不会暗加数量。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              if (_hasUnsupportedSafetyGap) ...[
                const SizedBox(height: UtenSpacing.s8),
                _unsupportedSafetyBanner(theme),
              ],
              const SizedBox(height: UtenSpacing.s12),
              // 物料可能上百种：列表懒构建，滚动流畅。
              Expanded(
                child: ListView.builder(
                  itemCount: widget.entries.length,
                  itemBuilder: (_, index) => _entryCard(theme, index),
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Container(
                key: const Key('supply-quantity-summary'),
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(
                    alpha: 0.35,
                  ),
                  borderRadius: UtenRadius.mdAll,
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Text(
                  '确认后：本批生产需求 ${widget.qtyText(_demandTotalQty)} '
                  '+ 公共安全库存补库 ${widget.qtyText(_safetyTotalQty)} '
                  '= 预计总量 ${widget.qtyText(_totalQty)}。'
                  '各物料仍按自己的基本单位下达。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    height: 1.45,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('supply-quantity-confirm'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _hasUnsupportedSafetyGap ? null : _submit,
          child: Text('确认提交$_routeLabel'),
        ),
      ],
    );
  }

  Widget _entryCard(ThemeData theme, int index) {
    final entry = widget.entries[index];
    final unit = entry.unitName ?? '件';
    final identity = entry.actionGroupKey ?? entry.materialLineId;
    final currentDemand = _qtyAt(index) ?? 0;
    return Semantics(
      container: true,
      label:
          '${entry.label}：本批生产需求 ${widget.qtyText(currentDemand)} $unit，'
          '公共安全库存补库 ${widget.qtyText(entry.safetyReplenishmentQty)} $unit，'
          '预计总量 ${widget.qtyText(entry.totalQty(currentDemand))} $unit',
      child: Container(
        key: ValueKey('supply-qty-$identity'),
        margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.label,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (entry.spec != null && entry.spec!.isNotEmpty)
              Text(
                entry.spec!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '本批生产需求上限 ${widget.qtyText(entry.maxQty)} $unit'
              '${entry.openQty > 0 ? ' · 需求在途 ${widget.qtyText(entry.openQty)} $unit' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Row(
              children: [
                _stepButton(theme, index, Icons.remove_rounded, -1),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: TextFormField(
                    key: ValueKey('supply-qty-input-$identity'),
                    controller: _controllers[index],
                    focusNode: _focusNodes[index],
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                    onChanged: (_) => setState(() {}),
                    validator: (_) => _validateQty(index),
                    errorBuilder: utenTextFieldErrorBuilder,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: '本批生产需求',
                      suffixText: unit,
                    ),
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                _stepButton(theme, index, Icons.add_rounded, 1),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            _safetySlice(theme, entry, unit),
            const SizedBox(height: UtenSpacing.s8),
            Container(
              key: ValueKey('supply-qty-total-$identity'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s12,
                vertical: UtenSpacing.s8,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.35,
                ),
                borderRadius: UtenRadius.smAll,
              ),
              child: Text(
                '预计总量 ${widget.qtyText(entry.totalQty(currentDemand))} $unit'
                ' = 本批 ${widget.qtyText(currentDemand)}'
                ' + 安全补库 ${widget.qtyText(entry.safetyReplenishmentQty)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _safetySlice(
    ThemeData theme,
    _SupplyQuantityEntry entry,
    String unit,
  ) {
    final unsupported =
        widget.route != MaterialSupplyRoute.buy &&
        entry.safetyReplenishmentGapQty > 0;
    final color = unsupported
        ? theme.colorScheme.error
        : theme.colorScheme.secondary;
    final detail = unsupported
        ? '本版本仅采购路线支持公共安全补库'
        : entry.safetyDeduplicatedElsewhere
        ? '同一物料的安全缺口已在本批另一行计入，本行固定为 0'
        : '安全保护 ${widget.qtyText(entry.safetyStockQty)}'
              ' − 公共可用 ${widget.qtyText(entry.publicAvailableQty)}'
              ' − 公共补库在途 ${widget.qtyText(entry.openSafetySupplyQty)}';
    return Container(
      key: ValueKey(
        'supply-safety-${entry.actionGroupKey ?? entry.materialLineId}',
      ),
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            unsupported ? Icons.policy_outlined : Icons.shield_outlined,
            color: color,
            size: 22,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '公共安全库存补库 '
                  '${widget.qtyText(entry.safetyReplenishmentQty)} $unit',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _unsupportedSafetyBanner(ThemeData theme) => Container(
    key: const Key('supply-safety-route-unsupported'),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.errorContainer,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.error),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.policy_outlined, color: theme.colorScheme.error),
        const SizedBox(width: UtenSpacing.s8),
        const Expanded(child: Text('本版本仅采购路线支持公共安全补库。当前路线不能提交，请取消后改用采购路线。')),
      ],
    ),
  );

  Widget _stepButton(
    ThemeData theme,
    int index,
    IconData icon,
    int delta,
  ) => SizedBox(
    width: 48,
    height: 48,
    child: IconButton.filledTonal(
      key: ValueKey(
        'supply-qty-step-$delta-'
        '${widget.entries[index].actionGroupKey ?? widget.entries[index].materialLineId}',
      ),
      tooltip: delta > 0 ? '加 1' : '减 1',
      onPressed: () => _step(index, delta),
      icon: Icon(icon),
    ),
  );
}

/// 借用调拨对话框的提交草稿：目标路径 + 数量 + 原因。
final class _BorrowRequestDraft {
  const _BorrowRequestDraft({
    required this.toMaterialLineId,
    required this.qty,
    required this.reason,
  });

  final String toMaterialLineId;
  final double qty;
  final String reason;
}

/// 现货调拨对话框（适老化）：默认数量 = min(借出方已分配, 对方缺口)，
/// 确认前用大白话写清双方影响。客户端只收集输入，服务端逐项复核。
class _BorrowDialog extends StatefulWidget {
  const _BorrowDialog({
    required this.from,
    required this.candidates,
    required this.productsById,
    required this.pathLabelOf,
    required this.qtyText,
  });

  final ProductionMaterialAnalysisMaterial from;
  final List<ProductionMaterialAnalysisMaterial> candidates;
  final Map<String, ProductionMaterialAnalysisProduct> productsById;
  final String Function(ProductionMaterialAnalysisMaterial) pathLabelOf;
  final String Function(double?) qtyText;

  @override
  State<_BorrowDialog> createState() => _BorrowDialogState();
}

class _BorrowDialogState extends State<_BorrowDialog> {
  String? _toMaterialLineId;
  late final TextEditingController _qtyController;
  late final TextEditingController _reasonController;
  String? _qtyError;

  @override
  void initState() {
    super.initState();
    _qtyController = TextEditingController();
    _reasonController = TextEditingController();
  }

  @override
  void dispose() {
    _qtyController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  ProductionMaterialAnalysisMaterial? get _target {
    for (final candidate in widget.candidates) {
      if (candidate.materialLineId == _toMaterialLineId) return candidate;
    }
    return null;
  }

  double get _maxQty {
    final target = _target;
    if (target == null) return 0;
    return widget.from.allocatedAvailableQty < target.shortageQty
        ? widget.from.allocatedAvailableQty
        : target.shortageQty;
  }

  void _selectTarget(String? materialLineId) {
    setState(() {
      _toMaterialLineId = materialLineId;
      _qtyError = null;
      // 默认值先行：数量自动填"能调的最大值"，员工只改例外。
      _qtyController.text = widget.qtyText(_maxQty);
    });
  }

  void _submit() {
    final target = _target;
    if (target == null) return;
    final qty = double.tryParse(_qtyController.text.trim());
    if (qty == null || qty <= 0) {
      setState(() => _qtyError = '请填写大于 0 的调拨数量');
      return;
    }
    if (qty > _maxQty) {
      setState(
        () => _qtyError =
            '最多可调 ${widget.qtyText(_maxQty)} 件'
            '(不超过借出方已分配量，也不超过对方缺口)',
      );
      return;
    }
    final reason = _reasonController.text.trim();
    if (reason.length < 2) return;
    Navigator.pop(
      context,
      _BorrowRequestDraft(
        toMaterialLineId: target.materialLineId,
        qty: qty,
        reason: reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fromProduct = widget.productsById[widget.from.analysisLineId];
    final fromProductLabel =
        fromProduct?.goodsName ?? fromProduct?.goodsCode ?? '当前产品';
    final target = _target;
    final toProduct = target == null
        ? null
        : widget.productsById[target.analysisLineId];
    final qty = double.tryParse(_qtyController.text.trim());
    return AlertDialog(
      key: const Key('material-borrow-dialog'),
      title: const Text('分析内调给产品'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '把「$fromProductLabel」已分配的 '
                '${widget.from.goodsName ?? widget.from.goodsCode ?? '该物料'} '
                '现货调给更急的产品。',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '这里仅调整当前物料分析内的产品分配。若接受方在其它分析，'
                '请使用“跨计划让料”；原计划会标记优先待补，接受计划无需返还。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '可调上限：已分配 ${widget.qtyText(widget.from.allocatedAvailableQty)} 件',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '调给哪个产品(只列出缺这种料的)：',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              RadioGroup<String>(
                groupValue: _toMaterialLineId,
                onChanged: _selectTarget,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final candidate in widget.candidates)
                      RadioListTile<String>(
                        key: ValueKey(
                          'material-borrow-target-${candidate.materialLineId}',
                        ),
                        value: candidate.materialLineId,
                        title: Text(
                          widget
                                  .productsById[candidate.analysisLineId]
                                  ?.goodsName ??
                              widget
                                  .productsById[candidate.analysisLineId]
                                  ?.goodsCode ??
                              '未命名产品',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          '路径：${widget.pathLabelOf(candidate)} · '
                          '缺 ${widget.qtyText(candidate.shortageQty)} 件',
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                key: const Key('material-borrow-qty'),
                controller: _qtyController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() => _qtyError = null),
                decoration: InputDecoration(
                  labelText: '调拨数量(件)',
                  // uten-field-message-exception: raw-message - AlertDialog intrinsic sizing does not support LayoutBuilder.
                  helperText: target == null
                      ? '先选择调给哪个产品'
                      : '最多 ${widget.qtyText(_maxQty)} 件',
                  // uten-field-message-exception: raw-message - AlertDialog intrinsic sizing does not support LayoutBuilder.
                  errorText: _qtyError,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                key: const Key('material-borrow-reason'),
                controller: _reasonController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '调拨原因(必填)',
                  // uten-field-message-exception: raw-message - AlertDialog intrinsic sizing does not support LayoutBuilder.
                  helperText: '会写入审计记录，例如"客户 X 加急，先保这单"。',
                ),
              ),
              if (target != null && qty != null && qty > 0) ...[
                const SizedBox(height: UtenSpacing.s12),
                Container(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiaryContainer.withValues(
                      alpha: 0.4,
                    ),
                    borderRadius: UtenRadius.mdAll,
                  ),
                  child: Text(
                    '确认后：「$fromProductLabel」会重新缺 '
                    '${widget.qtyText(qty)} 件该料；'
                    '「${toProduct?.goodsName ?? toProduct?.goodsCode ?? '对方产品'}」'
                    '缺口减少 ${widget.qtyText(qty)} 件。'
                    '正式下达采购/生产前都可以撤销。',
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('material-borrow-confirm'),
          onPressed: _toMaterialLineId == null ? null : _submit,
          child: const Text('确认分析内调配'),
        ),
      ],
    );
  }
}

class _RequiredReasonDialog extends StatefulWidget {
  const _RequiredReasonDialog({
    required this.title,
    required this.fieldKey,
    required this.initialValue,
    required this.helperMessage,
    required this.confirmLabel,
  });

  final String title;
  final Key fieldKey;
  final String initialValue;
  final String helperMessage;
  final String confirmLabel;

  @override
  State<_RequiredReasonDialog> createState() => _RequiredReasonDialogState();
}

class _RequiredReasonDialogState extends State<_RequiredReasonDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: widget.fieldKey,
      controller: _controller,
      autofocus: true,
      minLines: 2,
      maxLines: 4,
      decoration: InputDecoration(
        labelText: '原因(必填)',
        // uten-field-message-exception: raw-message - AlertDialog intrinsic sizing does not support LayoutBuilder.
        helperText: widget.helperMessage,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final value = _controller.text.trim();
          if (value.isEmpty) return;
          Navigator.pop(context, value);
        },
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}

/// 物料供给全链路进度弹窗（适老化大字号纵向时间线）。
///
/// 数据全部来自服务端只读链回溯（行动→申请→订货→审批→预计到货→收货→
/// 质检→库存），前端不在本地推算任何一步；打开时拉取一次，失败可重试。
class _SupplyProgressDialog extends ConsumerStatefulWidget {
  const _SupplyProgressDialog({
    required this.analysisId,
    required this.material,
  });

  final String analysisId;
  final ProductionMaterialAnalysisMaterial material;

  @override
  ConsumerState<_SupplyProgressDialog> createState() =>
      _SupplyProgressDialogState();
}

class _SupplyProgressDialogState extends ConsumerState<_SupplyProgressDialog> {
  MaterialSupplyProgress? _progress;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final progress = await ref
          .read(productionPlanRepositoryProvider)
          .materialSupplyProgress(
            widget.analysisId,
            widget.material.materialLineId,
          );
      if (!mounted) return;
      setState(() {
        _progress = progress;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = productionErrorMessage(error, fallback: '进度加载失败，请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goodsLabel =
        widget.material.goodsName ?? widget.material.goodsCode ?? '当前物料';
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('供给全链路进度'),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            goodsLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: UtenSpacing.s40),
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            : _error != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: UtenSpacing.s12),
                  UtenButton(
                    type: UtenButtonType.tonal,
                    icon: Icons.refresh_rounded,
                    onPressed: _load,
                    child: const Text('重试'),
                  ),
                ],
              )
            : _buildTimeline(theme, _progress!),
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildTimeline(ThemeData theme, MaterialSupplyProgress progress) {
    if (progress.steps.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Text('该物料还没有已下达的供给任务'),
      );
    }
    // 快递式追踪：最新进展在最上面（后端按业务顺序返回，这里倒序展示）。
    final steps = progress.steps.reversed.toList();
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < steps.length; i++)
            _ProgressStepTile(step: steps[i], isLast: i == steps.length - 1),
        ],
      ),
    );
  }
}

class _GeneratedPlanDialogAction {
  const _GeneratedPlanDialogAction.view(this.plan) : print = false;

  const _GeneratedPlanDialogAction.print(this.plan) : print = true;

  final ProductionGeneratedPlanRef plan;
  final bool print;
}

/// 进度时间线中的一步：左侧状态圆点 + 连接线，右侧步骤名、状态、单号与时间。
class _ProgressStepTile extends StatelessWidget {
  const _ProgressStepTile({required this.step, required this.isLast});

  final MaterialSupplyProgressStep step;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (dotColor, icon) = switch (step.state) {
      'DONE' => (UtenColors.deepGreen, Icons.check_rounded),
      'CURRENT' => (theme.colorScheme.tertiary, Icons.more_horiz_rounded),
      'REJECTED' => (theme.colorScheme.error, Icons.close_rounded),
      _ => (theme.colorScheme.outlineVariant, Icons.circle_outlined),
    };
    final stateLabel = switch (step.state) {
      'DONE' => '已完成',
      'CURRENT' => '进行中',
      'REJECTED' => '被驳回',
      _ => '未开始',
    };
    final Color? textColor = switch (step.state) {
      'DONE' => null,
      'CURRENT' => theme.colorScheme.tertiary,
      'REJECTED' => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 32,
            child: Column(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: step.state == 'WAITING'
                        ? Colors.transparent
                        : dotColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: dotColor, width: 2),
                  ),
                  child: Icon(
                    icon,
                    size: 14,
                    color: step.state == 'WAITING'
                        ? theme.colorScheme.onSurfaceVariant
                        : Colors.white,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: step.isDone
                          ? UtenColors.deepGreen.withValues(alpha: 0.4)
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: isLast ? 0 : UtenSpacing.s16,
                top: 2,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          step.label,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: textColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        stateLabel,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: step.state == 'WAITING'
                              ? theme.colorScheme.onSurfaceVariant
                              : dotColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  if (step.detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      step.detail!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (step.docNo != null ||
                      step.at != null ||
                      step.operatorName != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (step.docNo != null) step.docNo!,
                        // 快递式追踪：每步带责任人（提交人/采购人/审批人/收货人…）。
                        if (step.operatorName != null)
                          '负责人：${step.operatorName}',
                        if (step.at != null)
                          ChinaDateTime.formatIsoInstant(step.at),
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
