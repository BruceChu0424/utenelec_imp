import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/feedback/uten_segment_badge_label.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../features/basic_data/models/master_facet.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/uten_tree_row_projection.dart';
import '../../../shared/widgets/uten_tree_table_cell.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../department/models/department_node.dart';
import '../../department/repositories/department_repository.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/material_cascade_math.dart';
import '../models/production_material_analysis.dart';
import '../models/material_future_transfer.dart';
import '../models/material_aggregate_order.dart';
import '../models/material_preparation_draft_budget.dart';
import '../models/material_analysis_ownership_overlay.dart';
import '../models/material_future_transfer_progress.dart';
import '../models/production_flow_stage.dart';
import '../models/production_work_card.dart';
import '../providers/material_analysis_warehouse_prefs_provider.dart';
import '../providers/production_execution_refresh.dart';
import '../repositories/production_repository.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../widgets/material_reallocation_dialog.dart';
import '../widgets/material_transfer_launcher.dart';
import '../widgets/material_priority_replenishment_dialog.dart';
import '../widgets/material_shared_future_claim_dialog.dart';
import '../widgets/material_future_transfer_history.dart';
import '../widgets/production_execution_card_print_preview.dart';
import '../widgets/production_flow_stage_cell.dart';
import '../widgets/material_preparation_status_style.dart';
import '../widgets/material_borrow_dialog.dart';
import '../widgets/material_required_reason_dialog.dart';
import '../widgets/material_supply_progress_dialog.dart';
import '../widgets/material_supply_submit_confirm.dart';
import '../widgets/material_manual_demand_editor.dart';
import '../widgets/material_preparation_route_card.dart';
import '../widgets/production_overproduction_rate_field.dart';
import '../widgets/bom_usage_basis_text.dart';

part 'material_analysis_bom_tree.dart';
part 'material_analysis_borrow.dart';
part 'material_analysis_bucket_detail.dart';
part 'material_analysis_candidates.dart';
part 'material_analysis_child_shortage.dart';
part 'material_analysis_child_shortage_page.dart';
part 'material_analysis_plan_actions.dart';
part 'material_analysis_product_tasks.dart';
part 'material_analysis_material_table.dart';
part 'material_analysis_aggregate_table.dart';
part 'material_analysis_aggregate_submission.dart';
part 'material_analysis_draft_budget.dart';
part 'material_analysis_order_page.dart';
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

/// 套用分析快照后跟着要取的只读附带数据 (2026-09-27 进页只整页重画一次)。
/// 四类读取统一走 [_MaterialAnalysisPageBase._requestCompanionReads]: 同一轮里提出的
/// 合成一批并发请求, 全部回来后只 setState 一次; 各自的实现在负责它的那一层。
enum _CompanionRead {
  /// 在途调拨进度 (GET /{id}/future-transfers), 实现在页面基类。
  futureTransfers,

  /// 车间在催清单 (GET /{id}/workshop-urges), 实现在补下层物料层。
  workshopUrges,

  /// 批量可调拨量 (GET /{id}/transferable-in-summary), 实现在主表层。
  transferableIn,

  /// 生产车间 / 负责人默认值 (组织树 + GET /default-workshops), 实现在主表层。
  assignmentDefaults,
}

