import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
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
import 'production_plan_summary_sheet_page.dart';
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
  bool _booting = true;
  bool _loadingCandidates = false;
  bool _previewingAnalysis = false;
  bool _savingRoutes = false;
  bool _savingPriorities = false;
  bool _borrowing = false;
  bool _previewingPlan = false;
  bool _generating = false;
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
  _BomViewMode _bomViewMode = _BomViewMode.shortage;

  /// BOM 区展示的两种排布：false = 按产品分组的 BOM 树（默认，现状）；
  /// true = 按物料汇总缺料（跨产品聚合同一物料，展开看每条 BOM 路径）。
  /// 只是展示投影：勾选与下达仍落到各自的逐路径节点任务，不合并任务身份。
  bool _bomAggregateByMaterial = false;
  final Set<String> _expandedMaterialAggregates = {};
  String _bomKeyword = '';
  final Map<String, String> _bomOverrideReasons = {};
  List<String> _priorityDraft = [];
  List<String> _priorityBaseline = [];
  bool _editingPriorities = false;
  int _routeControlRevision = 0;
  int _productVisibleLimit = 60;
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
    return analysis == null ||
        analysis.allowedActions.isEmpty ||
        analysis.allowedActions.contains(action);
  }

  bool get _canManage =>
      _permissions.contains(Perm.productionMaterialAnalysisManage) &&
      _serverAllows('REFRESH');
  bool get _canRoute =>
      _permissions.contains(Perm.productionMaterialAnalysisRoute) &&
      _serverAllows('CONFIRM_ROUTES');
  bool get _canNotify =>
      _permissions.contains(Perm.productionMaterialAnalysisNotify) &&
      _serverAllows('NOTIFY_SUPPLY');
  bool get _canGenerate =>
      _permissions.contains(Perm.productionMaterialAnalysisGenerate) &&
      _serverAllows('GENERATE_PLAN');
  bool get _canReallocate =>
      _permissions.contains(Perm.productionMaterialAnalysisReallocate) &&
      _serverAllows('REALLOCATE');
  bool get _canBomOverride =>
      _permissions.contains(Perm.productionMaterialAnalysisBomOverride);

  bool get _busy =>
      _previewingAnalysis ||
      _savingRoutes ||
      _savingPriorities ||
      _borrowing ||
      _previewingPlan ||
      _generating ||
      _notifyingRoute != null;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _bomSearchDebounce?.cancel();
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
        '单次联合分析最多 500 个来源（含手工计划），已保留可加入的前 $salesSourceLimit 项；其余请另开一个批次',
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
      context.appWarning('单次联合分析最多 500 个来源（销售产品与手工计划合计）');
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
      requireConfirm: true,
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
      setState(() {
        _previewingAnalysis = false;
        _error = productionErrorMessage(error, fallback: '联合物料分析失败');
      });
    }
  }

  void _applyAnalysis(ProductionMaterialAnalysisView view) {
    _analysis = view;
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
    final validOverrideIds = view.products
        .map((product) => product.analysisLineId)
        .toSet();
    _bomOverrideReasons.removeWhere(
      (analysisLineId, _) => !validOverrideIds.contains(analysisLineId),
    );
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

  Future<void> _setRoute(
    _MaterialGroup group,
    MaterialSupplyRoute? route,
  ) async {
    if (route == null || !_canRoute || !group.actionable) return;
    final suggestion = group.representative.sourceSuggestion;
    String? reason;
    if (suggestion == null || suggestion != route) {
      reason = await _promptRouteReason(group, route);
      if (reason == null || !mounted) {
        if (mounted) {
          setState(() => _routeControlRevision++);
        }
        return;
      }
    }
    setState(() {
      _routeDraft[group.key] = route;
      for (final selected in _selectedSupplyGroups.values) {
        selected.remove(group.key);
      }
      if (reason == null) {
        _routeReasons.remove(group.key);
      } else {
        _routeReasons[group.key] = reason;
      }
      _dirtyRouteGroups.add(group.key);
      _planPreview = null;
    });
  }

  /// The common path needs one click: accept this row's concrete master-data
  /// suggestion and persist it immediately. Manual overrides still go through
  /// the dropdown and mandatory reason dialog.
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
      helperText:
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

  Future<void> _promptBomOverride(
    ProductionMaterialAnalysisProduct product,
  ) async {
    if (!_canBomOverride) return;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => _RequiredReasonDialog(
        title: '填写资料异常继续原因',
        fieldKey: const Key('bom-override-reason'),
        initialValue: _bomOverrideReasons[product.analysisLineId] ?? '',
        helperText: '此操作会进入审计记录，不会补写或猜测 BOM。',
        confirmLabel: '确认原因',
      ),
    );
    if (reason == null || !mounted) return;
    setState(() {
      _bomOverrideReasons[product.analysisLineId] = reason;
      _planPreview = null;
    });
  }

  bool _alreadyNotified(_MaterialGroup group, MaterialSupplyRoute route) =>
      group.paths.any(
        (path) => path.notifiedTargets.any(
          (target) => target.target == route && target.status != 'CANCELLED',
        ),
      );

  bool _isExecutableSupplyGroup(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) =>
      group.actionable &&
      group.representative.shortageQty > 0 &&
      _routeDraft[group.key] == route &&
      !_dirtyRouteGroups.contains(group.key) &&
      !(route == MaterialSupplyRoute.make &&
          group.representative.lowerLevelPending) &&
      !_alreadyNotified(group, route);

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
      MaterialSupplyRoute.buy => '提交采购需求（$count）',
      MaterialSupplyRoute.subcontract => '提交委外需求（$count）',
      MaterialSupplyRoute.make => '安排自制生产（$count）',
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

  /// 行首选择控件：复选框只改变本地批量选择，不写业务事实。
  ///
  /// - 已下达通知 → 显示「已下达」标记，不再参与勾选；
  /// - 库存已覆盖（无缺口）→ 显示「已齐」标记，不出现死勾选框；
  /// - 路线已确认且可执行 → 直接勾选/取消；
  /// - 路线未确认但有主档建议 → 提示先点右侧“采用建议”，不把普通勾选
  ///   伪装成一次 PUT 写入；
  /// - 无建议路线 / 下层未齐套等 → 点按给出明确引导，不静默无响应。
  Widget _nodeSelectionControl(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup group,
    MaterialSupplyRoute? route,
    bool selected,
  ) {
    final notified = _notifiedTargetOf(material);
    if (notified != null) {
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
      return _nodeGateControl(
        theme,
        material,
        label: '仅查看',
        message: '没有下达采购、委外或生产任务的权限',
        icon: Icons.visibility_outlined,
      );
    }
    if (_dirtyRouteGroups.contains(group.key)) {
      return _nodeGateControl(
        theme,
        material,
        label: '先保存路线',
        message: '路线有未保存修改，保存后才可加入批量下达',
        icon: Icons.save_outlined,
      );
    }
    if (route == null || material.confirmedRoute == null) {
      return _nodeGateControl(
        theme,
        material,
        label: '先确认路线',
        message: '先采用建议路线，或在右侧详情中选择采购、委外或自制',
        icon: Icons.route_outlined,
      );
    }
    if (makeGated) {
      return _nodeGateControl(
        theme,
        material,
        label: '下层未齐',
        message: '下层物料未齐套，暂不能安排生产，请先处理下层缺料',
        icon: Icons.account_tree_outlined,
      );
    }
    if (!_isExecutableSupplyGroup(group, route)) {
      return _nodeGateControl(
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

  Widget _nodeGateControl(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material, {
    required String label,
    required String message,
    required IconData icon,
  }) => Tooltip(
    message: message,
    child: Semantics(
      container: true,
      enabled: false,
      label: '$label：$message',
      child: Container(
        key: ValueKey('material-bom-gate-${material.materialLineId}'),
        constraints: const BoxConstraints(minWidth: 76, minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: UtenRadius.smAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: UtenSpacing.s4),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    ),
  );

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
      setState(() => _expandedPathGroups.add(group.key));
      context.appInfo('该物料没有建议路线，请先在节点详情中选择路线');
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
        final key = businessIdempotencyKey(
          'material-analysis-notify-chunk',
          [
            current.analysisId,
            current.version,
            current.fingerprint,
            route.wireName,
            ...actionGroupKeys,
            ...materialLineIds,
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
            ? '$message（${groups.length} 条）'
            : '$message（${groups.length} 条，分 ${batches.length} 批完成）',
      );
      return current;
    } catch (error) {
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

  bool _canSelectProduct(ProductionMaterialAnalysisProduct product) {
    if (product.readyNowQty <= 0) return false;
    if (!product.hasBomPolicyError) return true;
    return _canBomOverride &&
        (_bomOverrideReasons[product.analysisLineId]?.trim().isNotEmpty ??
            false);
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

  bool get _hasUnresolvedBomPolicyError {
    final analysis = _analysis;
    if (analysis == null) return false;
    return analysis.products.any(
      (product) =>
          product.hasBomPolicyError &&
          (!_canBomOverride ||
              (_bomOverrideReasons[product.analysisLineId]?.trim().isEmpty ??
                  true)),
    );
  }

  List<MaterialBomOverride> get _bomOverrides => [
    for (final entry in _bomOverrideReasons.entries)
      if (entry.value.trim().isNotEmpty)
        MaterialBomOverride(analysisLineId: entry.key, reason: entry.value),
  ];

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
    if (_hasUnresolvedBomPolicyError) {
      context.appWarning('存在“必须维护 BOM”但未维护的资料异常，请先处理');
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
            bomOverrides: _bomOverrides,
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
      setState(() => _previewingPlan = false);
      context.appError(
        productionErrorMessage(error, fallback: '计划预览失败，请刷新分析后重试'),
        force: true,
      );
      return false;
    }
  }

  Future<void> _generatePlan(List<MaterialAnalysisPlanItemInput> items) async {
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
        false,
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
            items: items,
            bomOverrides: _bomOverrides,
          );
      if (!mounted) return;
      setState(() {
        _generating = false;
        _applyAnalysis(result.analysis);
      });
      context.appSuccess('生产计划已生成并提交审批');
      await _showGeneratedPlans(result.plans);
    } catch (error) {
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

  /// 打开备料计划汇总单预览（当前分析视图直接传入，不重算）。
  void _openSummarySheet() {
    final analysis = _analysis;
    if (analysis == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProductionPlanSummarySheetPage(analysis: analysis),
      ),
    );
  }

  Future<void> _openPlanWizard() async {
    if (!_canGenerate || _busy || _editingPriorities) return;
    if (_dirtyRouteGroups.isNotEmpty) {
      context.appWarning('请先确认物料路线');
      return;
    }
    if (_hasUnresolvedBomPolicyError) {
      context.appWarning('存在“必须维护 BOM”但未维护的资料异常，请先处理');
      return;
    }
    final initialItems = _planItems();
    final analysis = _analysis;
    if (initialItems == null || analysis == null) return;
    final products = {
      for (final product in analysis.products) product.analysisLineId: product,
    };
    final masterNames = ref.read(masterNameServiceProvider);
    // V192 默认车间预填：读取正式排产确认学习出的偏好；seed 显式指定优先。
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
    final result = await Navigator.of(context)
        .push<List<MaterialAnalysisPlanItemInput>>(
          MaterialPageRoute(
            builder: (_) => ProductionPlanWizardPage(
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
    if (!mounted || result == null || result.isEmpty) return;
    final previewPassed = await _previewPlan(result);
    if (!mounted || !previewPassed) return;
    await _generatePlan(result);
  }

  Future<void> _showGeneratedPlans(
    List<ProductionGeneratedPlanRef> plans,
  ) async {
    final valid = plans.where((plan) => plan.planId.isNotEmpty).toList();
    if (valid.isEmpty || !mounted) return;
    if (valid.length == 1) {
      final open = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('生产计划已生成'),
          content: Text(
            '${valid.single.planNo ?? valid.single.planId}\n'
            '页面已刷新，可继续处理其他物料。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('留在物料分析'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('查看计划'),
            ),
          ],
        ),
      );
      if (open == true && mounted) {
        await context.push(RoutePath.productionPlanDetail(valid.single.planId));
      }
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('已生成生产计划'),
        children: [
          for (final plan in valid)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, plan.planId),
              child: ListTile(
                leading: const Icon(Icons.assignment_turned_in_outlined),
                title: Text(plan.planNo ?? plan.planId),
                subtitle: const Text('打开生产计划详情'),
              ),
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
    if (selected != null && mounted) {
      await context.push(RoutePath.productionPlanDetail(selected));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = context.breakpoint.isCompact;
    return Scaffold(
      appBar: UtenAppBar(
        title: '物料分析准备',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.productionSchedule),
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
                      title: Text('计划单预览'),
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
            if (_analysis != null)
              UtenButton(
                key: const Key('material-analysis-summary-sheet'),
                type: UtenButtonType.tonal,
                icon: Icons.summarize_outlined,
                onPressed: _busy ? null : _openSummarySheet,
                child: const Text('计划单预览'),
              ),
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
            UtenButton(
              type: UtenButtonType.tonal,
              icon: Icons.history_rounded,
              onPressed: _busy
                  ? null
                  : () => context.push(RouteName.productionPlanList),
              child: const Text('生产计划历史'),
            ),
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
        child: UtenContentContainer.wide(
          child: _booting
              ? const Center(child: CircularProgressIndicator())
              : _analysis == null
              ? _candidateBody(theme)
              : _analysisBody(theme),
        ),
      ),
      bottomNavigationBar: _analysis == null ? null : _bottomActions(theme),
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
          const SizedBox(height: UtenSpacing.s8),
          Align(
            alignment: Alignment.centerRight,
            child: _candidateStartButton(),
          ),
        ],
      ),
    );
  }

  Widget _candidateStartButton() => UtenButton(
    key: const Key('material-analysis-start'),
    size: UtenButtonSize.large,
    icon: Icons.insights_outlined,
    isLoading: _previewingAnalysis,
    onPressed:
        !_canManage ||
            (_sourceQtyControllers.isEmpty && _manualSources.isEmpty) ||
            _previewingAnalysis
        ? null
        : _startCandidateAnalysis,
    onDisabledTap: !_canManage
        ? () => context.appWarning('没有新建或刷新物料分析权限')
        : null,
    child: const Text('联合分析所选产品'),
  );

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
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
          child: SizedBox(
            width: double.infinity,
            child: _candidateStartButton(),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s8)),
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
              ? '其他需求（返工 / 试制 / 样品 / 备库）'
              : '其他需求（已加入 ${_manualSources.length} 项）',
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
                          helperText: '本次分析数量',
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
            '结果先显示可生产产品和缺料任务，可搜索或切换“全部 BOM”。'
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
                    '手工计划（返工 / 试制 / 样品 / 备库）',
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
                      helperText: '同一需求请始终使用同一个编号',
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
    final selectable = (line.remainingQty ?? 0) > 0;
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
                      helperText: '本次分析数量',
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
    return CustomScrollView(
      key: const Key('material-analysis-results'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          sliver: SliverToBoxAdapter(child: _analysisHeader(theme, analysis)),
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
            padding: const EdgeInsets.only(
              top: UtenSpacing.s12,
              bottom: UtenSpacing.s12,
            ),
            sliver: SliverToBoxAdapter(
              child: _planPreviewCard(theme, _planPreview!),
            ),
          )
        else
          const SliverPadding(
            padding: EdgeInsets.only(bottom: UtenSpacing.s16),
          ),
      ],
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
                ChoiceChip(
                  key: ValueKey('material-bom-view-${mode.name}'),
                  selected: _bomViewMode == mode,
                  onSelected: (_) => setState(() {
                    _bomViewMode = mode;
                    _bomProductVisibleLimit = _bomProductPageSize;
                  }),
                  avatar: Icon(mode.icon, size: 18),
                  label: Text('${mode.label} ${_bomModeCount(analysis, mode)}'),
                  labelStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
              // 排布切换：按产品看 BOM 树（默认）/ 按物料汇总缺料。
              // 多产品联合分析时物料行非常多，按物料汇总把同一物料跨产品
              // 聚成一行，是给采购/委外下单用的决策视图；任务身份不合并。
              ChoiceChip(
                key: const ValueKey('material-bom-layout-product'),
                selected: !_bomAggregateByMaterial,
                onSelected: _bomAggregateByMaterial
                    ? (_) => setState(() => _bomAggregateByMaterial = false)
                    : null,
                avatar: const Icon(Icons.account_tree_outlined, size: 18),
                label: const Text('按产品看'),
                labelStyle: const TextStyle(fontWeight: FontWeight.w700),
              ),
              ChoiceChip(
                key: const ValueKey('material-bom-layout-material'),
                selected: _bomAggregateByMaterial,
                onSelected: _bomAggregateByMaterial
                    ? null
                    : (_) => setState(() => _bomAggregateByMaterial = true),
                avatar: const Icon(Icons.summarize_outlined, size: 18),
                label: const Text('按物料汇总'),
                labelStyle: const TextStyle(fontWeight: FontWeight.w700),
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
                  '批量选择（整次分析）',
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
    final entries = <_BomTreeEntry>[const _BomIntroEntry()];
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
    if (entries.length == 1) entries.add(const _BomEmptyEntry());
    return SliverList(
      key: const Key('material-bom-tree'),
      delegate: SliverChildBuilderDelegate((_, index) {
        final entry = entries[index];
        return switch (entry) {
          _BomIntroEntry() => _bomTreeIntro(theme),
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
      margin: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      padding: const EdgeInsets.all(UtenSpacing.s12),
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
                      '${aggregate.spec?.isNotEmpty == true ? '（${aggregate.spec}）' : ''}',
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
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
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
          const SizedBox(height: UtenSpacing.s8),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: UtenRadius.smAll,
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 8,
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
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s8),
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
              if (group.actionable)
                _nodeSelectionControl(theme, material, group, route, selected),
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
          const SizedBox(height: UtenSpacing.s4),
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
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

  Widget _bomTreeIntro(ThemeData theme) => Container(
    key: const Key('material-dependency-section'),
    margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
    padding: const EdgeInsets.all(UtenSpacing.s12),
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: LayoutBuilder(
      builder: (_, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.account_tree_outlined, size: 20),
              SizedBox(width: UtenSpacing.s8),
              Expanded(child: Text('BOM 物料任务（按产品分组，可按产品或分支折叠）')),
            ],
          ),
          if (constraints.maxWidth >= 900) ...[
            const SizedBox(height: UtenSpacing.s8),
            const Row(
              children: [
                Expanded(flex: 5, child: Text('物料 / 路线')),
                Expanded(child: Text('需求')),
                Expanded(child: Text('分配')),
                Expanded(child: Text('现货')),
                Expanded(child: Text('缺口')),
                Expanded(flex: 2, child: Text('状态')),
                Expanded(flex: 2, child: Text('操作')),
                SizedBox(width: UtenSpacing.s8),
              ],
            ),
          ],
        ],
      ),
    ),
  );

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
        label: Text('继续显示下一批产品（还有 $remainingProducts 个）'),
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
      constraints: const BoxConstraints(minHeight: 56),
      margin: const EdgeInsets.only(
        top: UtenSpacing.s8,
        bottom: UtenSpacing.s4,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
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
    final noWarehouseStock = material.availableQty <= 0;
    final foreground = selected ? Colors.white : null;
    final onSurfaceVar = selected
        ? Colors.white70
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      key: ValueKey(
        'material-bom-node-${material.nodeKey ?? material.materialLineId}',
      ),
      constraints: const BoxConstraints(minHeight: 60),
      margin: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      padding: const EdgeInsets.only(
        left: UtenSpacing.s8,
        right: UtenSpacing.s12,
        top: UtenSpacing.s8,
        bottom: UtenSpacing.s8,
      ),
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
        builder: (_, constraints) {
          final compact = constraints.maxWidth < 900;
          // 行首：加大缩进 + 层级色带 + 类型角标 + 可执行节点勾选框 + 物料标识。
          // 缩进与色带两级冗余表达层级（另有「层级 N」文字），方便现场
          // 一眼分清哪个是哪个的子组件。
          final identity = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width:
                    material.level.clamp(0, compact ? 4 : 8) *
                    (compact ? 10 : 20),
              ),
              if (material.level >= 1) ...[
                Container(
                  width: 5,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _levelBandColor(
                      theme,
                      material.level,
                    ).withValues(alpha: selected ? 0.95 : 0.75),
                    borderRadius: UtenRadius.smAll,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s4),
              ],
              SizedBox(
                width: 48,
                height: 48,
                child: hasChildren && material.nodeKey != null
                    ? IconButton(
                        key: ValueKey(
                          'material-bom-branch-toggle-${material.nodeKey}',
                        ),
                        tooltip:
                            _collapsedBomBranches.contains(material.nodeKey)
                            ? '展开下级物料'
                            : '折叠下级物料',
                        onPressed: () => setState(() {
                          final key = material.nodeKey!;
                          if (!_collapsedBomBranches.add(key)) {
                            _collapsedBomBranches.remove(key);
                          }
                        }),
                        icon: Icon(
                          _collapsedBomBranches.contains(material.nodeKey)
                              ? Icons.chevron_right_rounded
                              : Icons.expand_more_rounded,
                          color: foreground ?? onSurfaceVar,
                        ),
                      )
                    : Icon(
                        material.parentNodeKey == null
                            ? Icons.account_tree_outlined
                            : Icons.subdirectory_arrow_right_rounded,
                        size: 20,
                        color: foreground ?? onSurfaceVar,
                      ),
              ),
              const SizedBox(width: UtenSpacing.s4),
              _typeBadge(theme, route, onColor: selected ? Colors.white : null),
              const SizedBox(width: UtenSpacing.s4),
              if (actionable)
                _nodeSelectionControl(theme, material, group, route, selected),
              const SizedBox(width: UtenSpacing.s4),
              Expanded(
                child: _materialIdentity(theme, group, foreground: foreground),
              ),
              _nodeDetailsToggle(theme, group, foreground: foreground),
            ],
          );
          final shortageStyle = TextStyle(
            color: selected
                ? Colors.white
                : material.shortageQty > 0
                ? theme.colorScheme.error
                : null,
            fontWeight: FontWeight.w700,
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                identity,
                const SizedBox(height: UtenSpacing.s8),
                Wrap(
                  spacing: UtenSpacing.s12,
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
                      noWarehouseStock
                          ? '无现货'
                          : '现货 ${_qty(material.availableQty)}',
                      style: TextStyle(
                        color: selected
                            ? Colors.white
                            : noWarehouseStock
                            ? theme.colorScheme.error
                            : null,
                        fontWeight: noWarehouseStock
                            ? FontWeight.w700
                            : FontWeight.normal,
                      ),
                    ),
                    Text(
                      shortage ? '缺 ${_qty(material.shortageQty)}' : '已齐',
                      style: shortageStyle,
                    ),
                    _statusLabel(theme, displayStatus),
                  ],
                ),
                _nodeCoverageBar(theme, material, selected: selected),
                _borrowBadges(theme, material, selected: selected),
                const SizedBox(height: UtenSpacing.s4),
                _nodePrimaryAction(theme, group, route, selected: selected),
                if (_expandedPathGroups.contains(group.key))
                  _nodeDetails(theme, group),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(flex: 5, child: identity),
                  Expanded(
                    child: Text(
                      _qty(material.requiredQty),
                      style: TextStyle(color: foreground),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _qty(material.allocatedAvailableQty),
                      style: TextStyle(color: foreground),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      noWarehouseStock ? '无现货' : _qty(material.availableQty),
                      style: TextStyle(
                        color: selected
                            ? Colors.white
                            : noWarehouseStock
                            ? theme.colorScheme.error
                            : null,
                        fontWeight: noWarehouseStock
                            ? FontWeight.w700
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _qty(material.shortageQty),
                      style: shortageStyle,
                    ),
                  ),
                  Expanded(flex: 2, child: _statusLabel(theme, displayStatus)),
                  Expanded(
                    flex: 2,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _nodePrimaryAction(
                        theme,
                        group,
                        route,
                        selected: selected,
                      ),
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                ],
              ),
              _nodeCoverageBar(theme, material, selected: selected),
              _borrowBadges(theme, material, selected: selected),
              if (_expandedPathGroups.contains(group.key))
                _nodeDetails(theme, group),
            ],
          );
        },
      ),
    );
  }

  /// 层级色带颜色：同一深度同一颜色，配合加大的缩进与「层级 N」文字，
  /// 三层冗余表达层级，方便现场一眼分清哪个是哪个的子组件。
  Color _levelBandColor(ThemeData theme, int level) {
    final scheme = theme.colorScheme;
    final palette = <Color>[
      scheme.primary,
      scheme.tertiary,
      scheme.secondary,
      Colors.orange.shade700,
      Colors.purple.shade400,
      Colors.teal.shade600,
    ];
    final index = (level - 1).clamp(0, palette.length - 1);
    return palette[index];
  }

  /// 节点备料进度条。口径 = 本批需求中被合格现货/分配覆盖的比例
  /// （需求 - 缺口）÷ 需求，与右侧状态文字严格同源：已齐套/已入库即 100%。
  /// 不混用报工 fqty / 成品入库 iqty；自制件排产后的生产进度仍由状态
  /// 文字与子计划承担。本批无需补货（requiredQty<=0）的节点不显示进度条。
  Widget _nodeCoverageBar(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material, {
    required bool selected,
  }) {
    if (material.requiredQty <= 0) return const SizedBox.shrink();
    final covered = (material.requiredQty - material.shortageQty).clamp(
      0.0,
      material.requiredQty,
    );
    final ratio = (covered / material.requiredQty).clamp(0.0, 1.0);
    final hasShortage = material.shortageQty > 0;
    final barColor = selected
        ? Colors.white
        : !hasShortage
        ? theme.colorScheme.primary
        : ratio <= 0
        ? theme.colorScheme.error
        : theme.colorScheme.tertiary;
    final textColor = selected
        ? Colors.white
        : hasShortage && ratio <= 0
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      key: ValueKey('material-node-progress-${material.materialLineId}'),
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: UtenRadius.smAll,
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 8,
                backgroundColor: selected
                    ? Colors.white24
                    : theme.colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(barColor),
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Text(
            '备料 ${(ratio * 100).toStringAsFixed(0)}%'
            ' · 已备 ${_qty(covered)}/${_qty(material.requiredQty)}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
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
    if (material.borrowRefs.isEmpty) return const SizedBox.shrink();
    final chips = <Widget>[];
    for (final ref in material.borrowRefs) {
      final inbound = ref.isInbound;
      final effective = ref.qty > 0;
      final color = selected
          ? Colors.white
          : !effective
          ? theme.colorScheme.onSurfaceVariant
          : inbound
          ? theme.colorScheme.primary
          : Colors.orange.shade800;
      final label = !effective
          ? '调拨申请 ${_qty(ref.requestedQty)} 件暂未生效'
          : inbound
          ? '已调入 ${_qty(ref.qty)} 件 · 来自 ${ref.counterpartProduct ?? '其它产品'}'
          : '已被调走 ${_qty(ref.qty)} 件 · 调给 ${ref.counterpartProduct ?? '其它产品'}';
      chips.add(
        Container(
          key: ValueKey(
            'material-borrow-ref-${ref.direction}-${material.materialLineId}-${ref.borrowId}',
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s8,
            vertical: UtenSpacing.s4,
          ),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white24
                : color.withValues(alpha: effective ? 0.12 : 0.07),
            borderRadius: UtenRadius.smAll,
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                inbound ? Icons.call_received_rounded : Icons.call_made_rounded,
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
      context.appInfo('没有其它产品缺这种料，无需调拨');
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
        helperText: '撤销后借出方恢复分配、借入方重新出现缺口。请填写撤销原因。',
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

  /// 节点详情内的借用区：逐笔借用明细（可撤销）+ 调出入口。
  Widget _nodeBorrowSection(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
  ) {
    final refs = material.borrowRefs;
    final canBorrowOut = _canBorrowOut(material);
    if (refs.isEmpty && !canBorrowOut) return const SizedBox.shrink();
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
                      type: UtenButtonType.ghost,
                      icon: Icons.undo_rounded,
                      onPressed: _busy ? null : () => _revokeBorrow(ref),
                      child: const Text('撤销'),
                    ),
                ],
              ),
            ),
          if (canBorrowOut)
            Align(
              alignment: Alignment.centerLeft,
              child: UtenButton(
                key: ValueKey(
                  'material-borrow-start-${material.materialLineId}',
                ),
                type: UtenButtonType.tonal,
                icon: Icons.swap_horiz_rounded,
                onPressed: _busy ? null : () => _showBorrowDialog(material),
                child: const Text('调给其它产品'),
              ),
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

  Widget _productSection(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
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
        const SizedBox(height: UtenSpacing.s8),
        LayoutBuilder(
          builder: (_, constraints) {
            final compact = constraints.maxWidth < UtenBreakpoints.mediumStart;
            final width = compact ? constraints.maxWidth : 360.0;
            return Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                for (final product in visibleProducts)
                  SizedBox(width: width, child: _productCard(theme, product)),
              ],
            );
          },
        ),
        if (remainingProducts > 0) ...[
          const SizedBox(height: UtenSpacing.s8),
          Align(
            child: UtenButton(
              key: const Key('material-analysis-show-more-products'),
              type: UtenButtonType.tonal,
              icon: Icons.expand_more_rounded,
              onPressed: () => setState(() => _productVisibleLimit += 60),
              child: Text('继续显示下一批（还有 $remainingProducts 个）'),
            ),
          ),
        ],
      ],
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
                  child: Checkbox(
                    key: ValueKey(
                      'material-analysis-product-select-${product.analysisLineId}',
                    ),
                    value: selected,
                    onChanged: !selectable || _busy
                        ? null
                        : (value) => _toggleProduct(product, value == true),
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
            if (product.hasBomPolicyError) ...[
              const SizedBox(height: UtenSpacing.s8),
              _statusLabel(
                theme,
                _StatusView(
                  '资料异常：该产品要求 BOM，但未维护有效 BOM',
                  Icons.report_problem_outlined,
                  selected ? Colors.white : theme.colorScheme.error,
                ),
              ),
              if (_canBomOverride)
                Align(
                  alignment: Alignment.centerLeft,
                  child: UtenButton(
                    key: Key('bom-override-${product.analysisLineId}'),
                    type: UtenButtonType.ghost,
                    icon: Icons.edit_note_outlined,
                    onPressed: _busy ? null : () => _promptBomOverride(product),
                    child: Text(
                      _bomOverrideReasons.containsKey(product.analysisLineId)
                          ? '已填写继续原因'
                          : '填写原因继续',
                    ),
                  ),
                ),
            ],
            const SizedBox(height: UtenSpacing.s8),
            _productShortageSummary(theme, product, selected: selected),
            _producibleHeadline(theme, product, selected: selected),
            _readinessBlockerHint(theme, product, selected: selected),
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
                  helperText: '最多 ${_qty(product.readyNowQty)} 个',
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

  /// 产品卡缺口摘要：不展开 BOM 就能看出这个产品还缺几种料、其中几条
  /// 路线还没确认，帮助计划员决定先处理谁。条数来自服务端逐路径快照，
  /// 这里只统计展示，不重算缺口；无缺口时占位收起，由可生产标题表达结论。
  Widget _productShortageSummary(
    ThemeData theme,
    ProductionMaterialAnalysisProduct product, {
    required bool selected,
  }) {
    final analysis = _analysis;
    if (analysis == null) return const SizedBox.shrink();
    final nodes =
        _analysisIndexes(analysis).materialsByProduct[product.analysisLineId] ??
        const <ProductionMaterialAnalysisMaterial>[];
    final shortageNodes = nodes
        .where((node) => node.shortageQty > 0)
        .toList(growable: false);
    if (shortageNodes.isEmpty) return const SizedBox.shrink();
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
              '还缺 ${shortageNodes.length} 种料'
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
    final maxQty = product.readyNowQty;
    final producible = maxQty > 0;
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
                  producible ? '最多可生产 ${_qty(maxQty)} 个' : '物料不足，暂不可生产',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '齐套 ${(ratio * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
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
    if (product.readyNowQty > 0) return const SizedBox.shrink();
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
    final accent = selected ? Colors.white70 : theme.colorScheme.tertiary;
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s4),
      child: Text(
        '等待：${parts.join(' · ')} · $hint',
        style: theme.textTheme.bodySmall?.copyWith(color: accent),
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
      '（仅反映备料进度，不计入本批上限）',
      style: theme.textTheme.bodySmall?.copyWith(color: secondary),
    );
  }

  Widget _materialIdentity(
    ThemeData theme,
    _MaterialGroup group, {
    Color? foreground,
  }) {
    final material = group.representative;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${material.goodsName ?? material.goodsCode ?? '未命名物料'}'
          '${material.spec?.isNotEmpty == true ? '（${material.spec}）' : ''}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          [
            '层级 ${material.level}',
            material.goodsCode,
            material.colorName,
          ].whereType<String>().join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: foreground ?? theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _nodeDetailsToggle(
    ThemeData theme,
    _MaterialGroup group, {
    Color? foreground,
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
      child: TextButton.icon(
        key: ValueKey(
          'material-node-details-toggle-${material.materialLineId}',
        ),
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
          foregroundColor: foreground,
        ),
        onPressed: toggleDetails,
        icon: Icon(
          expanded ? Icons.expand_less_rounded : Icons.info_outline_rounded,
          size: 18,
        ),
        label: Text(expanded ? '收起' : '详情'),
      ),
    );
  }

  Widget _nodeDetails(ThemeData theme, _MaterialGroup group) {
    final material = group.representative;
    final detailFacts = <String>[
      if (material.reservedQty > 0) '已预留 ${_qty(material.reservedQty)}',
      if (material.safetyStockQty > 0) '安全库存 ${_qty(material.safetyStockQty)}',
      if (material.inboundQty > 0) '在途 ${_qty(material.inboundQty)}',
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
          if (group.actionable)
            _routeControl(group)
          else
            _inactiveNodeHint(theme, material, selected: false),
          _nodeBorrowSection(theme, material),
        ],
      ),
    );
  }

  Widget _routeControl(_MaterialGroup group, {bool selected = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<MaterialSupplyRoute>(
          key: ValueKey(
            'route-${group.key}-${_routeDraft[group.key]?.wireName ?? 'EMPTY'}'
            '-$_routeControlRevision',
          ),
          initialValue: _routeDraft[group.key],
          isExpanded: true,
          decoration: InputDecoration(
            labelText: '路线',
            filled: selected,
            fillColor: selected ? Colors.white : null,
          ),
          items: [
            for (final route in MaterialSupplyRoute.values)
              DropdownMenuItem(value: route, child: Text(route.label)),
          ],
          onChanged: !_canRoute || _busy
              ? null
              : (route) => _setRoute(group, route),
        ),
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s4),
          child: Text(
            '建议：${group.representative.sourceSuggestion?.label ?? '需人工判断'}'
            '${_routeReasons[group.key]?.isNotEmpty == true ? ' · 已填覆盖原因' : ''}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: selected
                  ? Colors.white
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
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

  Widget _nodePrimaryAction(
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
      return const SizedBox.shrink();
    }
    if (material.requiredQty <= 0) {
      return const SizedBox.shrink();
    }
    if (material.shortageQty <= 0) {
      return const SizedBox.shrink();
    }
    if (!group.actionable) {
      return const SizedBox.shrink();
    }
    if (material.confirmedRoute == null) {
      final suggestion = material.sourceSuggestion;
      if (suggestion == null) {
        return OutlinedButton.icon(
          key: ValueKey('material-open-route-${material.materialLineId}'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 48),
            foregroundColor: selected ? UtenColors.deepGreen : null,
            backgroundColor: selected ? Colors.white : null,
          ),
          onPressed: _canRoute && !_busy
              ? () => setState(() => _expandedPathGroups.add(group.key))
              : null,
          icon: const Icon(Icons.alt_route_rounded),
          label: const Text('选择路线'),
        );
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
      return const SizedBox.shrink();
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
    // 已下达通知 → 等待入库 / 生产中 / 已入库 / 已完工。
    // 用 shortageQty 作入库/完工的权威信号（refresh 后缺口归零 = 已到货）。
    if (notified != null) {
      final route = notified.target;
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
          '已入库',
          Icons.check_circle_outline_rounded,
          theme.colorScheme.primary,
        );
      }
      final suffix =
          (notified.documentNo == null || notified.documentNo!.isEmpty)
          ? ''
          : ' · ${notified.documentNo}';
      return _StatusView(
        route == MaterialSupplyRoute.subcontract
            ? '等待委外入库$suffix'
            : '等待采购入库$suffix',
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
        Icons.account_tree_outlined,
        theme.colorScheme.tertiary,
      );
    }
    if (material.shortageQty > 0) {
      return _StatusView(
        '待通知',
        Icons.notifications_active_outlined,
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

  /// 物料类型三色角标（采购/委外/自制/待定）。
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
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: onColor == null ? color.withValues(alpha: 0.14) : color,
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
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

  Widget _bottomActions(ThemeData theme) {
    final buttons = <Widget>[
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
          type: UtenButtonType.tonal,
          size: UtenButtonSize.large,
          icon: Icons.done_all_rounded,
          isLoading: _savingRoutes,
          onPressed: _busy ? null : _acceptAllSuggestedRoutes,
          child: Text('采纳建议路线（$_unconfirmedSuggestedRouteCount）'),
        ),
      if (_dirtyRouteGroups.isNotEmpty)
        UtenButton(
          type: UtenButtonType.tonal,
          size: UtenButtonSize.large,
          icon: Icons.rule_folder_outlined,
          isLoading: _savingRoutes,
          onPressed: !_canRoute || _busy ? null : _saveRoutes,
          child: Text('确认路线（${_dirtyRouteGroups.length}）'),
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
          child: Text('$_planActionLabel（${_selectedPlanLineIds.length}）'),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: Material(
        color: theme.colorScheme.surface,
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < UtenBreakpoints.mediumStart;
              return compact
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (
                          var index = 0;
                          index < buttons.length;
                          index++
                        ) ...[
                          SizedBox(
                            width: double.infinity,
                            child: buttons[index],
                          ),
                          if (index != buttons.length - 1)
                            const SizedBox(height: UtenSpacing.s8),
                        ],
                      ],
                    )
                  : Row(
                      children: [
                        const Spacer(),
                        for (final button in buttons) ...[
                          button,
                          const SizedBox(width: UtenSpacing.s8),
                        ],
                      ],
                    );
            },
          ),
        ),
      ),
    );
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

final class _BomIntroEntry extends _BomTreeEntry {
  const _BomIntroEntry();
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

enum _ReadinessState { ready, waitingMake, waitingSupply, waiting }

enum _BomViewMode {
  shortage('只看缺料', Icons.error_outline_rounded),
  unconfirmed('待确认路线', Icons.help_outline_rounded),
  all('全部 BOM', Icons.account_tree_outlined);

  const _BomViewMode(this.label, this.icon);

  final String label;
  final IconData icon;
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
            '（不超过借出方已分配量，也不超过对方缺口）',
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
      title: const Text('调给其它产品'),
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
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '可调上限：已分配 ${widget.qtyText(widget.from.allocatedAvailableQty)} 件',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '调给哪个产品（只列出缺这种料的）：',
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
                  labelText: '调拨数量（件）',
                  helperText: target == null
                      ? '先选择调给哪个产品'
                      : '最多 ${widget.qtyText(_maxQty)} 件',
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
                  labelText: '调拨原因（必填）',
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
          child: const Text('确认调拨'),
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
    required this.helperText,
    required this.confirmLabel,
  });

  final String title;
  final Key fieldKey;
  final String initialValue;
  final String helperText;
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
        labelText: '原因（必填）',
        helperText: widget.helperText,
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
