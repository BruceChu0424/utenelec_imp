part of 'production_material_analysis_page.dart';

/// Preparation is organized by route; issue state remains inside each list.
/// Commands continue to use the host's permission, version and idempotency flow.
enum _AnalysisBucket { buy, subcontract, workshop }

enum _PreparationTaskFilter { pending, issued, blocked }

extension _AnalysisBucketX on _AnalysisBucket {
  String countLabel(AppLocalizations l10n) => switch (this) {
    _AnalysisBucket.buy => l10n.materialTaskBuy,
    _AnalysisBucket.subcontract => l10n.materialTaskSubcontract,
    _AnalysisBucket.workshop => l10n.materialTaskWorkshop,
  };

  String semanticHint(AppLocalizations l10n) => switch (this) {
    _AnalysisBucket.buy => l10n.materialTaskBuyHint,
    _AnalysisBucket.subcontract => l10n.materialTaskSubcontractHint,
    _AnalysisBucket.workshop => l10n.materialTaskWorkshopHint,
  };

  MaterialSupplyRoute? get supplyRoute => switch (this) {
    _AnalysisBucket.buy => MaterialSupplyRoute.buy,
    _AnalysisBucket.subcontract => MaterialSupplyRoute.subcontract,
    _AnalysisBucket.workshop => null,
  };
}

/// 详情页发起的批量动作请求（pop 回宿主页执行）。写动作都在宿主页上下文里
/// 继续：数量确认弹窗 / 计划向导 / 批量进度条 / 冲突恢复提示。
class _BucketActionRequest {
  _BucketActionRequest.buy(this.groupKeys, {this.qtyByActionGroupKey})
    : planDrafts = null,
      candidateInputs = null,
      type = _BucketActionType.buy;
  _BucketActionRequest.subcontract(
    Set<String>? keys, {
    this.qtyByActionGroupKey,
  }) : groupKeys = keys,
       planDrafts = null,
       candidateInputs = null,
       type = _BucketActionType.subcontractOnly;

  /// 2026-09-05 用户口径：车间桶右下角只留一个「创建生产计划」——所有自制
  /// 行（顶层/子件/候选）统一填「数量+车间+负责人」后一次下发（ADR-071：
  /// 单次原子调用，候选建子件任务+逐行出计划+可选审核一个事务完成）。
  _BucketActionRequest.createProductionPlans({
    this.candidateInputs,
    this.planDrafts,
  }) : groupKeys = null,
       qtyByActionGroupKey = null,
       type = _BucketActionType.createProductionPlans;

  final _BucketActionType type;

  /// BUY / 委外 / 自制桶：目标操作组键（_MaterialGroup.key）。
  final Set<String>? groupKeys;

  /// 行内编辑的下达数量（键=actionGroupKey，值=表格里的文本）；空=用默认
  /// 全量（本批缺口 − 已在途）。2026-09-05 起数量修改统一在表格里完成。
  final Map<String, String>? qtyByActionGroupKey;

  /// 生成计划：已有产品行（顶层/子件）的输入——数量 + 车间 + 负责人。
  final List<_BucketPlanDraft>? planDrafts;

  /// 创建生产计划：候选行（含顶层同构候选）的输入——按行内填写的数量/
  /// 车间/负责人直接为新子件建任务并生成计划（2026-09-05 用户口径：
  /// 自制件不分子层级/齐套，统一「数量+车间+负责人→下发」）。
  final List<_BucketCandidatePlanInput>? candidateInputs;
}

enum _BucketActionType { buy, subcontractOnly, createProductionPlans }

/// 创建生产计划的候选行输入（2026-09-05：候选与产品同表单，建任务后按
/// 这些输入直接生成新子件的计划）。
class _BucketCandidatePlanInput {
  const _BucketCandidatePlanInput({
    required this.materialLineId,
    required this.qty,
    required this.departmentId,
    required this.workshopName,
    required this.workerId,
  });

  final String materialLineId;
  final double qty;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;
}

/// 生成计划的已有产品行输入（可安排详情页收集，宿主页校验后单次下达）。
class _BucketPlanDraft {
  const _BucketPlanDraft({
    required this.analysisLineId,
    required this.qty,
    required this.departmentId,
    required this.workshopName,
    required this.workerId,
  });

  final String analysisLineId;
  final double qty;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;
}

/// 详情页表格的一行：产品 / 自制候选 / 物料操作组 三种形态共用一张表。
class _BucketRow {
  _BucketRow.product(ProductionMaterialAnalysisProduct value)
    : id = value.analysisLineId,
      product = value,
      candidate = null,
      group = null;
  _BucketRow.candidate(_PendingMakeCandidate value)
    : id = value.material.materialLineId,
      product = null,
      candidate = value,
      group = null;
  _BucketRow.group(_MaterialGroup value)
    : id = value.key,
      product = null,
      candidate = null,
      group = value;
  final String id;
  final ProductionMaterialAnalysisProduct? product;
  final _PendingMakeCandidate? candidate;
  final _MaterialGroup? group;
}

/// 可安排桶的可编辑计划行（UtenEditableGrid）：本批数量 + 生产车间 + 负责人。
/// 车间默认来自正式排产确认学习（defaultWorkshops），带入即黄标提醒核对；
/// 负责人默认来自排产下钻 seed。候选行不填计划输入（先创建子件任务）。
class _BucketPlanRow extends EditableGridRow {
  _BucketPlanRow(
    this.origin, {
    required String defaultQtyText,
    ValueChanged<String>? onQtyChanged,
    String? defaultDepartmentId,
    String? defaultDepartmentName,
    String? defaultWorkerId,
    String? defaultWorkerName,
  }) : workshopAutofilled = defaultDepartmentId != null,
       workerAutofilled = defaultWorkerId != null {
    qty.text = defaultQtyText;
    departmentId.value = defaultDepartmentId;
    departmentName = defaultDepartmentName;
    workerId.value = defaultWorkerId;
    workerName = defaultWorkerName;
    if (onQtyChanged != null) {
      qty.addListener(() => onQtyChanged(qty.text));
    }
  }

  final _BucketRow origin;
  final TextEditingController qty = TextEditingController();

  /// 行标识（产品/候选的稳定 id，与 [_BucketRow.id] 同源）。
  String get id => origin.id;

  final ValueNotifier<String?> departmentId = ValueNotifier<String?>(null);
  String? departmentName;

  /// 车间是否学习/预填带入（黄框提醒核对，手选后清除）。
  bool workshopAutofilled;

  final ValueNotifier<String?> workerId = ValueNotifier<String?>(null);
  String? workerName;
  bool workerAutofilled;

  bool get isProduct => origin.product != null;

  @override
  void dispose() {
    qty.dispose();
    departmentId.dispose();
    workerId.dispose();
    super.dispose();
  }
}

typedef _BucketPlanInputDraft = ({
  String qty,
  String? departmentId,
  String? departmentName,
  String? workerId,
  String? workerName,
  bool workshopAutofilled,
  bool workerAutofilled,
  bool selected,
});