abstract class _MaterialAnalysisPageBase
    extends ConsumerState<ProductionMaterialAnalysisPage> {
  static const int _maxAnalysisItems = 500;
  static const int _requestChunkSize = 500;
  static const int _maxPlansPerPrintJob = 50;
  static const int _maxConcurrentPrintLoads = 5;
  static const Duration _analysisPollInterval = Duration(seconds: 45);

  ProductionMaterialAnalysisView? _analysis;
  final _ownerReadGuard = LatestRequestGuard();
  final _ownerReadTokens = Expando<int>();
  bool _savingGoodsOwnership = false;
  bool _ownerRefreshQueued = false;
  final Set<BuildContext> _preparationReadContexts = {};
  int _preparationSubmissionScopes = 0;
  bool _deferredFutureTransferRead = false;
  bool get _preparationSubmissionActive => _preparationSubmissionScopes > 0;
  void _cancelPreparationEditorPreview();
  void _flushDeferredAssignmentRead();

  Future<T> _withPreparationSubmissionScope<T>(
    Future<T> Function() command,
  ) async {
    final outermost = _preparationSubmissionScopes++ == 0;
    final releaseBadges = outermost
        ? ref.read(badgeSummaryProvider.notifier).holdRefreshes()
        : null;
    if (outermost) _cancelPreparationEditorPreview();
    try {
      return await command();
    } finally {
      _preparationSubmissionScopes--;
      if (outermost) {
        releaseBadges?.call();
        if (mounted) {
          _flushDeferredAssignmentRead();
          if (_deferredFutureTransferRead && _analysis != null) {
            _deferredFutureTransferRead = false;
            _requestCompanionReads(const [_CompanionRead.futureTransfers]);
          }
        }
      }
    }
  }

  Future<ProductionMaterialAnalysisView> _readMaterialAnalysisDetail(
    String id,
  ) async {
    final token = _ownerReadGuard.begin();
    final view = await ref
        .read(productionPlanRepositoryProvider)
        .materialAnalysisDetail(id);
    _ownerReadTokens[view] = token;
    return view;
  }

  void _acceptAnalysisOwnership(
    ProductionMaterialAnalysisView view, {
    required bool confirmedRead,
  });
  void _invalidateOwnerAssignmentDefaults(Set<String> goodsIds);
  void _applyAnalysisKeepingPreparationEditing(
    ProductionMaterialAnalysisView view,
  );

  ProductionMaterialAnalysisView _prepareAnalysisOwnership(
    ProductionMaterialAnalysisView view,
  ) {
    final token = _ownerReadTokens[view];
    final current = _analysis;
    final confirmed = token != null && _ownerReadGuard.isCurrent(token);
    // An older GET may still contain useful quantity facts. It must not revert
    // a later master-data read or a successfully saved ownership edit.
    if (token != null && !confirmed && current?.analysisId == view.analysisId) {
      view = view.withOwnershipFrom(current!);
    }
    _acceptAnalysisOwnership(view, confirmedRead: confirmed);
    return view;
  }

  void _refreshAfterOwnershipWrite() {
    _ownerReadGuard.begin();
    _ownerRefreshQueued = true;
    unawaited(_reloadAnalysisSilently(protectUnsavedEditing: true));
  }

  bool? _preparationApproveChoice;
  bool get _preparationApproveNow =>
      _permissions.contains(Perm.productionPlanApprove) &&
      (_preparationApproveChoice ?? true);
  final Map<String, ProductionGeneratedPlanRef> _preparationPlanResults = {};
  List<MaterialFutureTransferRecord> _futureTransferRecords = const [];
  Map<String, List<MaterialFutureTransferRecord>> _futureTransferByMaterial =
      const {};
  String? _futureTransferReadScope;
  String? _futureTransferError;
  int _futureTransferRequest = 0;

  // ===== 附带读取的公共装载器 (2026-09-27 进页只整页重画一次) =====
  //
  // 在途调拨、车间在催、可调拨量、车间/负责人默认值原来各自回来各 setState 一次,
  // 进页数据到达后接连 5-6 次整页重画。现在统一走这里: 同一轮里提出的读取合成一批
  // 并发请求, 全部回来后只 setState 一次。每个读取返回「套用动作」, 自带作用域 /
  // 代际守卫, 在合批套用那一刻再核对一次, 迟到的结果直接丢弃。
  final Set<_CompanionRead> _pendingCompanionReads = {};
  bool _companionReadsScheduled = false;

  /// 登记要取的附带数据; 本轮 (同一个微任务之前) 提出的所有读取合成一批。
  void _requestCompanionReads(Iterable<_CompanionRead> reads) {
    _pendingCompanionReads.addAll(reads);
    if (_companionReadsScheduled || _pendingCompanionReads.isEmpty) return;
    _companionReadsScheduled = true;
    scheduleMicrotask(() {
      _companionReadsScheduled = false;
      final batch = {..._pendingCompanionReads};
      _pendingCompanionReads.clear();
      final view = _analysis;
      if (!mounted || view == null) return;
      unawaited(
        _runCompanionReads([
          for (final read in batch) _companionRead(read, view),
        ]),
      );
    });
  }

  /// 一类附带读取的实现: 返回要在合批 setState 里执行的套用动作, null = 不用套用
  /// (无权限、作用域没变、被写命令推迟等)。各层只认自己负责的那几类, 其余交给上一层。
  Future<VoidCallback?> _companionRead(
    _CompanionRead read,
    ProductionMaterialAnalysisView view,
  ) async => switch (read) {
    _CompanionRead.futureTransfers => await _fetchFutureTransfers(view),
    _ => null,
  };

  /// 并发执行一批附带读取, 全部回来后在同一次 setState 里套用。直接 await 它的调用方
  /// (比如下单前必须等到车间默认值) 也走这里, 保证只有一套套用口径。
  Future<void> _runCompanionReads(Iterable<Future<VoidCallback?>> reads) async {
    final results = await Future.wait([
      for (final read in reads)
        read.then<VoidCallback?>((apply) => apply, onError: (_) => null),
    ]);
    final applies = results.whereType<VoidCallback>().toList(growable: false);
    if (applies.isEmpty) return;
    if (!mounted) {
      // 页面已销毁: 仍执行套用动作里的收尾 (加载标记复位、等待者放行), 不再重画。
      for (final apply in applies) {
        apply();
      }
      return;
    }
    setState(() {
      for (final apply in applies) {
        apply();
      }
    });
    materialDetailRevision.value++;
  }

  Future<VoidCallback?> _fetchFutureTransfers(
    ProductionMaterialAnalysisView view,
  ) async {
    if (!mounted ||
        !identical(_analysis, view) ||
        !view.allowedActions.contains('VIEW_FUTURE_TRANSFERS')) {
      return null;
    }
    if (_preparationSubmissionActive) {
      _deferredFutureTransferRead = true;
      return null;
    }
    final request = ++_futureTransferRequest;
    final scope = _sessionScopeKey();
    bool current() =>
        mounted &&
        request == _futureTransferRequest &&
        _analysis?.analysisId == view.analysisId &&
        scope == _sessionScopeKey();
    try {
      final records = await ref
          .read(productionPlanRepositoryProvider)
          .materialFutureTransfers(analysisId: view.analysisId);
      return () {
        if (!current()) return;
        _futureTransferRecords = records;
        _futureTransferByMaterial = MaterialFutureTransferProgress.index(
          view.analysisId,
          records,
        );
        _futureTransferReadScope = scope;
        _futureTransferError = null;
      };
    } catch (_) {
      return () {
        if (current()) _futureTransferError = '在途调拨进度暂不可用，请刷新核对';
      };
    }
  }

  /// 账号 / 模拟身份 / 权限集一变: 在途调拨按新会话重取; 可调拨量与车间默认值
  /// 各自带会话作用域键, 作用域没变的读取直接跳过, 变了的与在途调拨合成一批。
  void _reloadCompanionScopes() {
    final reads = <_CompanionRead>[
      _CompanionRead.transferableIn,
      _CompanionRead.assignmentDefaults,
    ];
    if (_futureTransferReadScope != _sessionScopeKey()) {
      setState(() {
        ++_futureTransferRequest;
        _futureTransferRecords = const [];
        _futureTransferByMaterial = const {};
        _futureTransferError = null;
        _futureTransferReadScope = null;
      });
      reads.add(_CompanionRead.futureTransfers);
    }
    if (_analysis != null) _requestCompanionReads(reads);
  }

  MaterialAnalysisSalesCandidatePage? _candidatePage;
  String? _warehouseId;
  final Set<String> _warehouseIds = {};
  String? _error;
  String? _serverRefreshNotice;
  bool _booting = true;

  /// 带着来源进页 (排产看板「联合分析所选」) 时由进页流程自动发起的第一次分析。
  /// 只有这种情况用整页进度卡代替候选区 (候选表尚未加载, 否则会闪一张空表);
  /// 在新建页自己点「联合分析」时保留已填内容只读显示 (ADR-130), 只在按钮上转圈。
  bool _autoPreviewFromSeed = false;
  bool _loadingCandidates = false;
  final _candidateRequests = LatestRequestGuard();
  bool _previewingAnalysis = false;
  bool _savingRoutes = false;
  bool _savingPriorities = false;
  bool _cancellingAnalysis = false;
  bool _cancellingAction = false;
  bool _claimingSharedFuture = false;
  bool _borrowing = false;
  bool _generating = false;

  /// 「下达进行中」的对外广播：分桶详情页是独立 widget，宿主 setState 通知不到它，
  /// 但它要在**自己页面上**盖同一张进度遮罩（2026-09-11 起不再先 pop 回宿主页）。
  /// 只跟随网络调用本身——结果弹层展示期间必须为 false，否则弹层背后还在转圈，
  /// 且 widget test 的 pumpAndSettle 永远settle 不了。
  final ValueNotifier<bool> planSubmissionProgress = ValueNotifier<bool>(false);
  final ValueNotifier<int> materialDetailRevision = ValueNotifier<int>(0);

  void _setGenerating(bool value) {
    _generating = value;
    planSubmissionProgress.value = value;
  }

  /// 2026-09-12 用户口径「点了没反应像卡住」：下达采购/委外执行期间屏幕中间
  /// 给加载遮罩（车间已有 planSubmissionProgress 专用遮罩，不重复盖）。与
  /// planSubmissionProgress 同一约束：只跟随网络调用本身，结果弹层前必须清空。
  final ValueNotifier<String?> bucketActionBusyMessage = ValueNotifier<String?>(
    null,
  );

  bool _planSubmissionApproveNow = false;

  /// 最近一次「下达车间」的返回结果(ADR-104：主表分段提交是 silent 的，靠它把
  /// 「并入原计划 N 张」写进分段回报)。
  List<ProductionGeneratedPlanRef> _lastIssuedPlans = const [];
  MaterialSupplyRoute? _notifyingRoute;
  int _candidatePageNo = 1;
  final int _candidatePageSize = 100;
  String _candidateKeyword = '';

  // 2026-09-25 单号列统一：候选表销售单号列排序 + 值筛选（服务端白名单/facets）。
  String? _candidateSortColumn;
  bool _candidateSortAscending = true;
  Map<String, List<MasterFacetBucket>> _candidateDocNoFacets = const {};
  String? _candidateOrderNoFilter;
  final _candidateSearch = TextEditingController();
  final _bomSearch = TextEditingController();
  Timer? _analysisPollTimer;
  bool _silentAnalysisReloadInFlight = false;

  /// 新建分析页的两个分段：勾选销售订单产品 / 录入手工需求单(ADR-130)。
  _CandidateTab _candidateTab = _CandidateTab.sales;

  /// 本次分析的手工需求单(每张 = 单头 + 多行货品)，至少一张；页面释放时统一 dispose。
  final List<MaterialManualDemandDraft> _manualDemandDrafts = [];

  /// 分析结果顶部「手工需求」chip 超过上限时是否展开全部。
  bool _manualDemandsExpanded = false;

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

  // Shared by preparation and bucket detail. Recalculation only changes quantities,
  // never a planner's per-line tolerance. These are next-issue inputs, not edits of
  // any previously approved execution segment.
  final Map<String, TextEditingController> _overproductionPercentInputs = {};

  /// 系统按货品默认比例预填的格子(ADR-129 §2.10，与计划编辑页同一份口径)：没人
  /// 改过的下达时送空值，由服务端按默认填写且不记住，新快照带来新的默认比例时跟着
  /// 刷新；人改过的按所填值明确提交，也不再跟着刷新。
  final _prefilledOverproductionRates = SystemPrefilledRates();

  /// 表格按「已下达」显示过的格子：比例随工单锁定，快照刷新不再改它的显示值。
  final Set<TextEditingController> _issuedOverproductionRates = {};
  bool _overproductionReseedAttached = false;

  /// [issued] 由表格的已下达分支传入，见 [_issuedOverproductionRates]。
  TextEditingController _overproductionPercentController({
    String? analysisLineId,
    String? materialLineId,
    bool issued = false,
  }) {
    final analysis = _analysis;
    final indexes = analysis == null ? null : _analysisIndexes(analysis);
    final product = indexes?.productsById[analysisLineId];
    final material = indexes?.groupsByLine[materialLineId]?.representative;
    final sourceProduct =
        product ??
        (material?.isRootSupply == true
            ? indexes?.productsById[material?.analysisLineId]
            : null);
    final exactMaterialId =
        product?.rootMaterialLineId ??
        materialLineId ??
        indexes?.materialsByProduct[analysisLineId]
            ?.where((m) => m.isRootSupply)
            .firstOrNull
            ?.materialLineId;
    final identity = exactMaterialId != null
        ? 'M:$exactMaterialId'
        : 'P:$analysisLineId';
    final key = '${_sessionScopeKey()}|${analysis?.analysisId}|$identity';
    final controller = _overproductionPercentInputs.putIfAbsent(key, () {
      if (!_overproductionReseedAttached) {
        // materialDetailRevision 在每份新快照落地(_applyAnalysis 末尾)时递增：
        // 借同一个信号刷新没人改过的预填比例，不在构建期间改输入框。
        _overproductionReseedAttached = true;
        materialDetailRevision.addListener(_reseedSystemOverproductionRates);
      }
      // 计划单上人改过才会带来比例(见计划编辑页)，与本页手填同等明确提交。
      final requested = sourceProduct == null
          ? null
          : widget.seed.initialAllowedOverproductionRateFor(sourceProduct);
      final goodsId = product?.goodsId ?? material?.goodsId;
      final created = TextEditingController();
      if (requested == null) {
        _prefilledOverproductionRates.fill(
          created,
          analysis?.overproductionDefaults[goodsId] ?? 0,
          goodsId: goodsId,
        );
      } else {
        created.text = productionOverproductionPercentText(requested);
      }
      return created;
    });
    if (issued) _issuedOverproductionRates.add(controller);
    return controller;
  }

  /// 下达时带的允许超产比例：没人改过送 null(服务端按货品默认填写、标 DEFAULT、
  /// 不记住)；人填的按所填值明确提交。调用方已校验过格子里是有效比例。
  double? _submittedOverproductionRate({
    String? analysisLineId,
    String? materialLineId,
  }) => _prefilledOverproductionRates.submitted(
    _overproductionPercentController(
      analysisLineId: analysisLineId,
      materialLineId: materialLineId,
    ),
  );

  /// 新快照的默认比例刷进没人改过、也未按已下达显示的格子；快照没带该货品的
  /// 默认比例时保持原样。
  void _reseedSystemOverproductionRates() =>
      _prefilledOverproductionRates.reseed(
        _overproductionPercentInputs.values,
        _analysis?.overproductionDefaults ?? const {},
        skip: _issuedOverproductionRates.contains,
      );

  final Set<String> _selectedPlanLineIds = {};
  final Map<String, MaterialSupplyRoute> _routeDraft = {};
  // 2026-09-16：「按历史分析推导上次确认路线」的前端记忆整套退役——供应方式的
  // 单一事实源是货品主档 goods.source_type，确认即回写主档，建议路线
  // (sourceSuggestion) 随快照下发，不再另发一趟 /last-routes 也不再本地缓存。
  // 只留下会话作用域键：在途调拨读取仍要用它隔离迟到响应。
  Set<String>? _sessionScopePermissions;
  String? _sessionScopeIdentity;
  String? _sessionComputedScope;

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

  /// BOM 表是否处于全屏（表格全屏路由打开时顶部卡片不可见，搜索框
  /// 借 [MasterDataTableView.onFullscreenChanged] 回到表格工具条）。
  bool _bomTableFullscreen = false;
  String? _bulkOperationLabel;
  int _bulkOperationCompleted = 0;
  int _bulkOperationTotal = 0;
  ProductionMaterialAnalysisView? _indexCacheAnalysis;
  _MaterialAnalysisIndexes? _indexCache;
  ProductionMaterialAnalysisView? _bomProjectionAnalysis;

  /// 投影缓存键：视图 chip + 关键词 + 表头筛选 + 路线草稿/脏组签名（路线列桶与
  /// 路线筛选跟着下拉草稿变，缓存键漏掉它们会出现「改了不刷新」）。
  String? _bomProjectionKey;
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
      (_permissions.contains(Perm.productionMaterialAnalysisGenerate) ||
          _permissions.contains(Perm.productionMaterialAnalysisNotify) ||
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
      _savingGoodsOwnership ||
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

  /// 当前把整页按住的那个操作叫什么（给禁用态的 tooltip 用）。
  String? get _busyLabel {
    if (_savingGoodsOwnership) return '保存所属仓库';
    if (_previewingAnalysis) return '刷新分析';
    if (_savingRoutes) return '确认物料路线';
    if (_savingPriorities) return '调整优先级';
    if (_cancellingAnalysis) return '取消分析';
    if (_cancellingAction) return '撤销下达';
    if (_claimingSharedFuture) return '认领公共在途';
    if (_borrowing) return '调拨物料';
    if (_generating) return '创建生产计划';
    final route = _notifyingRoute;
    if (route != null) return '下达${route.label}';
    return null;
  }

  /// 下达进行中的遮罩（不可关闭）。放在基类是因为**分桶详情页也要用同一份**——
  /// 2026-09-11 起下达车间不再先 pop 回宿主页，进度画在分桶页自己身上。
  Widget _planSubmissionOverlay(ThemeData theme) {
    // ADR-71：下达车间是一次原子调用（建子件任务+出计划+可选审核同一事务），
    // 不再有「校验→生成」两阶段，遮罩只描述这一个不可中断的步骤。
    // 2026-09-12 起 delegate 到全站统一的 UtenBusyOverlay（root Overlay 全屏
    // 蒙版 + 屏幕正中卡片；蒙版色贴近页面背景，见组件注释）。
    final title = _planSubmissionApproveNow ? '正在生成并审核下达' : '正在生成生产计划';
    final description = _planSubmissionApproveNow
        ? '系统正在同一事务内创建子件任务、生成计划、审核下达并按需生成提货单。'
        : '系统正在创建计划草稿并提交审批。';
    return UtenBusyOverlay(
      semanticsKey: const Key('material-analysis-plan-submission-progress'),
      title: title,
      description: description,
    );
  }

  /// 页面级长动作遮罩的副标题：取消分析 / 撤回任务不是「批量处理所选行」，
  /// 文案要对得上正在做的事。
  String _actionBusyDescription(String message) =>
      message.startsWith('正在取消') || message.startsWith('正在撤回')
      ? '收到服务端结果后自动按最新事实刷新分析。'
      : '同一事务内批量处理所选行，完成后自动刷新。';

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
      ) &&
      // 自制路线下过生产计划的行同样已有未撤销的下游任务：计划在那儿，路线不能再改。
      // 原来只认 notifiedTargets(采购 / 委外的申请)，自制计划不在里面——顶层与自制子件
      // 下达之后「供应方式」下拉照旧可改(2026-09-23 用户实机)。
      !group.paths.any((path) => _issuedMakePlanOf(path) != null);

  /// 这一行已下达的生产计划挂在哪个产品行上：顶层是产品行自己(它本身就是排产对象)，
  /// 其余是锚点子件行；没下过、或计划已全部撤销，返回 null。
  ProductionMaterialAnalysisProduct? _issuedMakePlanOf(
    ProductionMaterialAnalysisMaterial material,
  ) {
    final analysis = _analysis;
    if (analysis == null) return null;
    final anchorId = material.isRootSupply
        ? material.analysisLineId
        : material.planAnchorAnalysisLineId;
    if (anchorId == null) return null;
    final product = _analysisIndexes(analysis).productsById[anchorId];
    return product != null && product.issuedPlanQty > 0.0001 ? product : null;
  }

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

  /// 这一行的供应方式当前取值（显示与提交共用）。
  ///
  /// 2026-09-25 确认路线退役：优先级 = 本地草稿 > 已确认 > 根行历史计划证明的
  /// MAKE > 主档/BOM 推导建议(sourceSuggestion)。**服务端 REVIEW（主档来源为空
  /// 且无 BOM 子层）解析成 null**——这类行红框空选、不能下单，由人补选后
  /// 直改即存；不再有「兜底委外」的假预填（缺省值看着像已决定，还卡住了
  /// 「选同一个值不算改动」的确认路径）。
  MaterialSupplyRoute? _draftRoute(_MaterialGroup group) {
    final material = group.representative;
    final explicit = _routeDraft[group.key] ?? material.confirmedRoute;
    if (explicit != null) return explicit;
    final product = _analysis == null
        ? null
        : _analysisIndexes(_analysis!).productsById[material.analysisLineId];
    // A historical production plan proves MAKE even before its new root node
    // has a route-confirmation record. Do not overwrite that fact.
    if (material.isRootSupply &&
        product != null &&
        _hasExistingRootPlan(product)) {
      return MaterialSupplyRoute.make;
    }
    return material.sourceSuggestion;
  }

  /// 会话作用域键（账号 / 模拟身份 / 权限集）：跨账号切换时用它丢弃迟到的
  /// 异步响应，避免把上一个账号的数据显示给下一个账号。
  String _sessionScopeKey() {
    final session = ref.read(sessionProvider);
    final permissions = _permissions;
    final identity =
        '${session.status}|${session.user?.id}|${session.actor?.id}|'
        '${session.impersonationReadOnly}|${identityHashCode(session.user)}|'
        '${identityHashCode(session.actor)}';
    if (identity == _sessionScopeIdentity &&
        identical(permissions, _sessionScopePermissions)) {
      return _sessionComputedScope!;
    }
    final ordered = permissions.toList()..sort();
    _sessionScopeIdentity = identity;
    _sessionScopePermissions = permissions;
    return _sessionComputedScope = '$identity|${ordered.join(',')}';
  }

  // ===== 继承链协作契约：实现在后段 part，基类生命周期按虚调用分发 =====
  Future<void> _previewAnalysis();

  /// 供应方式自动确认的轻提示文案 (预览 / 改路线回包共用一处)。
  String _autoConfirmedRoutesText(int count) => '已按货品档案自动确认 $count 条供应方式';

  /// 静默刷新 (确认路线) 进行中：顶部卡片给一行不挡操作的小提示。
  bool _autoRouteRefreshing = false;

  /// 静默刷新的防环守卫：每个 (analysisId|version|fingerprint) 纪元最多刷一次，
  /// 刷新回包本身也登记进来——服务端若仍报待确认，不再连环刷新。
  String? _autoRouteRefreshEpoch;

  String _analysisEpoch(ProductionMaterialAnalysisView view) =>
      '${view.analysisId}|${view.version}|${view.fingerprint}';

  /// ADR-102 (2026-09-27 供应方式自动确认移到服务端)：新建 / 刷新分析时服务端在同一次
  /// 重算里就按货品档案确认了供应方式，页面不再自己补发 PUT /routes、不再盖全屏遮罩。
  /// 打开已有分析时，若服务端报还有能确认的行(多半是到货 / 审核等别的单据顺带重算后
  /// 新冒出来的)，就静默刷新一次分析，由服务端一并确认。有人正在填数 / 勾选或别的操作
  /// 进行中就不打扰，下次换快照再试。
  void _refreshPendingRouteConfirmation() {
    final analysis = _analysis;
    if (!mounted ||
        analysis == null ||
        analysis.pendingAutoConfirmRouteCount <= 0 ||
        _autoRouteRefreshEpoch == _analysisEpoch(analysis) ||
        _booting ||
        _busy ||
        !_canManage ||
        !_canRoute ||
        _sources.isEmpty ||
        _hasUnsavedAnalysisEditing) {
      return;
    }
    final warehouseId = _warehouseId;
    final warehouseIds = _warehouseIds.toList()..sort();
    if (warehouseId == null ||
        !warehouseIds.contains(warehouseId) ||
        _sources.length > _MaterialAnalysisPageBase._maxAnalysisItems) {
      return;
    }
    _autoRouteRefreshEpoch = _analysisEpoch(analysis);
    unawaited(
      _runPendingRouteConfirmation(analysis, warehouseId, warehouseIds),
    );
  }

  /// 静默刷新本体：与右上角「按最新库存刷新分析」同一个接口、同一份请求内容 (完整来源 +
  /// 版本 / 指纹)，只是不弹校验提示、不挂红色错误——不是人点的，失败只轻提示一次。
  /// 放在页面基类而不复用候选层的 [_previewAnalysis]：那里是人点的新建 / 刷新，
  /// 校验提示、错误态和 409 恢复都按「人在等结果」设计。
  Future<void> _runPendingRouteConfirmation(
    ProductionMaterialAnalysisView view,
    String warehouseId,
    List<String> warehouseIds,
  ) async {
    final canonicalSources = [..._sources]
      ..sort((a, b) => a.canonicalKey.compareTo(b.canonicalKey));
    final key = businessIdempotencyKey(
      'material-analysis-route-auto-confirm',
      [
        view.analysisId,
        view.version,
        view.fingerprint,
        warehouseId,
        warehouseIds.join(','),
        for (final source in canonicalSources)
          '${source.canonicalKey}:${source.requestedQty}:${source.sourceReason ?? ''}',
      ].join('|'),
    );
    setState(() {
      _previewingAnalysis = true;
      _autoRouteRefreshing = true;
    });
    try {
      final latest = await ref
          .read(productionPlanRepositoryProvider)
          .previewMaterialAnalysis(
            analysisId: view.analysisId,
            expectedVersion: view.version,
            analysisFingerprint: view.fingerprint,
            warehouseId: warehouseId,
            warehouseIds: warehouseIds,
            idempotencyKey: key,
            sources: canonicalSources,
          );
      if (!mounted) return;
      setState(() {
        _previewingAnalysis = false;
        _autoRouteRefreshing = false;
        // 本次刷新的回包自己不再触发静默刷新 (服务端若仍报待确认，不连环刷)。
        _autoRouteRefreshEpoch = _analysisEpoch(latest);
        if (_analysis?.analysisId != view.analysisId) return;
        // 静默刷新不是人点的：等回包期间若有人开始填数 / 勾选，按「保留未提交输入」
        // 套用，不能把刚填的吞掉。
        if (_hasUnsavedAnalysisEditing) {
          _applyAnalysisKeepingPreparationEditing(latest);
        } else {
          _applyAnalysis(latest);
        }
        if (latest.routeResetCount > 0) {
          _serverRefreshNotice = '${latest.routeResetCount} 条路线因主档变更需重新确认';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _previewingAnalysis = false;
        _autoRouteRefreshing = false;
      });
      // 页面仍显示原快照，不挂红色错误。版本冲突说明别人刚改过，静默重读最新即可；
      // 其他失败轻提示一次，可点右上角刷新重试。
      if (_isAnalysisConflict(error)) {
        unawaited(_reloadAnalysisSilently(protectUnsavedEditing: true));
      } else {
        context.appInfo('供应方式自动确认没有完成，可点右上角「刷新」重试');
      }
    }
  }

  /// 服务端在本次新建 / 刷新 / 改路线的同一次重算里自动确认了供应方式时的轻提示
  /// (ADR-102)：放在套用快照这一处，不管是哪条路径 (候选层的新建 / 刷新、静默刷新)
  /// 拿到的回包都只提示一次；同一快照纪元不重复。改路线的保存把条数并进自己的成功
  /// 提示，先登记纪元再套用。
  String? _autoConfirmNoticeEpoch;

  void _noticeAutoConfirmedRoutes(ProductionMaterialAnalysisView view) {
    final count = view.autoConfirmedRouteCount;
    final epoch = _analysisEpoch(view);
    if (count <= 0 || _autoConfirmNoticeEpoch == epoch) return;
    _autoConfirmNoticeEpoch = epoch;
    // 套用快照发生在 setState 回调里：提示排到本轮之后发。
    scheduleMicrotask(() {
      if (mounted) context.appInfo(_autoConfirmedRoutesText(count));
    });
  }

  /// 表头筛选值只在当前桶里仍存在时保留（刷新/轮询/切视图后失效值自动移除，
  /// 仍有效的用户筛选不清）；实现见 material_analysis_material_table.dart。
  void _pruneMaterialTableFilters();

  /// 主表「这一行此刻能不能下单」的判据，不能时返回人话原因(ADR-102)。
  /// 实现见 material_analysis_material_table.dart。
  String? _tableIssueBlockedReason(
    _MaterialGroup group, {
    bool forAggregate = false,
  });
  Widget? _materialAggregateToolbarAction() => null;
  void _materialAggregateAnalysisChanged() {}
  bool _materialAggregateOwnsLine(String lineId) => false;
  bool _materialAggregateOwnsProductLine(String lineId) => false;

  /// 主表里还有用户手填未提交的数量，或还勾着待下单的行(ADR-102)。
  /// 轮询期间必须让路，否则整树换快照会把人填了一屏的数与勾选一起吃掉。
  bool get _hasUnsubmittedMaterialTableInput;

  /// 主表勾选集里此刻真能下单的那些行，以及被折叠/表头筛选藏起来的行数
  /// (ADR-102)。实现见 material_analysis_material_table.dart。
  ({List<_MaterialGroup> visible, int hidden}) _selectedIssuableGroups();

  int _materialOrderSelectionCount(List<_MaterialGroup> groups) =>
      groups.length;
  bool get _materialAggregateWorking => false;

  /// 把这些行按「车间逐层 → 采购 → 委外」分段下达(ADR-102)。全部段都成功返回 true。
  Future<bool> _submitMaterialTableRows(List<_MaterialGroup> groups);

  /// 下单前每个提交单元的累计已下单量(ADR-117)，下单后与之比出「这次刚下了什么」。
  /// 实现见 material_analysis_child_shortage.dart。
  Map<String, double> _issuedQtySnapshot();

  /// Compare authoritative order facts, including successful aggregate substeps.
  bool _orderedSince(Map<String, double> before);

  /// 下单 / 追加成功后查刚下单的件的下层：还缺料就弹窗问要不要现在补(ADR-117)。
  Future<void> _checkChildShortagesAfterOrder(Map<String, double> before);

  /// 下完单后立即核对本分析上的车间催办(ADR-117)，计划已下够的办结撤卡。
  Future<void> _reconcileWorkshopUrgesAfterOrder();

  /// 释放主表行内「下单数量 / 追加下单」的输入控制器(ADR-102)。
  /// 实现见 material_analysis_material_table.dart。
  void _disposeMaterialTableInputs();

  /// 换成另一份分析时，把主表的行内输入与指派草稿整体作废(ADR-102)。
  void _resetMaterialTableInputsForNewAnalysis();

  /// 同一份分析换了新快照后，把系统预填值刷新一遍——**只覆盖用户没动过的格子**。
  /// 轮询与 409 恢复都会整树换快照，少了这一步，用户填了一屏的数会被静默吃掉。
  void _reseedMaterialTableQtyInputs();

  /// 权威快照一到就让父子联动的回滚式预览作废(ADR-102)：模拟快照永远比权威旧，
  /// 留着它会让主表拿下达前的模拟值预填并让人下单。
  void _invalidateMaterialTableCascadePreview();
  bool _normalizeNewWarehouseScope();
  ProductionMaterialAnalysisMaterial? _rootSupplyMaterialOf(
    ProductionMaterialAnalysisProduct product,
  );
  bool _hasResolvedMaterialSource(ProductionMaterialAnalysisMaterial material);

  /// 「物料 / 调拨」简化选择器（三个调入入口+完整详情）；
  /// 实现见 material_analysis_material_table.dart。
  Future<void> _showTransferLauncher(_MaterialGroup group);
  String _analysisDynamicProjectionKey(ProductionMaterialAnalysisView view);

  Widget _nodeBorrowSection(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
  );

  Future<void> _loadCandidates({int? page}) async {
    final request = _candidateRequests.begin();
    // 2026-09-25 单号列统一：销售单号排序/值筛选随列表下推（服务端白名单）。
    final requestedSort = _candidateSortColumn;
    final requestedOrder = _candidateSortColumn == null
        ? null
        : (_candidateSortAscending ? 'asc' : 'desc');
    final requestedOrderNo = _candidateOrderNoFilter;
    final requestedKeyword = _candidateKeyword;
    setState(() {
      _loadingCandidates = true;
      _error = null;
      if (page != null) _candidatePageNo = page;
    });
    try {
      final repository = ref.read(productionPlanRepositoryProvider);
      final result = await repository.materialAnalysisSalesCandidates(
        page: _candidatePageNo,
        size: _candidatePageSize,
        keyword: requestedKeyword,
        sort: requestedSort,
        order: requestedOrder,
        orderBillNo: requestedOrderNo,
      );
      // 单号 facets 与列表同上下文（不含单号自身筛选）；失败不阻断列表。
      Map<String, List<MasterFacetBucket>> facets = const {};
      try {
        facets = await repository.materialAnalysisSalesCandidateFacets(
          keyword: requestedKeyword,
        );
      } catch (_) {
        facets = const {};
      }
      if (!mounted || !_candidateRequests.isCurrent(request)) return;
      setState(() {
        _candidateDocNoFacets = facets;
        _candidatePage = result;
        _candidatePageNo = result.page;
        _loadingCandidates = false;
      });
    } catch (error) {
      if (!mounted || !_candidateRequests.isCurrent(request)) return;
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

  /// 主表或准备子页可见时共用一个只读轮询；写命令期间让路。
  /// 编辑期间更新服务端事实，并按原行恢复输入和选择，不执行刷新写命令。
  Future<void> _pollAnalysisIfIdle() async {
    if (!mounted) return;
    final visible =
        ModalRoute.of(context)?.isCurrent == true ||
        _preparationReadContexts.any(
          (scope) => scope.mounted && ModalRoute.of(scope)?.isCurrent == true,
        );
    if (!visible) return;
    if (_analysis == null || _booting || _busy) {
      return;
    }
    await _reloadAnalysisSilently(protectUnsavedEditing: true);
  }

  bool get _hasUnsavedAnalysisEditing =>
      _editingPriorities ||
      _dirtyRouteGroups.isNotEmpty ||
      _selectedPlanLineIds.isNotEmpty ||
      // ADR-102：主表现在整张铺开了行内数量输入与下单勾选，轮询期间必须一并让路。
      // 少了这一条，45 秒一次的静默刷新会把人填了一屏的数和勾选一起冲掉。
      _hasUnsubmittedMaterialTableInput ||
      _batchQtyControllers.entries.any(
        (entry) =>
            entry.value.text.trim().isNotEmpty &&
            _systemSeededBatchQtyTexts[entry.key] != entry.value.text,
      );

  /// 动态投影键按快照对象缓存：当前快照每次轮询都要比一次，不必每次重拼整串。
  final Expando<String> _projectionKeys = Expando<String>();
  String _projectionKeyOf(ProductionMaterialAnalysisView view) =>
      _projectionKeys[view] ??= _analysisDynamicProjectionKey(view);

  /// 静默重拉当前分析详情（返回即刷新）。本地未保存的路线草稿/勾选按稳定
  /// 操作组键恢复到新快照，避免吞掉计划员正在做的决定。
  Future<void> _reloadAnalysisSilently({
    bool protectUnsavedEditing = false,
  }) async {
    final analysis = _analysis;
    if (analysis == null ||
        _busy ||
        _booting ||
        _silentAnalysisReloadInFlight) {
      return;
    }
    // 产品优先级正在拖动时不替换产品顺序；路线草稿则可以按 action group
    // 安全地映射到新快照，既加载最新库存，又不吞掉计划员的未保存决定。
    _silentAnalysisReloadInFlight = true;
    _ownerRefreshQueued = false;
    try {
      final view = await _readMaterialAnalysisDetail(analysis.analysisId);
      if (!mounted) return;
      final current = _analysis;
      // 写命令、切换分析或更高版本已经到达时不接收此旧读。
      // 新开始的本地编辑由下方保留输入的事实刷新处理。
      if (_busy ||
          current == null ||
          current.analysisId != analysis.analysisId ||
          view.version < current.version) {
        return;
      }
      // 分析头版本只保护分析本身的写入 CAS；计划审批、派工、仓库发料、
      // 报工/入库和 exact peg 是读侧动态投影，可能在 version/fingerprint
      // 不变时更新。只有头与动态投影都相同才跳过重建。
      // 2026-09-27：先比较再套用，编辑中也一样——原来有人填数/勾选时不比就整份
      // 重新套用，45 秒一次整页重画并补发汇总预览，数据其实没变。
      if (view.version == current.version &&
          view.fingerprint == current.fingerprint &&
          _projectionKeyOf(view) == _projectionKeyOf(current)) {
        return;
      }
      if (_editingPriorities ||
          (protectUnsavedEditing && _hasUnsavedAnalysisEditing)) {
        setState(() {
          _applyAnalysisKeepingPreparationEditing(view);
        });
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
      if (mounted && _ownerRefreshQueued) {
        unawaited(_reloadAnalysisSilently(protectUnsavedEditing: true));
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _overproductionPercentInputs.values) {
      controller.dispose();
    }
    materialDetailRevision.dispose();
    bucketActionBusyMessage.dispose();
    _analysisPollTimer?.cancel();
    _candidateSearch.dispose();
    _bomSearch.dispose();
    for (final draft in _manualDemandDrafts) {
      draft.dispose();
    }
    _disposeMaterialTableInputs();
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
      final existingAnalysisId = widget.seed.analysisId;
      if (existingAnalysisId != null) {
        // Independent reads start together. Opening a saved analysis must not
        // write/recompute its complete BOM and stock snapshot on every visit.
        // Explicit refresh and the server's version/BOM guards own that work.
        final results = await Future.wait<Object?>([
          ref.read(masterNameServiceProvider).ensureCommonLoaded(),
          _readMaterialAnalysisDetail(existingAnalysisId),
        ]);
        final view = results[1] as ProductionMaterialAnalysisView;
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
        return;
      }
      await Future.wait([
        ref.read(masterNameServiceProvider).ensureCommonLoaded(),
        ref.read(materialAnalysisWarehousePrefsProvider.notifier).syncNow(),
      ]);
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
      setState(() {
        _booting = false;
        _autoPreviewFromSeed = _sources.isNotEmpty;
      });
      if (_sources.isNotEmpty) {
        try {
          await _previewAnalysis();
        } finally {
          if (mounted) setState(() => _autoPreviewFromSeed = false);
        }
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
    view = _prepareAnalysisOwnership(view);
    final previousAnalysisId = _analysis?.analysisId;
    ++_futureTransferRequest;
    if (previousAnalysisId != view.analysisId ||
        _futureTransferReadScope != _sessionScopeKey() ||
        !view.allowedActions.contains('VIEW_FUTURE_TRANSFERS')) {
      _futureTransferRecords = const [];
      _futureTransferByMaterial = const {};
      _futureTransferError = null;
      _futureTransferReadScope = null;
    }
    if (previousAnalysisId != null && previousAnalysisId != view.analysisId) {
      for (final controller in _batchQtyControllers.values) {
        controller.dispose();
      }
      _batchQtyControllers.clear();
      _systemSeededBatchQtyTexts.clear();
      // 换了一份分析，主表行内输入与指派草稿全部作废(ADR-102)。
      _resetMaterialTableInputsForNewAnalysis();
    }
    _analysis = view;
    _materialAggregateAnalysisChanged();
    // 权威快照优先：先让父子联动的模拟快照作废，再按新快照刷系统预填值
    // (只覆盖用户没动过的格子)。顺序不能反——反了就是拿模拟值去回填。
    _invalidateMaterialTableCascadePreview();
    _reseedMaterialTableQtyInputs();
    // 附带读取合成一批、回来只重画一次(写命令期间由各读取自己推迟)。
    _requestCompanionReads(const [
      _CompanionRead.futureTransfers,
      _CompanionRead.transferableIn,
      _CompanionRead.assignmentDefaults,
    ]);
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
    final indexes = _analysisIndexes(view);
    final groups = indexes.groups;
    // 刷新后草稿已清空，只有仍可勾的组才留在选中集：轮询期间被同事确认的行
    // 自动脱选（否则「勾着但不计数」）。
    //
    // ADR-102（2026-09-25 确认路线退役修订）：勾选只服务「下单」，谓词与
    // [_selectedIssuableGroups] 同源——能下单，或只差「车间/负责人」这种当场
    // 能修好的拦截。原先「路线可提交」那一支随确认路线按钮一起退役。
    // 2026-09-27：只核对勾着的组——进页时勾选集是空的，不再对整张表逐行跑一遍判据。
    bool stillSelectable(String key) {
      final group = indexes.groupsByKey[key];
      return group != null &&
          const [
            null,
            '先在「生产车间」列里指定本次交给哪个车间',
            '先在「负责人」列里指定本次谁负责',
          ].contains(_tableIssueBlockedReason(group, forAggregate: true));
    }

    _selectedMaterialGroupKeys.removeAll(
      _selectedMaterialGroupKeys.where((key) => !stillSelectable(key)).toList(),
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
    // 新快照的进度/路线桶可能不再含旧筛选值（确认路线后「路线待确认」桶消失
    // 即典型）：只移除失效值，避免不可见的激活筛选把表过滤成空。
    _pruneMaterialTableFilters();
    materialDetailRevision.value++;
    _noticeAutoConfirmedRoutes(view);
    // 服务端报还有能按货品档案确认的行：本轮结束后静默刷新一次(自带纪元守卫)。
    if (view.pendingAutoConfirmRouteCount > 0) {
      scheduleMicrotask(_refreshPendingRouteConfirmation);
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
      final latest = await _readMaterialAnalysisDetail(analysisId);
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
          product.sourceType != 'SUBCONTRACT_MAKE' &&
          product.sourceType != 'AGGREGATE_MAKE')
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
    final groupsByKey = <String, _MaterialGroup>{};
    final materialsByAnchorProduct =
        <String, ProductionMaterialAnalysisMaterial>{};
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
      groupsByKey[group.key] = group;
      final anchor = material.planAnchorAnalysisLineId;
      if (anchor != null) {
        materialsByAnchorProduct.putIfAbsent(anchor, () => material);
      }
    }
    final indexes = _MaterialAnalysisIndexes(
      productsById: productsById,
      materialsByProduct: materialsByProduct,
      groups: groups,
      groupsByLine: groupsByLine,
      groupsByKey: groupsByKey,
      materialsByAnchorProduct: materialsByAnchorProduct,
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

  bool _canSelectProduct(ProductionMaterialAnalysisProduct product) =>
      _productRouteConfirmedForWorkshop(product) &&
      !_productFullyTransferred(product) &&
      product.canSchedule;

  /// 顶层与子层同口径：根供给行必须显式确认为自制（历史计划只影响草稿预填，
  /// 见 _draftRoute 的根分支，不再绕过确认门）；无根供给行的旧分析沿用旧合同。
  bool _productRouteConfirmedForWorkshop(
    ProductionMaterialAnalysisProduct product,
  ) {
    final root = _rootSupplyMaterialOf(product);
    if (root == null) return true;
    final group = _analysisIndexes(
      _analysis!,
    ).groupsByLine[root.materialLineId];
    return root.confirmedRoute == MaterialSupplyRoute.make &&
        group != null &&
        !_dirtyRouteGroups.contains(group.key);
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

  // ===== 缺口颜色（2026-09-10 F2e：语义 token 明暗配对，主表与桶详情共用）=====

  /// 缺口文字色：>0 红（colorScheme.error 随主题）、=0 绿（successText /
  /// successOnDark，白底对比达 AA）、无数据中性。
  Color _shortageTextColor(ThemeData theme, double? shortage) {
    if (shortage == null) return theme.colorScheme.onSurface;
    if (shortage > 0) return theme.colorScheme.error;
    return theme.brightness == Brightness.dark
        ? UtenColors.successOnDark
        : UtenColors.successText;
  }

  /// 缺口格底色：>0 errorContainer 30%、=0 success 14%（深色取亮档）。
  Color? _shortageCellColor(ThemeData theme, double? shortage) {
    if (shortage == null) return null;
    if (shortage > 0) {
      return theme.colorScheme.errorContainer.withValues(alpha: 0.3);
    }
    return (theme.brightness == Brightness.dark
            ? UtenColors.successOnDark
            : UtenColors.success)
        .withValues(alpha: 0.14);
  }

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
    if (product == null) return null;
    if (product.sourceType != sourceType) {
      // 同料合并共享批次的产品(AGGREGATE_MAKE)与 MAKE/SUBCONTRACT_MAKE 子任务同一条
      // 委托链：并入共享批次的行也解析得到「已建任务」的子产品，进度/计划入口
      // 内联展示，不再误报「计划同步中」(2026-09-26 用户实机)。
      if (sourceType == 'MAKE_COMPONENT' &&
          product.sourceType == 'AGGREGATE_MAKE') {
        return product;
      }
      return null;
    }
    return product;
  }

  /// 本行需求并入的共享制造批次(AGGREGATE_MAKE)产品；没并进共享批次时返回 null。
  ProductionMaterialAnalysisProduct? _sharedBatchChildProductOf(
    ProductionMaterialAnalysisMaterial material,
  ) {
    if (material.aggregateDelegatedQty <= 0.0001) return null;
    final child = _taskChildProductOf(material);
    if (child?.sourceType == 'AGGREGATE_MAKE') return child;
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
    if (material.preparationAdoptedQty > 0 &&
        material.planAnchorAnalysisLineId == null &&
        (material.aggregatePreparation?.orderedQty ?? 0) <= 0.0001 &&
        (material.aggregatePreparation?.totalOrderedQty ?? 0) <= 0.0001 &&
        !material.notifiedTargets.any(
          (target) =>
              target.status != 'CANCELLED' &&
              const {
                'PREPLAN_MAKE_TASK',
                'SUBCONTRACT_MAKE_TASK',
                'PRODUCTION_PLAN',
              }.contains(target.documentType),
        )) {
      // 采用的是已有来源计划；来源的 MAKE_* 进度不代表本行另建了待同步计划。
      return false;
    }
    final stage = material.flowStage?.trim().toUpperCase();
    return material.planAnchorAnalysisLineId != null ||
        (stage != null &&
            stage.startsWith('MAKE_') &&
            stage != 'MAKE_PENDING_ISSUE');
  }
}

/// 继承链的最终实现类：保持测试与 createState 引用的原私有名。
class _ProductionMaterialAnalysisPageState
    extends _MaterialAnalysisChildShortageState {
  @override
  Widget build(BuildContext context) {
    // 账号 / 权限一变就重设跨账号读的作用域(在途调拨、可调拨量、车间默认值都按
    // 会话隔离迟到响应)。
    ref.listen(sessionProvider, (_, _) => _reloadCompanionScopes());
    ref.listen(currentPermissionsProvider, (_, _) => _reloadCompanionScopes());

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
                // 禁用时也要说清为什么（2026-09-14 用户口径「取消分析按钮点击
                // 没有反应」）：一个点不动又不解释的图标，用户只会当它坏了。
                tooltip: _busy
                    ? '正在执行「${_busyLabel ?? '上一个操作'}」，结束后才能取消分析'
                    : '取消分析',
                onPressed: _busy ? null : _cancelCurrentAnalysis,
                icon: _cancellingAnalysis
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cancel_outlined),
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
                    ? _bootingBody(theme)
                    : _analysis == null
                    ? (_previewingAnalysis && _autoPreviewFromSeed
                          ? _firstAnalysisProgress(theme)
                          : _candidateBody(theme))
                    : _analysisBody(theme),
              ),
            ),
            if (_planSubmissionInProgress)
              Positioned.fill(child: _planSubmissionOverlay(theme)),
            ValueListenableBuilder<String?>(
              valueListenable: bucketActionBusyMessage,
              builder: (context, message, _) => message != null
                  ? Positioned.fill(
                      child: UtenBusyOverlay(
                        // 2026-09-15 起确认路线也走这条通道，key 泛化为「页面
                        // 级长动作遮罩」（测试锁定用，分桶页那份同 key 不同路由
                        // 不会同时挂载）。
                        semanticsKey: const Key(
                          'material-analysis-action-busy',
                        ),
                        title: message,
                        description: _actionBusyDescription(message),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      // 悬浮动作随勾选状态出现/消失，不做进场缩放动画：状态变化后
      // 立即可点（动画中途命中区域为缩放中尺寸，会吃掉点击）。
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      // 进页等待期与第一次分析进行中只显示进度，不挂候选表的「联合分析」按钮。
      floatingActionButton: _analysis != null
          ? _floatingActions()
          : _booting || (_previewingAnalysis && _autoPreviewFromSeed)
          ? null
          : _candidateFloatingAction(),
    );
    return PopScope(canPop: !_planSubmissionInProgress, child: page);
  }

  /// 进页等待期 (2026-09-27 用户口径「一进就弹窗加载, 会卡一会」)。
  /// 打开已有分析: 页头骨架 + 一行说明, 不再是整页正中一个光秃秃的转圈;
  /// 带着来源新建: 直接进「正在分析」进度卡, 不先闪一下转圈。
  Widget _bootingBody(ThemeData theme) {
    if (widget.seed.analysisId == null) {
      return _sources.isNotEmpty
          ? _firstAnalysisProgress(theme)
          : const Center(child: CircularProgressIndicator());
    }
    return ListView(
      key: const Key('material-analysis-opening-skeleton'),
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      children: [
        Container(
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
                children: [
                  _skeletonBlock(theme, width: 260, height: 48),
                  _skeletonBlock(theme, width: 160, height: 48),
                  _skeletonBlock(theme, width: 200, height: 48),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              _skeletonBlock(theme, height: 52),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        Row(
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                '正在读取这份物料分析的 BOM 与库存结果…',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 骨架占位块：静态底色 (不闪烁、不依赖性能档设置)，形状对齐真实页头。
  Widget _skeletonBlock(
    ThemeData theme, {
    double? width,
    required double height,
  }) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: UtenRadius.mdAll,
    ),
  );

  /// 第一次分析进行中的页内进度卡：服务端要展开全部产品的 BOM 并核对库存，
  /// 期间不再闪出一张空的候选表 (「暂无可分析的已审销售订单产品」)。
  Widget _firstAnalysisProgress(ThemeData theme) {
    final count = _sources.length;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          key: const Key('material-analysis-first-preview-progress'),
          margin: const EdgeInsets.all(UtenSpacing.s16),
          padding: const EdgeInsets.all(UtenSpacing.s16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: UtenRadius.mdAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.insights_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      count > 0
                          ? '正在展开 $count 个产品的 BOM 并核对库存…'
                          : '正在展开 BOM 并核对库存…',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              const LinearProgressIndicator(),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '产品较多时需要几秒钟，算完自动显示物料表，并按货品档案确认好供应方式。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _analysisBody(ThemeData theme) {
    final analysis = _analysis!;
    // 悬浮动作区不占布局空间：列表底部预留透明高度，
    // 让末尾内容能滚到悬浮按钮上方，不被常驻遮挡。
    final actionCount = _bottomActionButtons().length;
    final bottomClearance = actionCount == 0
        // compact 悬浮胶囊避让：滚到底末块要能越过胶囊
        ? math.max(UtenSpacing.s16, UtenCapsuleNavScope.occlusionOf(context))
        : UtenFloatingActionGroup.scrollClearance;
    final headerSections = [
      Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s8),
        child: _analysisHeader(theme, analysis),
      ),
      // 静默刷新确认供应方式期间只给一行小提示，不盖遮罩、不挡查看。
      if (_autoRouteRefreshing)
        Padding(
          key: const Key('material-analysis-route-auto-confirming'),
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: Row(
            children: [
              const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '正在按货品档案确认新出现的供应方式，完成后自动刷新…',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      if (_serverRefreshNotice != null)
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: _serverRefreshBanner(theme, _serverRefreshNotice!),
        ),
      // ADR-117：车间在催 / 已下单的件下面还缺料——常驻提醒，点「去补下单」进补料页。
      if (_childShortageBanner(theme, analysis) case final banner?)
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: banner,
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
  ) {
    final compact = context.breakpoint.isCompact;
    final facts = <Widget>[
      if (analysis.analysisNo != null)
        Tooltip(
          message: '分析编号（计划单号）${analysis.analysisNo}',
          child: _factChip(theme, Icons.tag_outlined, analysis.analysisNo!),
        ),
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
    ];
    final warehouse = SizedBox(width: 260, child: _warehouseField());
    return Container(
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
              // 2026-09-12 用户口径：更新时间框与主仓库框等高。2026-09-27 起不再
              // 帧后量主仓库字段高度再 setState 一次：宽屏把主仓库与事实框排成
              // 同一行、按行高拉伸 (随主题/字号自适应)；手机窄屏各占一行、各按内容高。
              if (compact) ...[
                warehouse,
                ...facts,
              ] else
                IntrinsicHeight(
                  key: const Key('material-analysis-header-facts'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      warehouse,
                      for (final fact in facts) ...[
                        const SizedBox(width: UtenSpacing.s12),
                        Flexible(child: fact),
                      ],
                    ],
                  ),
                ),
              // 查找框常驻顶部卡片（更新时间右侧）；全屏时顶部卡片不可见，
              // 由 _bomToolbarActions 在全屏工具条里再挂一个（共享同一控制器）。
              SizedBox(
                width: compact ? 200 : 240,
                child: UtenSearchBar(
                  key: const Key('material-bom-search'),
                  controller: _bomSearch,
                  hint: _l10n.materialSearchHint,
                  onChanged: _bomSearchChanged,
                ),
              ),
            ],
          ),
          ..._linkedSalesOrdersSection(theme, analysis),
          ..._manualDemandsSection(theme, analysis),
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
  }

  /// 顶部卡片「关联销售订单」区块(ADR-088)。
  ///
  /// 口径：**本张分析的来源行**去重后的订单集合(与服务端 salesCandidates 同一过滤：
  /// 排除 MAKE_COMPONENT / SUBCONTRACT_MAKE 这类子层锚点行)。注意与「进行中」列表
  /// 那一列「关联订单」不是同一口径——那一列还并进了执行段的销售分摊，跨分摊/让单
  /// 会带进不属于本分析来源的订单，数量可能比这里多。
  ///
  /// 点订单编号进的是**专用只读货品清单页**，不是销售订单详情：计划员只需要核对
  /// 订了些什么货，不该看到价格与编辑动作。
  List<Widget> _linkedSalesOrdersSection(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
    final orders = _linkedSalesOrders(analysis);
    if (orders.isEmpty) return const [];
    return [
      const SizedBox(height: UtenSpacing.s8),
      Align(
        key: const Key('material-analysis-linked-sales-orders'),
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: UtenSpacing.s4),
              child: Text(
                '关联销售订单 ${orders.length}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final order in orders)
              ConstrainedBox(
                // 联合分析可能挂几十张订单：每个 chip 硬封宽 + 省略号，
                // 靠 Wrap 换行；窄屏 375 下也不会把顶部卡片撑溢出。
                constraints: const BoxConstraints(maxWidth: 260),
                child: ActionChip(
                  key: ValueKey('linked-sales-order-${order.orderId}'),
                  avatar: Icon(
                    Icons.receipt_long_outlined,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  label: Text(
                    order.clientName == null
                        ? order.billNo
                        : '${order.billNo} · ${order.clientName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  tooltip: '查看该订单的货品清单(只读)',
                  onPressed: () => context.push(
                    RoutePath.productionAnalysisSalesOrder(
                      analysis.analysisId,
                      order.orderId,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ];
  }

  /// 来源行去重出的订单列表(按单号升序，稳定顺序)。
  List<({String orderId, String billNo, String? clientName})>
  _linkedSalesOrders(ProductionMaterialAnalysisView analysis) {
    const childSourceTypes = {
      'MAKE_COMPONENT',
      'SUBCONTRACT_MAKE',
      'AGGREGATE_MAKE',
    };
    final byId =
        <String, ({String orderId, String billNo, String? clientName})>{};
    for (final product in analysis.products) {
      if (childSourceTypes.contains(product.sourceType)) continue;
      final orderId = product.orderId?.trim();
      final billNo = product.orderNo?.trim();
      if (orderId == null || orderId.isEmpty) continue;
      if (billNo == null || billNo.isEmpty) continue;
      byId.putIfAbsent(
        orderId,
        () => (
          orderId: orderId,
          billNo: billNo,
          clientName: product.clientName?.trim().isEmpty ?? true
              ? null
              : product.clientName!.trim(),
        ),
      );
    }
    // List.sort 不保证稳定：单号可能重复(历史导入/跨年重号)，复合 key 保证顺序确定。
    return byId.values.toList()..sort((left, right) {
      final byBillNo = left.billNo.compareTo(right.billNo);
      return byBillNo != 0 ? byBillNo : left.orderId.compareTo(right.orderId);
    });
  }

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
      // 货品档案改了供应方式时版本不变，但能自动确认的行变了：要套用才会静默刷新。
      '${view.pendingAutoConfirmRouteCount}',
      (view.allowedActions.toList()..sort()).join(','),
      view.warehouseId ?? '',
      (view.warehouseIds.toList()..sort()).join(','),
      // 超产默认比例是页面要跟着刷新的读侧事实(ADR-129 预填/汇总格跟随):
      // 版本指纹都不变、只变了默认时也要套用, 否则没人改过的格子停在旧默认。
      (view.overproductionDefaults.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
          .map((entry) => '${entry.key}=${entry.value}')
          .join(','),
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
          product.planExecutionWorkshopId,
          product.planExecutionWorkshopName,
          product.planExecutionResponsibleId,
          product.planExecutionResponsibleName,
          product.owningWarehouseId,
          product.owningWarehouseName,
          product.owningWorkshopId,
          product.owningWorkshopName,
        ].join('|'),
      );
    }
    for (final material in view.materials) {
      parts.add(
        <Object?>[
          material.materialLineId,
          material.owningWarehouseId,
          material.owningWarehouseName,
          material.owningWorkshopId,
          material.owningWorkshopName,
          material.requiredQty,
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
          material.priorityMakeSupplementQty,
          material.priorityFulfilledQty,
          material.selectedWarehousesAvailableQty,
          material.selectedOtherWarehouseTransferableQty,
          material.publicSurplusApprovedInboundQty,
          material.publicSurplusRemainingQty,
          material.sharedFutureClaimedQty,
          material.sharedFuturePendingQty,
          material.lateSharedFutureAvailableQty,
          material.additionalSupplyRecommendedQty,
          material.sharedFutureClaimableQty,
          material.flowStage,
          material.planningUncoveredQty,
          material.netShortageQty,
          material.preparationAvailableQty,
          material.preparationAdoptedQty,
          material.preparationPoolKey,
          material.preparationSharedAvailableQty,
          material.preparationOwnedAvailableQty,
          material.preparationUncoveredBeforeSharedQty,
          material.preparationAdoptableSharedQty,
          material.preparationSharedSupplySlices
              ?.map((slice) => [slice.key, slice.availableQty, slice.adoptable])
              .toList(),
          material.aggregatePreparation?.requiredQty,
          material.aggregatePreparation?.orderedQty,
          material.aggregatePreparation?.allocatedOrderedQty,
          material.aggregatePreparation?.totalOrderedQty,
          material.aggregatePreparation?.orderedQtyExact,
          material.aggregatePreparation?.planningUncoveredQty,
          material.aggregatePreparation?.netShortageQty,
          material.aggregatePreparation?.targetMaterialLineIds.join(','),
          material.aggregatePreparation?.actionable,
          material.plannedOutputQty,
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