String _bucketQtyText(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// 分桶详情页：全屏表格 + 多选 + 批量动作。数据取宿主页当前快照（详情页
/// 在前台时宿主页轮询暂停，快照稳定；动作执行回到宿主页后自然刷新）。
class _MaterialAnalysisBucketPage extends StatefulWidget {
  const _MaterialAnalysisBucketPage({required this.host, required this.bucket});

  /// 宿主页状态（分桶投影/权限/执行编排都在宿主页链上；运行时实例永远是
  /// 最终实现类 _ProductionMaterialAnalysisPageState）。
  final _MaterialAnalysisProductTasksState host;
  final _AnalysisBucket bucket;

  @override
  State<_MaterialAnalysisBucketPage> createState() =>
      _MaterialAnalysisBucketPageState();
}

class _MaterialAnalysisBucketPageState
    extends State<_MaterialAnalysisBucketPage> {
  final Set<String> _selectedIds = {};
  _PreparationTaskFilter _taskFilter = _PreparationTaskFilter.pending;
  int _preparedChildCount = 0;
  final Map<String, _BucketPlanInputDraft> _planInputDrafts = {};

  /// 采购/委外桶的表头筛选（进度/缺口；视图级过滤，切段清空）。
  final Map<String, String?> _tableFilters = {};

  /// 采购/委外桶的行内「下达数量」编辑（键=actionGroupKey）。2026-09-05 起
  /// 数量修改统一在表格里完成，不再弹逐行数量对话框；空文本=按默认全量
  /// （本批缺口 − 已在途需求）提交。
  final Map<String, TextEditingController> _submitQtyControllers = {};

  /// 该行是否可编辑下达数量（仅支持 actionGroupKey 提交单元；旧响应按
  /// 逐行 LINE 提交、组级编辑无法对应，退化为只读展示默认量）。
  bool _rowQtyEditable(_BucketRow row) =>
      _canAct &&
      _taskFilter == _PreparationTaskFilter.pending &&
      (row.group?.representative.actionGroupKey?.isNotEmpty ?? false);

  TextEditingController _submitQtyControllerOf(_MaterialGroup group) {
    final key = group.representative.actionGroupKey!;
    var controller = _submitQtyControllers[key];
    if (controller == null) {
      controller = TextEditingController(
        text: _bucketQtyText(
          _host._residualSubmitQty(group, _bucket.supplyRoute!),
        ),
      );
      _submitQtyControllers[key] = controller;
    }
    return controller;
  }

  void _disposeSubmitQtyControllers() {
    for (final controller in _submitQtyControllers.values) {
      controller.dispose();
    }
    _submitQtyControllers.clear();
  }

  bool get _usesPlanGrid =>
      _bucket == _AnalysisBucket.workshop &&
      _taskFilter == _PreparationTaskFilter.pending &&
      _planGrid != null;

  List<_BucketRow> _filterRows(List<_BucketRow> rows) => rows
      .where((row) {
        return switch (_taskFilter) {
          _PreparationTaskFilter.pending => _host._bucketRowHasPending(
            row,
            _bucket,
          ),
          _PreparationTaskFilter.issued => _host._bucketRowHasIssued(
            row,
            _bucket,
          ),
          _PreparationTaskFilter.blocked => _host._bucketRowNeedsAttention(
            row,
            _bucket,
          ),
        };
      })
      .toList(growable: false);

  bool _canSelectTask(_BucketRow row) =>
      _taskFilter == _PreparationTaskFilter.pending &&
      _host._bucketRowCanAct(row, _bucket);

  /// 只读桶（MasterDataTableView）的分页：每页 [_pageSize] 行，只构建当页。
  /// 几百上千产品的分析里 waiting/buy 桶动辄数千行——一次性构建在网页端
  /// （CanvasKit 布局更慢）是分钟级卡死；分页后翻页即切页。勾选按业务 id
  /// 由本页持有，跨页天然保留。
  static const int _pageSize = 200;
  int _pageNo = 1;

  /// 可安排桶的可编辑计划行控制器（产品行填数量/车间/负责人；候选行只勾选）。
  UtenEditableGridController<_BucketPlanRow>? _planGrid;

  _MaterialAnalysisProductTasksState get _host => widget.host;
  _AnalysisBucket get _bucket => widget.bucket;

  @override
  void initState() {
    super.initState();
    if (_bucket == _AnalysisBucket.workshop &&
        (_host._canGenerate || _host._canNotify)) {
      _planGrid = UtenEditableGridController<_BucketPlanRow>();
      _buildPlanRows();
      unawaited(_loadWorkshopDefaults());
    }
  }

  @override
  void dispose() {
    _disposeSubmitQtyControllers();
    _planGrid?.dispose();
    super.dispose();
  }

  /// The full set stays lightweight. Controllers/notifiers are created only
  /// for the loaded window and then owned exactly once by [_planGrid].
  List<_BucketRow> _allPlanOrigins = const [];
  int _planVisibleLimit = 100;
  Map<
    String,
    ({
      String departmentId,
      String? departmentName,
      String? workerId,
      String? workerName,
    })
  >
  _workshopDefaults = const {};
  Map<String, ({String? id, String? name})> _workshopManagers = const {};

  /// 宿主页「创建子件任务」后自动选中的子件（装载到可见行时恢复勾选）。
  Set<String> _presetSelectedIds = const {};

  void _buildPlanRows({Set<String> preferredIds = const {}}) {
    final host = _host;
    final grid = _planGrid!;
    for (final row in grid.rows) {
      _planInputDrafts[row.id] = (
        qty: row.qty.text,
        departmentId: row.departmentId.value,
        departmentName: row.departmentName,
        workerId: row.workerId.value,
        workerName: row.workerName,
        workshopAutofilled: row.workshopAutofilled,
        workerAutofilled: row.workerAutofilled,
        selected: grid.isSelected(row),
      );
    }
    final origins = host
        ._bucketRows(_AnalysisBucket.workshop)
        .where(
          (row) => host._bucketRowHasPending(row, _AnalysisBucket.workshop),
        )
        .toList(growable: false);
    final availableIds = origins.map((row) => row.id).toSet();
    _planInputDrafts.removeWhere((id, _) => !availableIds.contains(id));
    _presetSelectedIds = {
      ...host._selectedPlanLineIds.where(availableIds.contains),
      for (final entry in _planInputDrafts.entries)
        if (entry.value.selected) entry.key,
    };
    final firstIds = preferredIds.isEmpty ? _presetSelectedIds : preferredIds;
    _allPlanOrigins = [
      for (final row in origins)
        if (firstIds.contains(row.id)) row,
      for (final row in origins)
        if (!firstIds.contains(row.id)) row,
    ];
    // Keep only the loaded window as controllers; shifted rows retain lightweight drafts.
    final replacements = _allPlanOrigins
        .take(_planVisibleLimit)
        .map(_newPlanRow)
        .toList(growable: false);
    grid.clearSelection();
    grid.replaceAll(replacements);
    _applyPresetSelection();
  }

  _BucketPlanRow _newPlanRow(_BucketRow origin) {
    final host = _host;
    final saved = _planInputDrafts[origin.id];
    final product = origin.product;
    final candidate = origin.candidate;
    final goodsId = product?.goodsId ?? candidate?.material.goodsId;
    final workshop = goodsId == null ? null : _workshopDefaults[goodsId];
    final seedWorkerId = product == null ? null : host.widget.seed.workerId;
    final seedWorkerName =
        (seedWorkerId?.isNotEmpty ?? false) &&
            host.ref.read(masterNameServiceProvider).employee(seedWorkerId!) !=
                '—'
        ? host.ref.read(masterNameServiceProvider).employee(seedWorkerId)
        : null;
    final manager = workshop == null
        ? null
        : _workshopManagers[workshop.departmentId];
    // 2026-09-05 用户口径：候选行与产品行同一张表单——候选默认数量=该节点
    // 剩余下达量（本批缺口−已在途，子件任务按全量接管所有权，可改小分批）。
    final row = _BucketPlanRow(
      origin,
      defaultQtyText:
          saved?.qty ??
          (product != null
              ? host._planBatchDraftText(product)
              : candidate?.group != null
              ? host._qty(
                  host._residualSubmitQty(candidate!.group!, candidate.route),
                )
              : ''),
      onQtyChanged: product == null
          ? null
          : (value) =>
                host._rememberPlanBatchQty(product.analysisLineId, value),
      defaultDepartmentId: saved != null
          ? saved.departmentId
          : workshop?.departmentId,
      defaultDepartmentName: saved != null
          ? saved.departmentName
          : workshop?.departmentName,
      // 负责人优先级：显式路线种子 > 学习记忆（V488） > 车间主管（组织树）。
      defaultWorkerId: saved != null
          ? saved.workerId
          : seedWorkerId ?? workshop?.workerId ?? manager?.id,
      defaultWorkerName: saved != null
          ? saved.workerName
          : seedWorkerName ?? workshop?.workerName ?? manager?.name,
    );
    if (saved != null) {
      row.workshopAutofilled = saved.workshopAutofilled;
      row.workerAutofilled = saved.workerAutofilled;
    }
    return row;
  }

  void _applyPresetSelection() {
    if (_presetSelectedIds.isEmpty) return;
    for (final row in _planGrid!.rows) {
      if (_presetSelectedIds.contains(row.id) &&
          _host._bucketRowCanAct(row.origin, _bucket)) {
        _planGrid!.setSelected([row], true);
      }
    }
  }

  void _showMorePlanRows() {
    final loaded = _planGrid!.length;
    final next = (loaded + 100).clamp(0, _allPlanOrigins.length);
    if (next == loaded) return;
    _planVisibleLimit = next;
    _planGrid!.addRows(
      _allPlanOrigins.skip(loaded).take(next - loaded).map(_newPlanRow),
    );
    _applyPresetSelection();
    setState(() {});
  }

  /// 车间默认 = 正式排产确认学习（按货品），带入即黄标提醒核对；
  /// 负责人默认优先「学习出的负责人」（V488：上次人工选择的在职员工），
  /// 无记忆时才带出组织树上该车间的负责人（manager）。
  Future<void> _loadWorkshopDefaults() async {
    final goodsIds = <String>{};
    for (final origin in _allPlanOrigins) {
      final goodsId =
          origin.product?.goodsId ?? origin.candidate?.material.goodsId;
      if (goodsId?.isNotEmpty == true) goodsIds.add(goodsId!);
    }
    if (goodsIds.isEmpty) return;
    final results = await Future.wait([
      _host.ref
          .read(productionPlanRepositoryProvider)
          .defaultWorkshops(goodsIds)
          .catchError(
            (_) =>
                const <
                  String,
                  ({
                    String departmentId,
                    String? departmentName,
                    String? workerId,
                    String? workerName,
                  })
                >{},
          ),
      _workshopTreeOrNull(),
    ]);
    if (!mounted) return;
    final defaults =
        results[0]
            as Map<
              String,
              ({
                String departmentId,
                String? departmentName,
                String? workerId,
                String? workerName,
              })
            >;
    final workshopTree = results[1] as List<DepartmentNode>;
    _workshopDefaults = defaults;
    _workshopManagers = {
      for (final node in workshopTree)
        if (node.managerId?.isNotEmpty == true)
          node.id: (id: node.managerId, name: node.managerName),
    };
    var changed = false;
    for (final row in _planGrid!.rows) {
      // 2026-09-05：候选行与产品行同表单，学习默认车间/负责人同样带出。
      final goodsId =
          row.origin.product?.goodsId ?? row.origin.candidate?.material.goodsId;
      final picked = row.departmentId.value == null ? defaults[goodsId] : null;
      if (picked != null) {
        row.departmentId.value = picked.departmentId;
        row.departmentName = picked.departmentName;
        row.workshopAutofilled = true;
        changed = true;
        // 学习记忆带负责人（V488）：与车间一起带出，黄标提醒核对。
        if ((row.workerId.value == null || row.workerId.value!.isEmpty) &&
            picked.workerId != null) {
          row.workerId.value = picked.workerId;
          row.workerName = picked.workerName;
          row.workerAutofilled = true;
        }
      }
      // 负责人兜底：有车间还没负责人 → 带出组织树车间负责人（黄标提醒核对）。
      final departmentId = row.departmentId.value;
      if (departmentId != null &&
          (row.workerId.value == null || row.workerId.value!.isEmpty)) {
        final manager = _workshopManagers[departmentId];
        if (manager != null) {
          row.workerId.value = manager.id;
          row.workerName = manager.name;
          row.workerAutofilled = true;
          changed = true;
        }
      }
    }
    if (changed) setState(() {});
  }

  Future<List<DepartmentNode>> _workshopTreeOrNull() async {
    // 直接读稳定的部门仓库并复用与 productionWorkshopTreeProvider 同款的
    // 过滤——autoDispose provider 被一次性 read(.future) 时会在请求中途被
    // 回收，Future 永不完成（真实应用默认车间/负责人带不出的隐患）。
    try {
      final tree = await _host.ref.read(departmentRepositoryProvider).tree();
      return findDepartmentByCode(tree, kDeptCodeProduction)?.children ??
          const [];
    } catch (_) {
      return const [];
    }
  }

  /// 组织树上该车间的负责人（未维护返回 null）。
  ({String? id, String? name})? _workshopManagerOf(
    List<DepartmentNode> tree,
    String? departmentId,
  ) {
    if (departmentId == null || departmentId.isEmpty) return null;
    for (final node in tree) {
      if (node.id == departmentId && node.managerId?.isNotEmpty == true) {
        return (id: node.managerId, name: node.managerName);
      }
    }
    return null;
  }

  /// 执行批量动作（2026-09-04 修订）：详情页**保持在前台**——宿主页的编排
  /// （数量弹窗/分批/幂等/409 恢复）经 root Navigator 叠在本页之上。
  /// 例外：`createProductionPlans`（ADR-71 单次原子下达）先返回宿主页再执行
  /// ——提交遮罩挂在宿主页 Stack 上（留在本页会被不透明路由盖住不可见），
  /// 生成是终态动作，结果对话框也在宿主页上下文里展示。
  /// [_running] 覆盖弹窗关闭到请求返回之间的空窗（宿主页 busy 不通知本页），
  /// 防止批量进度期间重复点提交。
  Future<void> _run(_BucketActionRequest request) async {
    if (_running) return;
    // 2026-09-11：下达车间**不再先 pop 回物料分析再加载**。原来是「关掉本页 →
    // 宿主页转圈 → 弹结果」，用户看到的是「点了下达，页面自己退回去，然后在那边
    // 转半天」。现在与下达采购/委外同一条路径：本页显示进度、原地刷新行集，
    // 结果弹层（root Navigator）照常叠在本页之上。
    final previousProductIds = {
      for (final product
          in _host._analysis?.products ??
              const <ProductionMaterialAnalysisProduct>[])
        product.analysisLineId,
    };
    setState(() => _running = true);
    try {
      await _host._executeBucketAction(request);
    } finally {
      if (mounted) {
        final preparedIds = {
          for (final product
              in _host._analysis?.products ??
                  const <ProductionMaterialAnalysisProduct>[])
            if (!previousProductIds.contains(product.analysisLineId) &&
                (product.sourceType == 'MAKE_COMPONENT' ||
                    product.sourceType == 'SUBCONTRACT_MAKE'))
              product.analysisLineId,
        };
        if (preparedIds.isNotEmpty) _preparedChildCount = preparedIds.length;
        if (_bucket == _AnalysisBucket.workshop &&
            (_host._canGenerate || _host._canNotify)) {
          _taskFilter = _PreparationTaskFilter.pending;
          _buildPlanRows(preferredIds: preparedIds);
          if (preparedIds.isNotEmpty) unawaited(_loadWorkshopDefaults());
        }
        setState(() {
          _selectedIds.clear();
          // 动作后快照已变（缺口/在途重算）：编辑值失效，恢复默认全量。
          _disposeSubmitQtyControllers();
          _running = false;
        });
        // 下达车间是终态动作（本批行已变成计划）：结果弹层看完后回物料分析。
        // 与从前唯一的差别是**先办完再退**，而不是先退回去再让宿主页转圈。
        if (request.type == _BucketActionType.createProductionPlans &&
            mounted) {
          Navigator.of(context).pop();
        }
      }
    }
  }

  bool _running = false;

  bool get _hasWriteAction => _canAct;

  /// 动作执行窗口（含宿主页 busy 与本页 _running——宿主页 busy 变化不通知
  /// 本页重建，故两态都压住批量入口）。
  bool get _actionsLocked => _host._busy || _running;

  bool get _canAct =>
      _taskFilter == _PreparationTaskFilter.pending &&
      switch (_bucket) {
        _AnalysisBucket.workshop => _host._canGenerate || _host._canNotify,
        _AnalysisBucket.buy || _AnalysisBucket.subcontract => _host._canNotify,
      };

  void _submitMaterialBucket(Set<String> selectedIds) {
    if (!_canAct || _actionsLocked) return;
    final rows = _filterRows(_host._bucketRows(_bucket));
    final allowedRows = [
      for (final row in rows)
        if (selectedIds.contains(row.id) && _canSelectTask(row)) row,
    ];
    if (allowedRows.isEmpty) return;
    // 行内编辑值（键=actionGroupKey）；未编辑/不可编辑的行由宿主按默认
    // 全量（本批缺口 − 已在途）提交。
    final qtyByActionGroupKey = <String, String>{};
    for (final row in allowedRows) {
      final group = row.group;
      final actionGroupKey = group?.representative.actionGroupKey;
      if (group == null || actionGroupKey == null || actionGroupKey.isEmpty) {
        continue;
      }
      final controller = _submitQtyControllers[actionGroupKey];
      if (controller != null) {
        qtyByActionGroupKey[actionGroupKey] = controller.text;
      }
    }
    final allowedIds = {for (final row in allowedRows) row.id};
    switch (_bucket) {
      case _AnalysisBucket.buy:
        _run(
          _BucketActionRequest.buy(
            allowedIds,
            qtyByActionGroupKey: qtyByActionGroupKey,
          ),
        );
      case _AnalysisBucket.subcontract:
        _run(
          _BucketActionRequest.subcontract(
            allowedIds,
            qtyByActionGroupKey: qtyByActionGroupKey,
          ),
        );
      case _AnalysisBucket.workshop:
        return;
    }
  }

  // ===== 可安排桶：计划行校验与两类批量动作 =====

  List<_BucketPlanRow> get _selectedPlanRows =>
      _planGrid?.selectedRows ?? const [];

  /// 创建生产计划前校验：数量、车间、负责人逐行齐备（产品行与候选行同一
  /// 张表单，第一处错误点名提示）。数量上限=该行剩余需求——齐不齐料是车间
  /// 侧的事（ADR-71），计划侧不再按库存卡量。
  String? _validatePlanRows(List<_BucketPlanRow> rows) {
    for (final row in rows) {
      final product = row.origin.product;
      final candidate = row.origin.candidate;
      final name =
          product?.goodsName ??
          product?.goodsCode ??
          candidate?.material.goodsName ??
          candidate?.material.goodsCode ??
          row.id;
      final raw = row.qty.text.trim();
      final qty = double.tryParse(raw);
      if (raw.isEmpty || qty == null || !qty.isFinite || qty <= 0) {
        return '「$name」本批生产数量必须大于 0';
      }
      final candidateGroup = candidate?.group;
      final max =
          product?.remainingQty ??
          (candidateGroup != null && candidate != null
              ? _host._residualSubmitQty(candidateGroup, candidate.route)
              : null);
      if (max != null && qty > max) {
        return '「$name」本批生产数量不能超过剩余需求 '
            '${_host._qty(max)} 个';
      }
      if (row.departmentId.value == null || row.departmentId.value!.isEmpty) {
        return '「$name」尚未选择生产车间（有默认车间的已自动带出，请核对）';
      }
      if (row.workerId.value == null || row.workerId.value!.isEmpty) {
        return '「$name」尚未选择负责人';
      }
    }
    return null;
  }

  /// 2026-09-05 用户口径（ADR-71）：右下角只有一个「创建生产计划(N)」——
  /// 所有自制行（顶层/子件/候选）统一填「本批数量+生产车间+负责人」后
  /// 单次原子下发：服务端一个事务完成建子件任务+出计划+可选审核。
  void _submitCreateProductionPlans() {
    final selected = _selectedPlanRows;
    if (selected.isEmpty) {
      context.appInfo('请先勾选要创建生产计划的行');
      return;
    }
    final error = _validatePlanRows(selected);
    if (error != null) {
      context.appError(error);
      return;
    }
    final productDrafts = <_BucketPlanDraft>[
      for (final row in selected.where((row) => row.isProduct))
        _BucketPlanDraft(
          analysisLineId: row.id,
          qty: double.parse(row.qty.text.trim()),
          departmentId: row.departmentId.value,
          workshopName: row.departmentName,
          workerId: row.workerId.value,
        ),
    ];
    final candidateInputs = <_BucketCandidatePlanInput>[];
    for (final row in selected.where((row) => !row.isProduct)) {
      final candidate = row.origin.candidate!;
      if (candidate.group == null) continue;
      candidateInputs.add(
        _BucketCandidatePlanInput(
          materialLineId: candidate.material.materialLineId,
          qty: double.parse(row.qty.text.trim()),
          departmentId: row.departmentId.value,
          workshopName: row.departmentName,
          workerId: row.workerId.value,
        ),
      );
    }
    if (productDrafts.isEmpty && candidateInputs.isEmpty) {
      context.appInfo('所选候选当前不可创建，请刷新后重试');
      return;
    }
    _run(
      _BucketActionRequest.createProductionPlans(
        candidateInputs: candidateInputs,
        planDrafts: productDrafts,
      ),
    );
  }

  List<Widget> _planBatchActions(BuildContext context) {
    final controller = _planGrid!;
    final total = controller.selectedRows.length;
    // 未选任何行不占位（0 计数不渲染动作按钮）。
    if (total == 0) return const [];
    final editable = !_actionsLocked && _host._canGenerate;
    return [
      // 批量赋值（2026-09-11，对齐「新建采购」的多选统一设置条款）：选中一批行后
      // 只选一次车间/负责人/数量就写进全部选中行——几十行逐行点开选择器是纯体力活。
      // 批量写入视同「已核对」，清掉学习预填的黄标（与单行手选同口径）。
      UtenButton(
        key: const Key('material-analysis-bucket-batch-workshop'),
        type: UtenButtonType.tonal,
        size: UtenButtonSize.large,
        icon: Icons.factory_rounded,
        onPressed: editable ? () => _batchPickWorkshop(controller) : null,
        onDisabledTap: !_host._canGenerate
            ? () => context.appWarning('没有生成生产计划权限')
            : null,
        child: Text('批量设车间($total)'),
      ),
      UtenButton(
        key: const Key('material-analysis-bucket-batch-worker'),
        type: UtenButtonType.tonal,
        size: UtenButtonSize.large,
        icon: Icons.person_outline_rounded,
        onPressed: editable ? () => _batchPickWorker(controller) : null,
        child: Text('批量设负责人($total)'),
      ),
      UtenButton(
        key: const Key('material-analysis-bucket-batch-qty'),
        type: UtenButtonType.tonal,
        size: UtenButtonSize.large,
        icon: Icons.numbers_rounded,
        onPressed: editable ? () => _batchSetPlanQty(controller) : null,
        child: Text('批量设数量($total)'),
      ),
      UtenButton(
        key: const Key('material-analysis-bucket-action-ready'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: Icons.factory_outlined,
        onPressed: _actionsLocked || !_host._canGenerate
            ? null
            : _submitCreateProductionPlans,
        onDisabledTap: !_host._canGenerate
            ? () => context.appWarning('没有生成生产计划权限')
            : null,
        child: Text('创建生产计划($total)'),
      ),
    ];
  }

  /// 该计划行的默认数量文案（= 剩余需求；与建行时的 defaultQtyText 同源）。
  String _planRowDefaultQty(_BucketPlanRow row) {
    final product = row.origin.product;
    if (product != null) return _host._qty(product.remainingQty);
    final candidate = row.origin.candidate;
    final group = candidate?.group;
    if (candidate == null || group == null) return '';
    return _host._qty(_host._residualSubmitQty(group, candidate.route));
  }

  /// 计划表行右键菜单：整组清空可填内容 + 一键填满剩余数量。
  /// 作用对象是**当前选择集**（组件弹菜单前已完成选中归位）。
  List<UtenContextMenuEntry> _planRowMenu(
    BuildContext context,
    List<_BucketPlanRow> selected,
  ) {
    final n = selected.length;
    final editable = !_actionsLocked && _host._canGenerate && n > 0;
    return [
      UtenMenuItem(
        label: '填满剩余数量 ($n)',
        icon: Icons.playlist_add_check_rounded,
        enabled: editable,
        onTap: () => setState(() {
          for (final row in selected) {
            row.qty.text = _planRowDefaultQty(row);
          }
        }),
      ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: '清空本批数量 ($n)',
        icon: Icons.backspace_outlined,
        enabled: editable,
        onTap: () => setState(() {
          for (final row in selected) {
            row.qty.clear();
          }
        }),
      ),
      UtenMenuItem(
        label: '清空车间和负责人 ($n)',
        icon: Icons.layers_clear_outlined,
        enabled: editable,
        onTap: () => setState(() {
          for (final row in selected) {
            _clearPlanRowAssignment(row);
          }
        }),
      ),
      UtenMenuItem(
        label: '清空全部可填内容 ($n)',
        icon: Icons.cleaning_services_outlined,
        enabled: editable,
        destructive: true,
        onTap: () => setState(() {
          for (final row in selected) {
            row.qty.clear();
            _clearPlanRowAssignment(row);
          }
        }),
      ),
    ];
  }

  void _clearPlanRowAssignment(_BucketPlanRow row) {
    row.departmentId.value = null;
    row.departmentName = null;
    row.workshopAutofilled = false;
    row.workerId.value = null;
    row.workerName = null;
    row.workerAutofilled = false;
  }

  /// 选一次车间写进所有选中行。换车间时的负责人联动与单行 [_pickWorkshop] 同口径
  /// （学习记忆优先，其次组织树车间负责人），不让批量与单行长出两套行为。
  Future<void> _batchPickWorkshop(
    UtenEditableGridController<_BucketPlanRow> controller,
  ) async {
    final rows = controller.selectedRows;
    if (rows.isEmpty) return;
    final workshopTree = await _workshopTreeOrNull();
    if (!mounted) return;
    final workshopIds = {for (final node in workshopTree) node.id};
    final picked = await showUtenDepartmentPickerPanel(
      context,
      tree: workshopTree,
      selectablePredicate: (node) => workshopIds.contains(node.id),
    );
    final selection = picked == null || picked.isEmpty ? null : picked.first;
    if (selection == null || !mounted) return;
    setState(() {
      for (final row in rows) {
        if (row.departmentId.value != selection.id) {
          final goodsId =
              row.origin.product?.goodsId ??
              row.origin.candidate?.material.goodsId;
          final learned = goodsId == null ? null : _workshopDefaults[goodsId];
          final rememberedWorker =
              learned != null &&
                  learned.departmentId == selection.id &&
                  learned.workerId != null
              ? (id: learned.workerId, name: learned.workerName)
              : null;
          final manager =
              rememberedWorker ??
              _workshopManagerOf(workshopTree, selection.id);
          row.workerId.value = manager?.id;
          row.workerName = manager?.name;
          row.workerAutofilled = manager != null;
        }
        row.departmentId.value = selection.id;
        row.departmentName = selection.name;
        row.workshopAutofilled = false; // 批量显式设置 = 已核对
      }
    });
  }

  /// 选一次负责人写进所有选中行。候选默认按**第一行的车间**收敛（整批通常同车间）；
  /// 输入关键词后转全员检索，与单行选择器同口径。
  Future<void> _batchPickWorker(
    UtenEditableGridController<_BucketPlanRow> controller,
  ) async {
    final rows = controller.selectedRows;
    if (rows.isEmpty) return;
    final scopeDepartmentId = rows.first.departmentId.value;
    final picked = await showUtenEmployeePickerPanel(
      context,
      title: '选择生产负责人',
      departmentName: rows.first.departmentName,
      loader: (keyword) async {
        final result = await _host.ref
            .read(employeeRepositoryProvider)
            .list(
              size: 30,
              search: keyword,
              departmentId: (keyword?.trim().isEmpty ?? true)
                  ? scopeDepartmentId
                  : null,
              includeSubtree: true,
            );
        return [
          for (final employee in result.items)
            UtenEmployeePickerItem(
              id: employee.id,
              name: employee.fullName,
              employeeCode: employee.code,
              departmentName: employee.departmentName,
            ),
        ];
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      for (final row in rows) {
        row.workerId.value = picked.id;
        row.workerName = picked.name;
        row.workerAutofilled = false; // 批量显式设置 = 已核对
      }
    });
  }

  /// 一次输入数量写进所有选中行。留空 = 各行按自己的剩余需求填满——整批数量
  /// 各不相同是常态，硬写同一个数往往还要逐行改回去。
  Future<void> _batchSetPlanQty(
    UtenEditableGridController<_BucketPlanRow> controller,
  ) async {
    final rows = controller.selectedRows;
    if (rows.isEmpty) return;
    final input = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('批量设置本批数量（${rows.length} 行）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('留空并确认 = 每行各自填满剩余需求；填数字 = 每行都用这个数量。'),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const Key('material-analysis-bucket-batch-qty-input'),
              controller: input,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const UtenInputDecoration(
                InputDecoration(isDense: true, hintText: '留空=各自填满剩余'),
              ),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('写入'),
          ),
        ],
      ),
    );
    final text = input.text.trim();
    input.dispose();
    if (confirmed != true || !mounted) return;
    final value = text.isEmpty ? null : double.tryParse(text);
    if (text.isNotEmpty && (value == null || !value.isFinite || value <= 0)) {
      context.appWarning('本批数量必须是大于 0 的数字');
      return;
    }
    setState(() {
      for (final row in rows) {
        row.qty.text = value == null
            ? _planRowDefaultQty(row)
            : _host._qty(value);
      }
    });
  }

  // ===== 可安排桶：车间 / 负责人编辑 =====

  Future<void> _pickWorkshop(_BucketPlanRow row) async {
    final workshopTree = await _workshopTreeOrNull();
    if (!mounted) return;
    final workshopIds = {for (final node in workshopTree) node.id};
    // 2026-09-04 用户口径：单元格点开即右侧滑入面板（与向导表单里的车间
    // 选择器同款），不再先弹一层居中 AlertDialog。
    final picked = await showUtenDepartmentPickerPanel(
      context,
      tree: workshopTree,
      selectablePredicate: (node) => workshopIds.contains(node.id),
      initialSelection: row.departmentId.value == null
          ? const []
          : [
              DeptSelection(
                id: row.departmentId.value!,
                name: row.departmentName ?? '',
                fullPath: '',
                level: '',
              ),
            ],
    );
    final selection = picked == null || picked.isEmpty ? null : picked.first;
    if (selection == null || !mounted) return;
    setState(() {
      if (row.departmentId.value != selection.id) {
        // 换车间：负责人优先「该货品学习记忆里的负责人」（V488，仅当记忆车间
        // 恰为本次所换车间），否则带出组织树车间负责人（黄标提醒核对，可改）；
        // 两者都没有才留空手选（与计划向导同口径）。
        final goodsId =
            row.origin.product?.goodsId ??
            row.origin.candidate?.material.goodsId;
        final learned = goodsId == null ? null : _workshopDefaults[goodsId];
        final rememberedWorker =
            learned != null &&
                learned.departmentId == selection.id &&
                learned.workerId != null
            ? (id: learned.workerId, name: learned.workerName)
            : null;
        final manager =
            rememberedWorker ?? _workshopManagerOf(workshopTree, selection.id);
        row.workerId.value = manager?.id;
        row.workerName = manager?.name;
        row.workerAutofilled = manager != null;
      }
      row.departmentId.value = selection.id;
      row.departmentName = selection.name;
      row.workshopAutofilled = false; // 手选=已核对
    });
  }

  Future<void> _pickWorker(_BucketPlanRow row) async {
    // 2026-09-04 用户口径：直接右侧滑入人员选择面板，不再套居中弹窗。
    final picked = await showUtenEmployeePickerPanel(
      context,
      title: '选择生产负责人',
      selectedId: row.workerId.value,
      departmentName: row.departmentName,
      loader: (keyword) async {
        final result = await _host.ref
            .read(employeeRepositoryProvider)
            .list(
              size: 30,
              search: keyword,
              departmentId: (keyword?.trim().isEmpty ?? true)
                  ? row.departmentId.value
                  : null,
              includeSubtree: true,
            );
        return [
          for (final employee in result.items)
            UtenEmployeePickerItem(
              id: employee.id,
              name: employee.fullName,
              employeeCode: employee.code,
              departmentName: employee.departmentName,
            ),
        ];
      },
    );
    if (picked == null || !mounted) return;
    setState(() {
      row.workerId.value = picked.id;
      row.workerName = picked.name;
      row.workerAutofilled = false;
    });
  }

  // ===== 表格构建 =====

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final analysis = _host._analysis;
    if (analysis == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const SizedBox.shrink();
    }
    final allRows = _host._bucketRows(_bucket);
    final rows = _filterRows(allRows);
    return Scaffold(
      appBar: UtenAppBar(
        title: '${_bucket.countLabel(_host._l10n)} · ${rows.length}',
        // 分桶详情是宿主页的命令式子弹层，没有独立路由 scope；权限入口
        // 由宿主页承载（见 PagePermissionAction._scopeFromRouter 的
        // fail-closed 契约——非 go_router 页路由不得解析 scope）。
        showPagePermissionAction: false,
        leading: UtenBackButton(onPressed: () => Navigator.of(context).pop()),
      ),
      // 下达进行中的遮罩画在**本页**（2026-09-11）：此前是「先 pop 回物料分析
      // → 在宿主页转圈」，用户看到的是「点了下达，页面自己退回去了」。复用宿主页
      // 那一份 `_planSubmissionOverlay`（同一个 key，文案/语义/不可关闭都一致），
      // 不另写一份会漂移的。
      body: Stack(
        children: [
          _bucketBody(theme, analysis, allRows, rows),
          // 进度遮罩跟随宿主的**网络调用本身**（planSubmissionProgress），不跟
          // `_running`：后者要到结果弹层看完才落下，遮罩会一直转在弹层背后。
          ValueListenableBuilder<bool>(
            valueListenable: _host.planSubmissionProgress,
            builder: (context, submitting, _) => submitting
                ? Positioned.fill(child: _host._planSubmissionOverlay(theme))
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _bucketBody(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
    List<_BucketRow> allRows,
    List<_BucketRow> rows,
  ) {
    return SafeArea(
      // 宽度收敛用外壳容器；selectable:false 退出文字框选——表格页框选
      // 低价值，且 SelectionArea × 可滚动表格（含横向同步/行手势）为
      // 全站未测组合，转场期间有选择区重算开销（准则：外壳容器遇
      // 重交互表格一律退出）。
      child: UtenContentContainer.wide(
        selectable: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(UtenSpacing.s8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: UtenRadius.mdAll,
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        _bucket.semanticHint(_host._l10n),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                    // 2026-09-05 用户口径：不再给「全选全部 N 条」——表头
                    // 复选框已覆盖当页，跨页批量从宿主页分桶入口按桶执行。
                  ],
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              if (_preparedChildCount > 0) ...[
                Text(
                  _host._l10n.materialPreparedChildCreated(_preparedChildCount),
                  key: const Key('material-analysis-prepared-child-next'),
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  _host._canGenerate
                      ? _host._l10n.materialPreparedChildNext
                      : _host._l10n.materialPreparedChildNeedPlanner,
                ),
                // 2026-09-06 用户口径：不再放「下达车间」跳转按钮——备料子
                // 任务的计划下达统一在「下达车间」入口办理，本横幅只提示。
                const SizedBox(height: UtenSpacing.s8),
              ],
              UtenSegmentedFilter<_PreparationTaskFilter>(
                key: const Key('material-analysis-task-state'),
                selected: _taskFilter,
                segments: [
                  UtenSegment(
                    value: _PreparationTaskFilter.pending,
                    label: _pendingIssueFilterLabel,
                    count: allRows
                        .where(
                          (row) => _host._bucketRowHasPending(row, _bucket),
                        )
                        .length,
                  ),
                  UtenSegment(
                    value: _PreparationTaskFilter.issued,
                    label: _host._l10n.materialTaskIssued,
                    count: allRows
                        .where((row) => _host._bucketRowHasIssued(row, _bucket))
                        .length,
                  ),
                  UtenSegment(
                    value: _PreparationTaskFilter.blocked,
                    label: _host._l10n.materialTaskBlocked,
                    count: allRows
                        .where(
                          (row) => _host._bucketRowNeedsAttention(row, _bucket),
                        )
                        .length,
                  ),
                ],
                onChanged: (value) {
                  if (_actionsLocked || value == _taskFilter) return;
                  setState(() {
                    _taskFilter = value;
                    _pageNo = 1;
                    _selectedIds.clear();
                    _tableFilters.clear();
                    _planGrid?.clearSelection();
                  });
                },
              ),
              const SizedBox(height: UtenSpacing.s8),
              Expanded(
                // 可安排桶：网格按内容收缩 + 外层滚动（网格表体本身
                // NeverScrollable，编辑页同款结构）；首屏 100 行增量装载。
                child: _usesPlanGrid
                    ? SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _readyPlanGrid(theme),
                            if (_allPlanOrigins.length > _planVisibleLimit)
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: UtenSpacing.s8,
                                  bottom: UtenSpacing.s16,
                                ),
                                child: Center(
                                  child: UtenButton(
                                    key: const Key(
                                      'material-analysis-bucket-show-more',
                                    ),
                                    type: UtenButtonType.tonal,
                                    icon: Icons.expand_more_rounded,
                                    onPressed: _showMorePlanRows,
                                    child: Text(
                                      '继续显示(还有 '
                                      '${_allPlanOrigins.length - _planVisibleLimit} 行)',
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      )
                    : _bucketReadOnlyTable(rows),
              ),
              // 可安排桶的批量动作条：常驻钉底（UtenEditableGrid 的
              // batchActionsBuilder 只随编辑模式操作条渲染，select-only 模式
              // 不出现——故由本页自管，订阅控制器按选中数即时刷新）。
              // 2026-09-05 与全站对齐：「已选 N 项 + ✕」用标准胶囊
              // （UtenSelectionSummaryPill），与按钮同框进右对齐悬浮组
              // （UtenFloatingActionGroup）——与 MasterDataTableView 悬浮组同款。
              if (_usesPlanGrid) ...[
                const SizedBox(height: UtenSpacing.s8),
                AnimatedBuilder(
                  animation: _planGrid!,
                  builder: (context, _) => UtenFloatingActionGroup(
                    children: [
                      UtenSelectionSummaryPill(
                        count: _planGrid!.selectedRows.length,
                        clearKey: const Key(
                          'material-analysis-bucket-selected-count',
                        ),
                        onClear: _planGrid!.selectedRows.isEmpty
                            ? null
                            : () => _planGrid!.clearSelection(),
                      ),
                      ..._planBatchActions(context),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _bucketReadOnlyTable(List<_BucketRow> rows) {
    // 2026-09-05 用户口径：采购/委外桶的「进度」与「缺口」表头可点筛选
    // （自研锚定下拉，视图级过滤不动选择；缺口=只看有缺口/全部）。
    final filterable = _bucket != _AnalysisBucket.workshop;
    final progressFacets = <MasterFacetBucket>[];
    var gapCount = 0;
    if (filterable) {
      final progressCounts = <String, int>{};
      for (final row in rows) {
        final group = row.group;
        if (group == null) continue;
        if ((group.representative.shortageQty) > 0) gapCount++;
        final label = _host._materialStatus(Theme.of(context), group).label;
        progressCounts[label] = (progressCounts[label] ?? 0) + 1;
      }
      progressFacets.addAll(
        [
          for (final entry in progressCounts.entries)
            MasterFacetBucket(
              value: entry.key,
              count: entry.value,
              label: entry.key,
            ),
        ]..sort((a, b) => a.display.compareTo(b.display)),
      );
    }
    final progressFilter = _tableFilters['taskState'];
    final gapFilter = _tableFilters['shortageQty'];
    final filtered = !filterable
        ? rows
        : rows
              .where((row) {
                final group = row.group;
                if (group == null) return true;
                if (progressFilter != null &&
                    _host._materialStatus(Theme.of(context), group).label !=
                        progressFilter) {
                  return false;
                }
                if (gapFilter != null &&
                    (group.representative.shortageQty) <= 0) {
                  return false;
                }
                return true;
              })
              .toList(growable: false);
    final filteredTotalPages = _pageTotal(filtered);
    final filteredPage = _pageNo.clamp(1, filteredTotalPages);
    return MasterDataTableView<_BucketRow>(
      columns: _bucketColumns(),
      items: _pageRows(filtered, filteredPage),
      facets: {
        if (filterable) 'taskState': progressFacets,
        if (filterable && gapCount > 0)
          'shortageQty': [
            MasterFacetBucket(value: 'GAP', count: gapCount, label: '只看有缺口'),
          ],
      },
      nullCounts: const {},
      filters: {
        for (final entry in _tableFilters.entries)
          if (entry.value != null) entry.key: entry.value!,
      },
      onFilterChanged: (key, value) => setState(() {
        _tableFilters[key] = value;
        _pageNo = 1;
      }),
      selectable: _canAct,
      idOf: (row) => _canSelectTask(row) ? row.id : null,
      rowKeyOf: (row) => row.id,
      selectedIds: _selectedIds,
      onSelectedIdsChanged: (next) => setState(() {
        _selectedIds
          ..clear()
          ..addAll(next);
      }),
      batchActionsBuilder: _canAct ? _readOnlyBatchActions : null,
      // 行右键/长按 = 对当前选择集整组恢复默认下达数量（2026-09-11 用户要求）。
      rowMenuBuilder: _canAct ? _readOnlyRowMenu : null,
      // 勿传 virtualized（它强制表体撑满剩余高度 → 横滚条恒钉屏底）：保持默认
      // content-tall——与车间计划网格/货品资料同款，内容少横滚条贴末行、超高才钉底。
      onRowTap: _onRowTap,
      enableTextSelection: false,
      showFullscreenToggle: false,
      canOpenRow: (row) =>
          row.group != null ||
          (_host._canViewPlans &&
              (row.product?.latestPlanId?.trim().isNotEmpty ?? false)),
      emptyMessage: _host._l10n.materialTaskEmpty,
      currentPage: filteredPage,
      totalPages: filteredTotalPages,
      onPageChange: (next) => setState(() => _pageNo = next),
    );
  }

  List<Widget> _readOnlyBatchActions(
    BuildContext context,
    Set<String> selectedIds,
  ) {
    if (!_hasWriteAction) return const [];
    final count = selectedIds.length;
    final label = switch (_bucket) {
      _AnalysisBucket.buy => '提交采购需求($count)',
      _AnalysisBucket.subcontract => '下达委外($count)',
      _ => '',
    };
    final canAct = _canAct && !_actionsLocked && count > 0;
    // 跨页全选放悬浮区（与已选胶囊/提交按钮同框）；表头复选框只选当页。
    final allRows = _filterRows(_host._bucketRows(_bucket));
    final selectableCount = allRows.where(_canSelectTask).length;
    return [
      if (_taskFilter == _PreparationTaskFilter.pending &&
          allRows.length > _pageSize)
        UtenButton(
          key: const Key('material-analysis-bucket-select-all'),
          type: UtenButtonType.ghost,
          size: UtenButtonSize.large,
          icon: Icons.select_all_rounded,
          onPressed: _actionsLocked
              ? null
              : () => setState(() {
                  _selectedIds
                    ..clear()
                    ..addAll(
                      allRows.where(_canSelectTask).map((row) => row.id),
                    );
                }),
          child: Text('全选全部 $selectableCount 条'),
        ),
      // 批量设下达数量（2026-09-11，与下达车间同款批量赋值）：选中一批行只输一次
      // 数量就写进全部可编辑行；留空 = 各行恢复默认全量（缺口 − 已在途）。
      UtenButton(
        key: const Key('material-analysis-bucket-batch-submit-qty'),
        type: UtenButtonType.tonal,
        size: UtenButtonSize.large,
        icon: Icons.numbers_rounded,
        onPressed: _canAct && !_actionsLocked && count > 0
            ? () => _batchSetSubmitQty(selectedIds)
            : null,
        child: Text('批量设下达数量($count)'),
      ),
      UtenButton(
        key: Key('material-analysis-bucket-action-${_bucket.name}'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: Icons.notifications_active_outlined,
        onPressed: canAct ? () => _submitMaterialBucket(selectedIds) : null,
        onDisabledTap: count == 0
            ? null
            : !_canAct
            ? () => context.appWarning('没有下达采购、委外或生产任务的权限')
            : null,
        child: Text(label),
      ),
    ];
  }

  /// 当前选择集中「下达数量可编辑」的行（未下达段 + actionGroupKey 提交单元）。
  List<_BucketRow> _editableSelectedRows(Set<String> selectedIds) => [
    for (final row in _filterRows(_host._bucketRows(_bucket)))
      if (selectedIds.contains(row.id) && _rowQtyEditable(row)) row,
  ];

  /// 采购/委外桶的行右键菜单：整组恢复默认下达数量。
  /// 选中归位由 MasterDataTableView 负责（未选中的行右键 = 只选它）。
  List<UtenContextMenuEntry> _readOnlyRowMenu(_BucketRow row) {
    final targets = _editableSelectedRows(_selectedIds);
    final n = targets.length;
    return [
      UtenMenuItem(
        label: '恢复默认下达数量 ($n)',
        icon: Icons.restart_alt_rounded,
        enabled: !_actionsLocked && n > 0,
        onTap: () => setState(() {
          for (final target in targets) {
            _resetSubmitQty(target);
          }
        }),
      ),
    ];
  }

  void _resetSubmitQty(_BucketRow row) {
    final group = row.group;
    if (group == null) return;
    _submitQtyControllerOf(group).text = _bucketQtyText(
      _host._residualSubmitQty(group, _bucket.supplyRoute!),
    );
  }

  /// 一次输入下达数量写进所有选中的可编辑行；留空 = 各行恢复默认全量。
  Future<void> _batchSetSubmitQty(Set<String> selectedIds) async {
    final targets = _editableSelectedRows(selectedIds);
    if (targets.isEmpty) {
      context.appWarning('选中的行都不能改下达数量（只有未下达且按组提交的行可改）');
      return;
    }
    final input = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('批量设置下达数量（${targets.length} 行）'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('留空并确认 = 每行恢复默认全量（缺口 − 已在途）；填数字 = 每行都用这个数量。'),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              key: const Key('material-analysis-bucket-batch-submit-qty-input'),
              controller: input,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const UtenInputDecoration(
                InputDecoration(isDense: true, hintText: '留空=恢复默认全量'),
              ),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('写入'),
          ),
        ],
      ),
    );
    final text = input.text.trim();
    input.dispose();
    if (confirmed != true || !mounted) return;
    final value = text.isEmpty ? null : double.tryParse(text);
    if (text.isNotEmpty && (value == null || !value.isFinite || value <= 0)) {
      context.appWarning('下达数量必须是大于 0 的数字');
      return;
    }
    setState(() {
      for (final row in targets) {
        if (value == null) {
          _resetSubmitQty(row);
          continue;
        }
        final group = row.group;
        if (group != null) {
          _submitQtyControllerOf(group).text = _bucketQtyText(value);
        }
      }
    });
  }

  /// 分页切片：只构建当页行（大分析数千行一次性构建在网页端是分钟级卡死）。
  int _pageTotal(List<_BucketRow> rows) =>
      rows.length <= _pageSize ? 1 : (rows.length / _pageSize).ceil();

  List<_BucketRow> _pageRows(List<_BucketRow> rows, int page) {
    if (rows.length <= _pageSize) return rows;
    final start = (page - 1) * _pageSize;
    if (start >= rows.length) return rows.sublist(0);
    final end = (start + _pageSize).clamp(0, rows.length);
    return rows.sublist(start, end);
  }

  void _onRowTap(_BucketRow row) {
    final material = row.group?.representative;
    if (material != null) {
      showDialog<void>(
        context: context,
        builder: (_) => MaterialSupplyProgressDialog(
          analysisId: _host._analysis!.analysisId,
          material: material,
          canViewProductionPlans: _host._canViewPlans,
        ),
      );
      return;
    }
    final planId = row.product?.latestPlanId?.trim();
    if (_host._canViewPlans && planId != null && planId.isNotEmpty) {
      context.push(RoutePath.productionPlanDetail(planId));
    }
  }

  /// 可安排桶：可编辑计划表（数量 / 车间 / 负责人）。表头设置与只读桶的
  /// MasterDataTableView 对齐——支持列显隐、拖拽排序与恢复默认（列多时
  /// 计划员可自行收敛视野）。类型/货品/车间/负责人/状态表头均可点筛选
  /// （2026-09-11 补齐前两列，自研锚定下拉，视图级过滤不动数据与勾选）；
  /// 「全选/取消全选」按钮不渲染（表头复选框已覆盖当页选择）。
  Widget _readyPlanGrid(ThemeData theme) {
    return UtenEditableGrid<_BucketPlanRow>(
      controller: _planGrid!,
      selectable: _canAct,
      canSelectRow: (row) => _canSelectTask(row.origin),
      showAddRow: false,
      showRowDelete: false,
      showColumnSettings: true,
      showSelectAllToggle: false,
      // 行右键/长按 = 对当前选择集做整组清空/填满（2026-09-11 用户要求）。
      rowMenuExtraBuilder: _canAct ? _planRowMenu : null,
      emptyMessage: _host._l10n.materialTaskEmpty,
      columns: [
        EditableGridColumn<_BucketPlanRow>(
          key: 'kind',
          label: '类型',
          width: 92,
          // 2026-09-11：与「生产车间/负责人/状态」一致，类型列也给表头快速筛选
          // （用户截图反馈：同一张表有的列有下拉箭头有的没有）。
          filterValueOf: _planRowKindLabel,
          cellBuilder: (context, row) => Text(
            _planRowKindLabel(row),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'goods',
          label: '货品',
          width: 200,
          // 2026-09-11：货品列表头快速筛选，桶标签=货品名（无名用物料编码）。
          filterValueOf: _planRowGoodsLabel,
          textOf: (row) {
            final product = row.origin.product;
            if (product != null) {
              return product.goodsName ??
                  product.goodsCode ??
                  product.analysisLineId;
            }
            final material = row.origin.candidate!.material;
            return material.goodsName ?? material.goodsCode ?? '';
          },
          cellBuilder: (context, row) => Text(
            row.origin.product != null
                ? (row.origin.product!.goodsName ??
                      row.origin.product!.goodsCode ??
                      '未命名产品')
                : (row.origin.candidate!.material.goodsName ??
                      row.origin.candidate!.material.goodsCode ??
                      ''),
          ),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'requiredQty',
          label: '需求数量',
          width: 110,
          numeric: true,
          cellBuilder: (context, row) {
            // 2026-09-05 用户口径：本列显示总需求量（非剩余），数量后带单位；
            // 剩余口径只用于默认数量与上限校验（齐套/上限列已随 ADR-71 下线）。
            final product = row.origin.product;
            final candidate = row.origin.candidate;
            final qty =
                product?.requestedQty ?? candidate?.material.requiredQty;
            final unit =
                product?.unitName?.trim() ??
                candidate?.material.unitName?.trim();
            return Align(
              alignment: Alignment.centerRight,
              child: Text(
                unit == null || unit.isEmpty
                    ? _host._qty(qty)
                    : '${_host._qty(qty)} $unit',
              ),
            );
          },
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'qty',
          label: '本批数量',
          // 与销售/采购数量列同宽(128)；通用说明放列头 ⓘ（2026-09-10 全站口径），
          // 格内不再塞图标挤占「可分批下达」占位。
          width: 128,
          numeric: true,
          required: true,
          headerInfo: _host._l10n.workflowWorkshopQuantityHint,
          textOf: (row) => row.qty.text,
          listenableOf: (row) => row.qty,
          cellBuilder: (context, row) => RequiredCellFrame(
            listenable: row.qty,
            isEmpty: () => (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
            child: TextField(
              controller: row.qty,
              readOnly: !_host._canGenerate,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const UtenInputDecoration(
                InputDecoration(isDense: true, hintText: '可分批下达'),
              ),
            ),
          ),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'workshop',
          label: '生产车间',
          width: 150,
          required: true,
          // 空值返回 null（不建桶，计入「未填」），不要空串桶。
          filterValueOf: (row) => row.departmentName ?? row.departmentId.value,
          cellBuilder: (context, row) => ValueListenableBuilder<String?>(
            valueListenable: row.departmentId,
            builder: (context, departmentId, _) => InkWell(
              key: ValueKey('material-analysis-bucket-workshop-${row.id}'),
              onTap: _host._canGenerate ? () => _pickWorkshop(row) : null,
              // 2026-09-10 单元规格统一：不自带 border/contentPadding（吃
              // UtenEditableGrid 行级主题：圆角 10、内边距 14/12）、正文字号，
              // 与同行数量输入格等高同圆角。
              child: InputDecorator(
                decoration: applyAutofillHint(
                  InputDecoration(
                    isDense: true,
                    suffixIcon: Icon(
                      departmentId == null
                          ? Icons.search_rounded
                          : Icons.unfold_more_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    suffixIconConstraints: const BoxConstraints(minWidth: 20),
                  ),
                  Theme.of(context),
                  // 学习默认带出=黄框提醒核对；手选后清除。
                  autofilled: row.workshopAutofilled && departmentId != null,
                ),
                child: Text(
                  departmentId == null
                      ? (row.workshopAutofilled ? '默认车间待带出' : '点击选择')
                      : (row.departmentName ?? departmentId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: departmentId == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'worker',
          label: '负责人',
          width: 130,
          required: true,
          filterValueOf: (row) => row.workerName ?? row.workerId.value,
          cellBuilder: (context, row) => ValueListenableBuilder<String?>(
            valueListenable: row.workerId,
            builder: (context, workerId, _) => InkWell(
              key: ValueKey('material-analysis-bucket-worker-${row.id}'),
              onTap: _host._canGenerate ? () => _pickWorker(row) : null,
              child: InputDecorator(
                decoration: applyAutofillHint(
                  InputDecoration(
                    isDense: true,
                    suffixIcon: Icon(
                      workerId == null
                          ? Icons.search_rounded
                          : Icons.unfold_more_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    suffixIconConstraints: const BoxConstraints(minWidth: 20),
                  ),
                  Theme.of(context),
                  autofilled: row.workerAutofilled && workerId != null,
                ),
                child: Text(
                  workerId == null ? '点击选择' : (row.workerName ?? workerId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: workerId == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'stage',
          label: '状态',
          width: 140,
          filterValueOf: _planRowStatusLabel,
          cellBuilder: (context, row) {
            final product = row.origin.product;
            final routePending =
                product != null && _host._rootRoutePending(product);
            return Text(
              _planRowStatusLabel(row),
              style: theme.textTheme.bodySmall?.copyWith(
                color: routePending
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: routePending ? FontWeight.w700 : null,
              ),
            );
          },
        ),
      ],
    );
  }

  /// 计划行的状态文案（2026-09-05 用户口径：一张表一个状态列——路线待确认（红）/
  /// 阻断原因 / 未下达 / 已下达看执行段；齐套与否不在这里区分，计划只管下发，
  /// 车间等物料由执行段 WAITING→READY 自动判断）。状态列单元格与表头筛选共用。
  /// 2026-09-06 起未下达文案统一为词表第一步「等待下达车间」。
  String _planRowStatusLabel(_BucketPlanRow row) {
    final product = row.origin.product;
    return product != null
        ? _host._productExecutionStage(product)?.displayLabel ??
              (product.canSchedule
                  ? '等待下达车间'
                  : _host._rootRouteScheduleHint(product) ??
                        product.scheduleBlockedReason ??
                        _host._l10n.materialTaskBlocked)
        : (_host._canArrangePendingMakeCandidate(row.origin.candidate!)
              ? '等待下达车间'
              : '当前状态不可创建');
  }

  /// 计划行的类型文案（自制候选 / 自制子件 / 委外子件）。单元格与表头筛选共用
  /// 同一口径——取值稳定（不随重建变动），空值不可能出现，故不返回 null。
  String _planRowKindLabel(_BucketPlanRow row) {
    if (!row.isProduct) return '自制候选';
    return switch (row.origin.product!.sourceType) {
      'MAKE_COMPONENT' => '自制子件',
      'SUBCONTRACT_MAKE' => '委外子件',
      // 2026-09-05 用户口径：顶层与子层自制同构——顶层产品行的类型也是
      // 「自制候选」，不再有专属「产品」形态。
      _ => '自制候选',
    };
  }

  /// 计划行的货品名（表头筛选的桶标签）：优先货品名称，其次物料编码；两者都
  /// 没有 → null（不建桶，计入「未填」计数），绝不用行唯一的 analysisLineId
  /// 兜底——那会让每行各成一桶。
  String? _planRowGoodsLabel(_BucketPlanRow row) {
    final product = row.origin.product;
    final name = product != null
        ? (product.goodsName ?? product.goodsCode)
        : (row.origin.candidate!.material.goodsName ??
              row.origin.candidate!.material.goodsCode);
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// 「未下达」筛选段的路线化标签（与流程词表第一步同名）。
  String get _pendingIssueFilterLabel => switch (_bucket) {
    _AnalysisBucket.buy => '等待下发采购',
    _AnalysisBucket.subcontract => '等待下发委外',
    _AnalysisBucket.workshop => '等待下达车间',
  };

  List<MasterColumnDef<_BucketRow>> _bucketColumns() =>
      _bucket == _AnalysisBucket.workshop
      ? _productColumns()
      : _materialGroupColumns();

  /// Supply tasks show residual demand and downstream progress, using server facts.
  /// 2026-09-05 列口径（用户）：数量类只留「需求量 / 单位 / 已到货 / 缺口」，
  /// 原「未下达」并入可编辑的「下达数量」（默认=本批缺口−已在途，可直接改）。
  /// 单据清单列只在「已下达」段出现——该段的核心信息就是已生成的单据；
  /// 未下达段不再与四个数量列混排（单号仍可点行看全链路进度弹窗）。
  List<MasterColumnDef<_BucketRow>> _materialGroupColumns() {
    final host = _host;
    final route = _bucket.supplyRoute!;
    return [
      MasterColumnDef<_BucketRow>(
        key: 'goods',
        label: '物料',
        width: 200,
        value: (row) {
          final m = row.group?.representative;
          if (m == null) return null;
          final spec = m.spec?.trim();
          return spec?.isNotEmpty == true
              ? '${m.goodsName ?? m.goodsCode ?? m.materialLineId}（$spec）'
              : m.goodsName ?? m.goodsCode ?? m.materialLineId;
        },
      ),
      MasterColumnDef<_BucketRow>(
        key: 'color',
        label: '颜色',
        width: 90,
        value: (row) {
          final name = row.group?.representative.colorName?.trim();
          return (name == null || name.isEmpty) ? '—' : name;
        },
      ),
      MasterColumnDef<_BucketRow>(
        key: 'path',
        label: 'BOM 路径',
        width: 260,
        value: (row) => row.group == null
            ? null
            : host._pathLabel(row.group!.representative),
      ),
      MasterColumnDef<_BucketRow>(
        key: 'requiredQty',
        label: '需求量',
        width: 90,
        type: 'number',
        value: (row) => host._qty(row.group?.representative.requiredQty),
        info: '本批生产需要的总量（按产品数量 × 单件用量算出）。',
      ),
      MasterColumnDef<_BucketRow>(
        key: 'unit',
        label: '单位',
        width: 70,
        value: (row) => row.group?.representative.unitName?.trim(),
      ),
      MasterColumnDef<_BucketRow>(
        key: 'arrivedQty',
        label: host._l10n.materialAllocated,
        width: 100,
        type: 'number',
        value: (row) {
          final group = row.group;
          if (group == null) return null;
          // 服务端分配已包含本批可用的精确到货，不能再次叠加。
          final arrived = group.paths.fold<double>(
            0,
            (sum, material) => sum + material.allocatedAvailableQty,
          );
          return host._qty(arrived);
        },
        info: host._l10n.materialPreparedQuantityHint,
      ),
      // 仓库余量（2026-09-06 用户口径）：仓库里该维度还可用的现货池。
      // 够需求（>=需求量）标绿、不够标红——即使够货也不跳过采购/委外流程，
      // 计划员仍可在桶内按富余量下单（超量部分走公共富余，不绑定本需求）。
      MasterColumnDef<_BucketRow>(
        key: 'warehouseAvailableQty',
        label: '仓库余量',
        width: 100,
        type: 'number',
        value: (row) => host._qty(row.group?.representative.availableQty),
        info:
            '仓库里该物料当前还可用的现货量（不含在途订单）。够需求=绿、不够=红；'
            '即使够货也不跳过流程，仍可按富余量下单（富余走公共备货，不绑定本需求）。',
        // 颜色走语义 token（准则：不用硬编码 Material 色）：够=绿实底（浅色
        // successText 深绿/深色 successOnDark），不够=colorScheme.error。
        cellColor: (context, row) {
          final material = row.group?.representative;
          if (material == null || material.requiredQty <= 0) return null;
          final theme = Theme.of(context);
          return material.availableQty >= material.requiredQty
              ? (theme.brightness == Brightness.dark
                    ? UtenColors.successOnDark
                    : UtenColors.successText)
              : theme.colorScheme.error;
        },
      ),
      MasterColumnDef<_BucketRow>(
        key: 'shortageQty',
        label: '缺口',
        width: 90,
        type: 'number',
        // 缺口始终使用服务端实际缺料事实；下达量和公共备货不改变本批需求。
        value: (row) => host._qty(row.group?.representative.shortageQty),
        info: host._l10n.materialPhysicalShortageHint,
        cellBuilder: (context, row) {
          final group = row.group;
          if (group == null) return const SizedBox.shrink();
          final theme = Theme.of(context);
          final cellScope = MasterDataTableCellScope.maybeOf(context);
          final selected = cellScope?.selected ?? false;
          final shortage = group.representative.shortageQty;
          // 说明挂列头 ⓘ（info 字段），格内不再逐行 Tooltip（2026-09-09 口径）；
          // key 供测试/语义锚定「物理缺口」单元格。
          // 缺口颜色与主表同一口径（>0 红 / =0 绿 token 明暗配对，F2e）。
          return KeyedSubtree(
            key: const Key('bucket-shortage-qty-cell'),
            child: Text(
              host._qty(shortage),
              style: theme.textTheme.bodySmall?.copyWith(
                color: selected
                    ? cellScope?.foregroundColor
                    : host._shortageTextColor(theme, shortage),
                fontWeight: FontWeight.w700,
              ),
            ),
          );
        },
        cellColor: (context, row) {
          final group = row.group;
          if (group == null) return null;
          return host._shortageCellColor(
            Theme.of(context),
            group.representative.shortageQty,
          );
        },
      ),
      MasterColumnDef<_BucketRow>(
        key: 'submitQty',
        label: '下达数量',
        width: 130,
        type: 'number',
        // 未下达段=可编辑的本次下达量（默认=缺口−已在途）；已下达段=该行
        // 已实际下达给下游的量（按路线匹配的分摊合计），不再显示剩余 0。
        value: (row) => row.group == null
            ? null
            : _taskFilter == _PreparationTaskFilter.issued
            ? host._qty(_issuedSubmitQty(row.group!, route))
            : host._qty(host._residualSubmitQty(row.group!, route)),
        info:
            '未下达行：本次要下达的数量（默认 = 缺口 − 已在途，可改小分批）；'
            '已下达行：已实际下达给下游单据的量。',
        cellBuilderHandlesSemantics: true,
        cellBuilder: (context, row) => _submitQtyCell(context, row, route),
      ),
      if (_taskFilter == _PreparationTaskFilter.issued)
        MasterColumnDef<_BucketRow>(
          key: 'supplyProgress',
          label: '${host._l10n.materialTaskIssued}单据',
          width: 240,
          // 只展示单号（2026-09-05 用户口径）：状态与全链路进度走行点击弹窗。
          value: (row) => row.group?.paths
              .expand((path) => path.notifiedTargets)
              .where((target) => target.target == _bucket.supplyRoute)
              .map((target) => target.documentNo)
              .whereType<String>()
              .where((value) => value.isNotEmpty)
              .toSet()
              .join(' / '),
        ),
      MasterColumnDef<_BucketRow>(
        key: 'taskState',
        label: host._l10n.materialProgress,
        width: 260,
        info: host._l10n.materialSupplyProgressHint,
        value: (row) => row.group == null
            ? null
            : host._materialStatus(Theme.of(context), row.group!).label,
        cellColor: (context, row) => row.group == null
            ? null
            : host._materialStatus(Theme.of(context), row.group!).color,
      ),
    ];
  }

  /// 已下达段每行「已实际下达的量」：该物料组各路径上、按当前桶路线匹配的
  /// 下游分摊量合计（跳过已撤销目标；无分摊数据返回 0 显示为 0）。
  double _issuedSubmitQty(_MaterialGroup group, MaterialSupplyRoute route) {
    double sum = 0;
    for (final path in group.paths) {
      for (final target in path.notifiedTargets) {
        if (target.target != route) continue;
        if (target.status == 'CANCELLED') continue;
        sum += target.allocatedQty ?? 0;
      }
    }
    return sum;
  }

  /// 「下达数量」单元格：可编辑行（未下达段 + actionGroupKey 提交单元）给
  /// 数字输入框（默认=缺口全量，可改小分批/超量）；已下达段只读显示
  /// 已实际下达的量（路线匹配的分摊合计）；其余只读行显示默认量。
  Widget _submitQtyCell(
    BuildContext context,
    _BucketRow row,
    MaterialSupplyRoute route,
  ) {
    final theme = Theme.of(context);
    final group = row.group;
    if (group == null) return const SizedBox.shrink();
    final defaultValue = _host._residualSubmitQty(group, route);
    // 选中行整行深绿底+白字（表格统一高亮）：自绘的只读文字/输入框必须跟随
    // 白字口径——TextField 的显式 style 会盖掉环境 DefaultTextStyle，深色文字
    // 铺在深绿底上不可见（2026-09-06 用户反馈「选中后下达数量看不见」）。
    final cellScope = MasterDataTableCellScope.maybeOf(context);
    final selected = cellScope?.selected ?? false;
    final selectedColor = cellScope?.foregroundColor ?? Colors.white;
    if (!_rowQtyEditable(row)) {
      final issued = _taskFilter == _PreparationTaskFilter.issued;
      return Align(
        alignment: Alignment.centerRight,
        child: Text(
          issued
              ? _host._qty(_issuedSubmitQty(group, route))
              : _host._qty(defaultValue),
          style: theme.textTheme.bodySmall?.copyWith(
            color: selected
                ? selectedColor
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final unit = group.representative.unitName?.trim();
    return Semantics(
      label:
          '下达数量${unit == null ? '' : '（$unit）'}，默认 ${_host._qty(defaultValue)}',
      textField: true,
      child: TextField(
        key: ValueKey(
          'material-analysis-bucket-submit-qty-'
          '${group.representative.actionGroupKey}',
        ),
        controller: _submitQtyControllerOf(group),
        enabled: !_actionsLocked,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: theme.textTheme.bodySmall?.copyWith(
          color: selected ? selectedColor : null,
        ),
        cursorColor: selected ? selectedColor : null,
        decoration: UtenInputDecoration(
          InputDecoration(
            isDense: true,
            // 全站输入框主题默认白底（filled+fillColor=surface）：选中行是深绿底
            // +白字，若输入框仍画白底，白字压白底不可见（2026-09-06 用户反馈）。
            // 选中时改为 12% 半透明白叠加，输入区保持深色、白字清晰。
            filled: selected,
            fillColor: selected ? Colors.white.withValues(alpha: 0.12) : null,
            enabledBorder: selected ? InputBorder.none : null,
            disabledBorder: selected ? InputBorder.none : null,
            focusedBorder: selected ? InputBorder.none : null,
            hintStyle: selected ? TextStyle(color: selectedColor) : null,
            suffixStyle: selected ? TextStyle(color: selectedColor) : null,
            hintText: '默认 ${_host._qty(defaultValue)}',
            suffixText: unit?.isEmpty == true ? null : unit,
          ),
          // 说明挂列头 ⓘ（submitQty 列的 info），格内不再逐行渲染重复 ⓘ。
        ),
      ),
    );
  }

  /// 产品/候选列（车间桶已下达/需处理表）。
  /// 2026-09-06 用户口径重设计：去「订单/上级/剩余」；保留分析级必要列——
  /// 产品 / 需求量 / 下达数量(计划量) / 完成数量(完工入库+进度条) /
  /// 状态 / 生产车间 / 负责人 / 阻断摘要（已下达行显示下一步指引）。
  List<MasterColumnDef<_BucketRow>> _productColumns() {
    final host = _host;
    final issued = _taskFilter == _PreparationTaskFilter.issued;
    return [
      MasterColumnDef<_BucketRow>(
        key: 'goods',
        label: '产品',
        width: 200,
        value: (row) {
          if (row.product != null) {
            final code = row.product!.goodsCode?.trim();
            final name = row.product!.goodsName ?? '';
            return code?.isNotEmpty == true ? '$name($code)' : name;
          }
          final m = row.candidate?.material;
          if (m == null) return null;
          return m.goodsName ?? m.goodsCode ?? m.materialLineId;
        },
      ),
      MasterColumnDef<_BucketRow>(
        key: 'requestedQty',
        label: '需求量',
        width: 90,
        type: 'number',
        value: (row) => host._qty(
          row.product?.requestedQty ?? row.candidate?.material.requiredQty,
        ),
      ),
      MasterColumnDef<_BucketRow>(
        key: 'issuedQty',
        label: '下达数量',
        width: 100,
        type: 'number',
        // 已下达=生产计划量（planExecutionPlannedQty）；未下达显示「—」。
        value: (row) => issued
            ? (row.product?.planExecutionPlannedQty == null
                  ? null
                  : host._qty(row.product!.planExecutionPlannedQty))
            : null,
      ),
      MasterColumnDef<_BucketRow>(
        key: 'completedQty',
        label: '完成数量',
        width: 200,
        // 已下达=完工入库量 + 完工百分比进度条；未下达显示「—」。
        value: (row) => issued
            ? (row.product?.planExecutionInboundQty == null
                  ? null
                  : host._qty(row.product!.planExecutionInboundQty))
            : null,
        cellBuilder: (context, row) {
          final product = row.product;
          if (!issued || product == null) {
            return const Align(
              alignment: Alignment.centerRight,
              child: Text('—'),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '已完工入库 ${host._qty(product.planExecutionInboundQty ?? 0)}',
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              ProductionFlowProgress(
                ratio: product.planExecutionProgressRatio,
                semanticsLabel: '完工进度',
                height: 6,
              ),
            ],
          );
        },
      ),
      MasterColumnDef<_BucketRow>(
        key: 'stage',
        label: '状态',
        width: 150,
        value: (row) {
          final product = row.product;
          if (product != null) {
            // 已下达看执行段；未下达统一「等待下达车间」（词表第一步），
            // 路线未确认给红字原因。
            return host._productExecutionStage(product)?.displayLabel ??
                (product.canSchedule
                    ? '等待下达车间'
                    : _host._rootRouteScheduleHint(product) ??
                          product.scheduleBlockedReason ??
                          host._l10n.materialTaskBlocked);
          }
          final candidate = row.candidate;
          if (candidate == null) return null;
          return host._canArrangePendingMakeCandidate(candidate)
              ? '等待下达车间'
              : '当前状态不可创建';
        },
        // 顶层路线待确认：红色浅底与物料行一致（cellColor 组件层保证文字对比度）。
        cellColor: (context, row) {
          final product = row.product;
          return product != null &&
                  !product.canSchedule &&
                  _host._rootRoutePending(product)
              ? Theme.of(
                  context,
                ).colorScheme.errorContainer.withValues(alpha: 0.3)
              : null;
        },
      ),
      MasterColumnDef<_BucketRow>(
        key: 'workshop',
        label: '生产车间',
        width: 130,
        value: (row) => issued
            ? (row.product?.planExecutionWorkshopName?.trim().isEmpty == false
                  ? row.product!.planExecutionWorkshopName!.trim()
                  : null)
            : null,
      ),
      MasterColumnDef<_BucketRow>(
        key: 'responsible',
        label: '负责人',
        width: 110,
        value: (row) => issued
            ? (row.product?.planExecutionResponsibleName?.trim().isEmpty ==
                      false
                  ? row.product!.planExecutionResponsibleName!.trim()
                  : null)
            : null,
      ),
      MasterColumnDef<_BucketRow>(
        key: 'blocker',
        label: '阻断摘要',
        width: 260,
        value: (row) {
          final product = row.product;
          if (product != null) {
            if (_taskFilter == _PreparationTaskFilter.issued) {
              // 已下达：按当前阶段给出明确的下一步指引（不是阻断，是去向）。
              final status = product.planExecutionStatus?.trim().toUpperCase();
              return switch (status) {
                'SUBMITTED' => '计划待审核，审核后进入车间',
                'WAITING' =>
                  product.planExecutionZeroMaterial
                      ? '无需领料，车间可直接开工报工'
                      : '物料到仓验收合格后自动齐套并通知车间',
                'READY' =>
                  product.planExecutionZeroMaterial
                      ? '无需领料，车间可直接开工报工'
                      : '物料已齐套预留，仓库发料后即可报工',
                'IN_PROGRESS' => '车间生产中，完工经 FQC 与仓库点收入库',
                'COMPLETED' => '已全部完工入库',
                _ => host._productExecutionStage(product)?.detail,
              };
            }
            if (host._canSelectProduct(product)) return null;
            final serverReason =
                _host._rootRouteScheduleHint(product) ??
                product.scheduleBlockedReason?.trim();
            if (serverReason?.isNotEmpty == true) return serverReason;
            final readiness = host._productReadiness(product);
            return switch (readiness.state) {
              _ReadinessState.waitingMake =>
                '待自制子件补齐（自制缺料 ${readiness.make} 项）',
              _ReadinessState.waitingSupply =>
                '待采购/委外补齐（采购 ${readiness.buy} · 委外 '
                    '${readiness.subcontract}）',
              _ReadinessState.waiting => '下层缺料路线待确认（${readiness.review} 条）',
              _ReadinessState.ready => null,
            };
          }
          final candidate = row.candidate;
          if (candidate == null) return null;
          final unconfirmed = candidate.unconfirmedPathCount;
          return '缺料 ${candidate.shortageKindCount} 种 / '
              '${candidate.shortagePathCount} 条路径'
              '${unconfirmed > 0 ? '，其中 $unconfirmed 条路线待确认' : ''}';
        },
      ),
    ];
  }
}
