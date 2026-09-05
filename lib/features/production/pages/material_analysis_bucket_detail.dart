part of 'production_material_analysis_page.dart';

/// 物料分析分桶（2026-09-04 改版）：顶部入口条 ↔ 独立详情页。
///
/// 原设计是「可安排/暂不可安排/已转生产」大卡片内嵌小卡片瀑布流，物料多时
/// 页面被卡片撑爆、顺序混乱。改版后主页面只保留一行入口（各桶计数），点击
/// 进入全屏详情页批量处理；BOM 树头部「批量选择(整次分析)」三枚全选勾同时
/// 并入入口（采购/委外/自制桶）。
///
/// 动作编排（数量弹窗、分批、幂等、409 恢复、计划向导）仍由宿主页统一执行：
/// 详情页 pop 时带回 [_BucketActionRequest]，避免两处实现各自漂移。
enum _AnalysisBucket { ready, waiting, transferred, buy, subcontract, make }

extension _AnalysisBucketX on _AnalysisBucket {
  String get countLabel => switch (this) {
    _AnalysisBucket.ready => '可安排生产',
    _AnalysisBucket.waiting => '暂不可安排',
    _AnalysisBucket.transferred => '已转生产',
    _AnalysisBucket.buy => '可采购',
    _AnalysisBucket.subcontract => '可委外',
    _AnalysisBucket.make => '待自制',
  };

  String get semanticHint => switch (this) {
    _AnalysisBucket.ready =>
      '产品和已确认路线的自制/有子层委外件都可先按剩余需求排给车间。'
          '未齐套批次审批后进入待料，不占库存、不生成 DRAW。',
    _AnalysisBucket.waiting => '按结构、路线或已转交等真实阻断分类；单纯下层缺料不再阻止先排产。',
    _AnalysisBucket.transferred => '本批需求已全部转生产；双击行进入生产计划跟踪。',
    _AnalysisBucket.buy => '路线已确认采购且可执行的缺料；勾选后批量提交采购需求（数量可超过本批缺口）。',
    _AnalysisBucket.subcontract => '路线已确认委外且可执行的缺料；勾选后批量下达委外（数量可超过本批缺口）。',
    _AnalysisBucket.make => '自制路线已确认；可显式创建子件任务，下层缺料时后续计划进入待料。',
  };
}

/// 详情页发起的批量动作请求（pop 回宿主页执行）。写动作都在宿主页上下文里
/// 继续：数量确认弹窗 / 计划向导 / 批量进度条 / 冲突恢复提示。
class _BucketActionRequest {
  _BucketActionRequest.buy(this.groupKeys)
    : planDrafts = null,
      makeGroupKeys = null,
      subcontractGroupKeys = null,
      type = _BucketActionType.buy;
  _BucketActionRequest.subcontract(Set<String>? keys)
    : groupKeys = keys,
      planDrafts = null,
      makeGroupKeys = null,
      subcontractGroupKeys = keys,
      type = _BucketActionType.subcontractOnly;
  _BucketActionRequest.make(Set<String>? keys)
    : groupKeys = keys,
      planDrafts = null,
      makeGroupKeys = keys,
      subcontractGroupKeys = null,
      type = _BucketActionType.makeOnly;
  _BucketActionRequest.readyCandidates({
    this.makeGroupKeys,
    this.subcontractGroupKeys,
  }) : groupKeys = null,
       planDrafts = null,
       type = _BucketActionType.readyCandidates;
  _BucketActionRequest.generatePlans(this.planDrafts)
    : groupKeys = null,
      makeGroupKeys = null,
      subcontractGroupKeys = null,
      type = _BucketActionType.generatePlans;

  final _BucketActionType type;

  /// BUY / 委外 / 自制桶：目标操作组键（_MaterialGroup.key）。
  final Set<String>? groupKeys;

  /// 可安排桶·候选行：按路线拆分的组键（自制候选与有子层委外候选并存的场景）。
  final Set<String>? makeGroupKeys;
  final Set<String>? subcontractGroupKeys;

  /// 生成计划：逐产品输入（数量 + 车间 + 负责人）。
  final List<_BucketPlanDraft>? planDrafts;
}

enum _BucketActionType {
  buy,
  subcontractOnly,
  makeOnly,
  readyCandidates,
  generatePlans,
}

/// 生成计划的逐产品输入（可安排详情页收集，宿主页校验后进计划向导）。
class _BucketPlanDraft {
  const _BucketPlanDraft({
    required this.analysisLineId,
    required this.qty,
    required this.departmentId,
    required this.workshopName,
    required this.workerId,
    required this.workerName,
  });

  final String analysisLineId;
  final double qty;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;
  final String? workerName;
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
    if (_bucket == _AnalysisBucket.ready && _host._canGenerate) {
      _planGrid = UtenEditableGridController<_BucketPlanRow>();
      _buildPlanRows();
      unawaited(_loadWorkshopDefaults());
    }
  }

  @override
  void dispose() {
    _planGrid?.dispose();
    super.dispose();
  }

  /// The full set stays lightweight. Controllers/notifiers are created only
  /// for the loaded window and then owned exactly once by [_planGrid].
  List<_BucketRow> _allPlanOrigins = const [];
  int _planVisibleLimit = 100;
  Map<String, ({String departmentId, String? departmentName})>
  _workshopDefaults = const {};
  Map<String, ({String? id, String? name})> _workshopManagers = const {};

  /// 宿主页「创建子件任务」后自动选中的子件（装载到可见行时恢复勾选）。
  Set<String> _presetSelectedIds = const {};

  void _buildPlanRows() {
    final host = _host;
    _allPlanOrigins = host._bucketRows(_AnalysisBucket.ready);
    // 宿主页「创建子件任务」后自动选中的可生产子件保持已选（随行装载恢复）。
    _presetSelectedIds = {
      for (final id in host._selectedPlanLineIds)
        if (_allPlanOrigins.any((row) => row.id == id)) id,
    };
    _planGrid!.replaceAll(
      _allPlanOrigins.take(_planVisibleLimit).map(_newPlanRow),
    );
    _applyPresetSelection();
  }

  _BucketPlanRow _newPlanRow(_BucketRow origin) {
    final host = _host;
    final product = origin.product;
    final goodsId = product?.goodsId;
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
    return _BucketPlanRow(
      origin,
      defaultQtyText: product == null ? '' : host._planBatchDraftText(product),
      onQtyChanged: product == null
          ? null
          : (value) =>
                host._rememberPlanBatchQty(product.analysisLineId, value),
      defaultDepartmentId: workshop?.departmentId,
      defaultDepartmentName: workshop?.departmentName,
      // Explicit route seed wins; otherwise use the learned workshop manager.
      defaultWorkerId: seedWorkerId ?? manager?.id,
      defaultWorkerName: seedWorkerName ?? manager?.name,
    );
  }

  void _applyPresetSelection() {
    if (_presetSelectedIds.isEmpty) return;
    for (final row in _planGrid!.rows) {
      if (_presetSelectedIds.contains(row.id)) {
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
  /// 车间负责人默认带出该车间在组织树上维护的负责人（manager）。
  Future<void> _loadWorkshopDefaults() async {
    final goodsIds = <String>{};
    for (final origin in _allPlanOrigins) {
      final goodsId = origin.product?.goodsId;
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
                  ({String departmentId, String? departmentName})
                >{},
          ),
      _workshopTreeOrNull(),
    ]);
    if (!mounted) return;
    final defaults =
        results[0]
            as Map<String, ({String departmentId, String? departmentName})>;
    final workshopTree = results[1] as List<DepartmentNode>;
    _workshopDefaults = defaults;
    _workshopManagers = {
      for (final node in workshopTree)
        if (node.managerId?.isNotEmpty == true)
          node.id: (id: node.managerId, name: node.managerName),
    };
    var changed = false;
    for (final row in _planGrid!.rows) {
      if (!row.isProduct) continue;
      final goodsId = row.origin.product!.goodsId;
      final picked = row.departmentId.value == null ? defaults[goodsId] : null;
      if (picked != null) {
        row.departmentId.value = picked.departmentId;
        row.departmentName = picked.departmentName;
        row.workshopAutofilled = true;
        changed = true;
      }
      // 负责人：有车间还没负责人 → 默认带出车间负责人（黄标提醒核对）。
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
  /// （数量弹窗/分批/幂等/409 恢复）经 root Navigator 叠在本页之上，
  /// 不再先 pop 回宿主页弹窗；完成或取消后留在本页按最新快照刷新行集。
  /// 例外：`generatePlans` 是终态动作，先返回宿主页再执行——两阶段提交
  /// 遮罩与结果对话框都在宿主页上下文里展示（与原向导路由先关闭同款契约；
  /// 遮罩挂在宿主页 Stack 上，留在本页会被不透明路由盖住不可见）。
  /// [_running] 覆盖弹窗关闭到请求返回之间的空窗（宿主页 busy 不通知本页），
  /// 防止批量进度期间重复点提交。
  Future<void> _run(_BucketActionRequest request) async {
    if (_running) return;
    if (request.type == _BucketActionType.generatePlans) {
      Navigator.of(context).pop();
      await _host._executeBucketAction(request);
      return;
    }
    setState(() => _running = true);
    try {
      await _host._executeBucketAction(request);
    } finally {
      if (mounted) {
        // 行集随宿主页最新快照重算（分析对象被 _applyAnalysis 替换后分桶
        // 缓存自动失效）；可安排桶的计划行网格同步重建并恢复预勾选。
        if (_bucket == _AnalysisBucket.ready && _host._canGenerate) {
          _buildPlanRows();
        }
        setState(() => _running = false);
      }
    }
  }

  bool _running = false;

  bool get _hasWriteAction => _canAct;

  /// 动作执行窗口（含宿主页 busy 与本页 _running——宿主页 busy 变化不通知
  /// 本页重建，故两态都压住批量入口）。
  bool get _actionsLocked => _host._busy || _running;

  bool get _canAct => switch (_bucket) {
    _AnalysisBucket.ready => _host._canGenerate,
    _AnalysisBucket.buy ||
    _AnalysisBucket.subcontract ||
    _AnalysisBucket.make => _host._canNotify,
    _AnalysisBucket.waiting || _AnalysisBucket.transferred => false,
  };

  void _submitMaterialBucket(Set<String> selectedIds) {
    switch (_bucket) {
      case _AnalysisBucket.buy:
        _run(_BucketActionRequest.buy(Set<String>.of(selectedIds)));
      case _AnalysisBucket.subcontract:
        _run(_BucketActionRequest.subcontract(Set<String>.of(selectedIds)));
      case _AnalysisBucket.make:
        _run(_BucketActionRequest.make(Set<String>.of(selectedIds)));
      case _AnalysisBucket.ready:
      case _AnalysisBucket.waiting:
      case _AnalysisBucket.transferred:
        return;
    }
  }

  // ===== 可安排桶：计划行校验与两类批量动作 =====

  List<_BucketPlanRow> get _selectedPlanRows =>
      _planGrid?.selectedRows ?? const [];

  /// 生成计划前校验：数量、车间、负责人逐行齐备（第一处错误点名提示）。
  String? _validatePlanRows(List<_BucketPlanRow> rows) {
    for (final row in rows) {
      final product = row.origin.product!;
      final name =
          product.goodsName ?? product.goodsCode ?? product.analysisLineId;
      final raw = row.qty.text.trim();
      final qty = double.tryParse(raw);
      if (raw.isEmpty || qty == null || !qty.isFinite || qty <= 0) {
        return '「$name」本批生产数量必须大于 0';
      }
      if (qty > product.maxSchedulableQty) {
        return '「$name」本批生产数量不能超过当前可排产上限 '
            '${_host._qty(product.maxSchedulableQty)} 个';
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

  void _submitGeneratePlans() {
    final rows = _selectedPlanRows.where((row) => row.isProduct).toList();
    if (rows.isEmpty) {
      context.appInfo('请先勾选要生成计划的产品（自制候选请用「创建子件任务」）');
      return;
    }
    final error = _validatePlanRows(rows);
    if (error != null) {
      context.appError(error);
      return;
    }
    _run(
      _BucketActionRequest.generatePlans([
        for (final row in rows)
          _BucketPlanDraft(
            analysisLineId: row.id,
            qty: double.parse(row.qty.text.trim()),
            departmentId: row.departmentId.value,
            workshopName: row.departmentName,
            workerId: row.workerId.value,
            workerName: row.workerName,
          ),
      ]),
    );
  }

  void _submitReadyCandidates() {
    final selectedCandidates = _selectedPlanRows
        .where((row) => !row.isProduct)
        .toList();
    if (selectedCandidates.isEmpty) {
      context.appInfo('请先勾选要创建子件任务的自制候选');
      return;
    }
    final makeKeys = <String>{};
    final subcontractKeys = <String>{};
    for (final row in selectedCandidates) {
      final candidate = row.origin.candidate!;
      final key = candidate.group?.key;
      if (key == null) continue;
      if (candidate.route == MaterialSupplyRoute.subcontract) {
        subcontractKeys.add(key);
      } else {
        makeKeys.add(key);
      }
    }
    if (makeKeys.isEmpty && subcontractKeys.isEmpty) {
      context.appInfo('所选候选当前不可创建任务，请刷新后重试');
      return;
    }
    _run(
      _BucketActionRequest.readyCandidates(
        makeGroupKeys: makeKeys,
        subcontractGroupKeys: subcontractKeys,
      ),
    );
  }

  List<Widget> _planBatchActions(BuildContext context) {
    final controller = _planGrid!;
    final productCount = controller.selectedRows
        .where((row) => row.isProduct)
        .length;
    final candidateCount = controller.selectedRows.length - productCount;
    return [
      if (candidateCount > 0)
        UtenButton(
          key: const Key('material-analysis-bucket-create-tasks'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: Icons.factory_outlined,
          onPressed: _actionsLocked || !_host._canNotify
              ? null
              : _submitReadyCandidates,
          child: Text('创建子件任务($candidateCount)'),
        ),
      if (productCount > 0)
        UtenButton(
          key: const Key('material-analysis-bucket-action-ready'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: Icons.description_outlined,
          onPressed: _actionsLocked || !_host._canGenerate
              ? null
              : _submitGeneratePlans,
          onDisabledTap: !_host._canGenerate
              ? () => context.appWarning('没有生成生产计划权限')
              : null,
          child: Text('生成生产计划($productCount)'),
        ),
    ];
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
        // 换车间：负责人默认统一带出该车间的负责人（黄标提醒核对，可改）；
        // 车间未维护负责人才留空手选（与计划向导同口径）。
        final manager = _workshopManagerOf(workshopTree, selection.id);
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
    final rows = _host._bucketRows(_bucket);
    return Scaffold(
      appBar: UtenAppBar(
        title: '${_bucket.countLabel} ${rows.length} 项',
        // 分桶详情是宿主页的命令式子弹层，没有独立路由 scope；权限入口
        // 由宿主页承载（见 PagePermissionAction._scopeFromRouter 的
        // fail-closed 契约——非 go_router 页路由不得解析 scope）。
        showPagePermissionAction: false,
        leading: UtenBackButton(onPressed: () => Navigator.of(context).pop()),
      ),
      body: SafeArea(
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
                          _bucket.semanticHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ),
                      // 分页后表头全选只作用于当页：跨页批量场景给「全选全部」。
                      if (_hasWriteAction && rows.length > _pageSize) ...[
                        const SizedBox(width: UtenSpacing.s8),
                        UtenButton(
                          key: const Key('material-analysis-bucket-select-all'),
                          type: UtenButtonType.tonal,
                          onPressed: _actionsLocked
                              ? null
                              : () => setState(() {
                                  _selectedIds
                                    ..clear()
                                    ..addAll(rows.map((row) => row.id));
                                }),
                          child: Text('全选全部 ${rows.length} 条'),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: UtenSpacing.s8),
                Expanded(
                  // 可安排桶：网格按内容收缩 + 外层滚动（网格表体本身
                  // NeverScrollable，编辑页同款结构）；首屏 100 行增量装载。
                  child: _bucket == _AnalysisBucket.ready && _host._canGenerate
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
                // 可安排桶的批量动作条：常驻钉底、未选灰显（UtenEditableGrid 的
                // batchActionsBuilder 只随编辑模式操作条渲染，select-only 模式
                // 不出现——故由本页自管，订阅控制器按选中数即时刷新）。
                if (_bucket == _AnalysisBucket.ready && _host._canGenerate) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  AnimatedBuilder(
                    animation: _planGrid!,
                    builder: (context, _) => Wrap(
                      spacing: UtenSpacing.s8,
                      runSpacing: UtenSpacing.s8,
                      alignment: WrapAlignment.end,
                      children: _planBatchActions(context),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bucketReadOnlyTable(List<_BucketRow> rows) {
    final totalPages = _pageTotal(rows);
    final page = _pageNo.clamp(1, totalPages);
    return MasterDataTableView<_BucketRow>(
      columns: _bucketColumns(),
      items: _pageRows(rows, page),
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      selectable: _canAct,
      idOf: (row) => _canAct ? row.id : null,
      rowKeyOf: (row) => row.id,
      selectedIds: _selectedIds,
      onSelectedIdsChanged: (next) => setState(() {
        _selectedIds
          ..clear()
          ..addAll(next);
      }),
      batchActionsBuilder: _canAct ? _readOnlyBatchActions : null,
      virtualized: true,
      onRowTap: _onRowTap,
      enableTextSelection: false,
      showFullscreenToggle: false,
      canOpenRow: (row) =>
          _host._canViewPlans &&
          _bucket == _AnalysisBucket.transferred &&
          (row.product?.latestPlanId?.trim().isNotEmpty ?? false),
      emptyMessage: '当前桶没有条目',
      currentPage: page,
      totalPages: totalPages,
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
      _AnalysisBucket.make => '创建子件任务($count)',
      _ => '',
    };
    final canAct = _canAct && !_actionsLocked && count > 0;
    return [
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
    if (_bucket == _AnalysisBucket.transferred) {
      final planId = row.product?.latestPlanId?.trim();
      if (planId != null && planId.isNotEmpty) {
        context.push(RoutePath.productionPlanDetail(planId));
      }
    }
  }

  /// 可安排桶：可编辑计划表（数量 / 车间 / 负责人）。表头设置与只读桶的
  /// MasterDataTableView 对齐——支持列显隐、拖拽排序与恢复默认（列多时
  /// 计划员可自行收敛视野）。
  Widget _readyPlanGrid(ThemeData theme) {
    return UtenEditableGrid<_BucketPlanRow>(
      controller: _planGrid!,
      selectable: _canAct,
      canSelectRow: (row) =>
          row.isProduct ? _host._canGenerate : _host._canNotify,
      showAddRow: false,
      showRowDelete: false,
      showColumnSettings: true,
      emptyMessage: '当前没有可安排的产品或自制候选',
      columns: [
        EditableGridColumn<_BucketPlanRow>(
          key: 'kind',
          label: '类型',
          width: 92,
          cellBuilder: (context, row) => Text(
            row.isProduct
                ? switch (row.origin.product!.sourceType) {
                    'MAKE_COMPONENT' => '自制子件',
                    'SUBCONTRACT_MAKE' => '委外子件',
                    _ => '产品',
                  }
                : '自制候选',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'materialStatus',
          label: '物料状态',
          width: 112,
          cellBuilder: (context, row) {
            final product = row.origin.product;
            final partial = product?.hasPartialReadyBatch == true;
            final waiting = product != null && product.readyNowQty <= 0;
            return Text(
              product == null
                  ? row.origin.candidate!.material.lowerLevelPending
                        ? '下层缺料·可先排产'
                        : '下层已齐套'
                  : partial
                  ? '部分齐套·可先排 ${_host._qty(product.suggestedFirstBatchQty)}'
                  : waiting
                  ? '待料可排产'
                  : '物料齐套',
              style: theme.textTheme.bodySmall?.copyWith(
                color: partial || waiting
                    ? theme.colorScheme.tertiary
                    : theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            );
          },
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'goods',
          label: '货品',
          width: 200,
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
          key: 'order',
          label: '订单/上级',
          width: 140,
          textOf: (row) =>
              row.origin.product?.orderNo ??
              row.origin.candidate?.parentLabel ??
              '',
          cellBuilder: (context, row) => Text(
            row.origin.product?.orderNo ??
                row.origin.candidate?.parentLabel ??
                '—',
          ),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'requiredQty',
          label: '剩余需求',
          width: 90,
          numeric: true,
          cellBuilder: (context, row) => Align(
            alignment: Alignment.centerRight,
            child: Text(
              _host._qty(
                row.origin.product?.remainingQty ??
                    row.origin.candidate?.material.requiredQty,
              ),
            ),
          ),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'readyNowQty',
          label: '当前齐套',
          width: 100,
          numeric: true,
          cellBuilder: (context, row) => Align(
            alignment: Alignment.centerRight,
            child: Text(
              row.origin.product != null
                  ? _host._qty(row.origin.product!.readyNowQty)
                  : '—',
            ),
          ),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'suggestedFirstBatchQty',
          label: '建议首批',
          width: 126,
          numeric: true,
          cellBuilder: (context, row) {
            final product = row.origin.product;
            if (product == null) {
              return const Align(
                alignment: Alignment.centerRight,
                child: Text('—'),
              );
            }
            final partial = product.hasPartialReadyBatch;
            return Align(
              alignment: Alignment.centerRight,
              child: Tooltip(
                message: partial
                    ? '优先按当前完整齐套量生产；其余 ${_host._qty(product.waitingQtyAfterSuggestedFirstBatch)} 待后续到料'
                    : product.readyNowQty <= 0
                    ? '当前尚未齐套，默认整批分配车间并进入待料'
                    : '当前可排产量已齐套',
                child: Text(
                  partial
                      ? '${_host._qty(product.suggestedFirstBatchQty)}（先产）'
                      : _host._qty(product.suggestedFirstBatchQty),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: partial
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                    fontWeight: partial ? FontWeight.w800 : null,
                  ),
                ),
              ),
            );
          },
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'maxSchedulableQty',
          label: '可排产上限',
          width: 104,
          numeric: true,
          cellBuilder: (context, row) => Align(
            alignment: Alignment.centerRight,
            child: Text(
              row.origin.product != null
                  ? _host._qty(row.origin.product!.maxSchedulableQty)
                  : '—',
            ),
          ),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'qty',
          label: '本批数量',
          width: 110,
          numeric: true,
          required: true,
          cellBuilder: (context, row) => row.isProduct
              ? RequiredCellFrame(
                  listenable: row.qty,
                  isEmpty: () =>
                      (double.tryParse(row.qty.text.trim()) ?? 0) <= 0,
                  child: TextField(
                    controller: row.qty,
                    readOnly: !_host._canGenerate,
                    textAlign: TextAlign.right,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '默认建议首批',
                    ),
                  ),
                )
              : const Align(alignment: Alignment.centerRight, child: Text('—')),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'workshop',
          label: '生产车间',
          width: 150,
          required: true,
          cellBuilder: (context, row) => row.isProduct
              ? ValueListenableBuilder<String?>(
                  valueListenable: row.departmentId,
                  builder: (context, departmentId, _) => InkWell(
                    key: ValueKey(
                      'material-analysis-bucket-workshop-${row.id}',
                    ),
                    onTap: _host._canGenerate ? () => _pickWorkshop(row) : null,
                    child: InputDecorator(
                      decoration: applyAutofillHint(
                        InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          suffixIcon: Icon(
                            departmentId == null
                                ? Icons.search_rounded
                                : Icons.unfold_more_rounded,
                            size: 16,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          suffixIconConstraints: const BoxConstraints(
                            minWidth: 20,
                          ),
                        ),
                        Theme.of(context),
                        // 学习默认带出=黄框提醒核对；手选后清除。
                        autofilled:
                            row.workshopAutofilled && departmentId != null,
                      ),
                      child: Text(
                        departmentId == null
                            ? (row.workshopAutofilled ? '默认车间待带出' : '点击选择')
                            : (row.departmentName ?? departmentId),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: departmentId == null
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                )
              : const Align(child: Text('—')),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'worker',
          label: '负责人',
          width: 130,
          required: true,
          cellBuilder: (context, row) => row.isProduct
              ? ValueListenableBuilder<String?>(
                  valueListenable: row.workerId,
                  builder: (context, workerId, _) => InkWell(
                    key: ValueKey('material-analysis-bucket-worker-${row.id}'),
                    onTap: _host._canGenerate ? () => _pickWorker(row) : null,
                    child: InputDecorator(
                      decoration: applyAutofillHint(
                        InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          suffixIcon: Icon(
                            workerId == null
                                ? Icons.search_rounded
                                : Icons.unfold_more_rounded,
                            size: 16,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          suffixIconConstraints: const BoxConstraints(
                            minWidth: 20,
                          ),
                        ),
                        Theme.of(context),
                        autofilled: row.workerAutofilled && workerId != null,
                      ),
                      child: Text(
                        workerId == null
                            ? '点击选择'
                            : (row.workerName ?? workerId),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: workerId == null
                              ? Theme.of(context).colorScheme.onSurfaceVariant
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                )
              : const Align(child: Text('—')),
        ),
        EditableGridColumn<_BucketPlanRow>(
          key: 'stage',
          label: '执行状态/下层',
          width: 170,
          cellBuilder: (context, row) {
            final product = row.origin.product;
            final label = product != null
                ? _host._productExecutionStage(product)?.label ?? '可生产'
                : (_host._canArrangePendingMakeCandidate(row.origin.candidate!)
                      ? row.origin.candidate!.material.lowerLevelPending
                            ? '可创建任务·后续待料'
                            : '下层齐套，可创建任务'
                      : '当前状态不可创建');
            return Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            );
          },
        ),
      ],
    );
  }

  List<MasterColumnDef<_BucketRow>> _bucketColumns() {
    switch (_bucket) {
      case _AnalysisBucket.buy:
      case _AnalysisBucket.subcontract:
      case _AnalysisBucket.make:
        return _materialGroupColumns();
      case _AnalysisBucket.ready:
      case _AnalysisBucket.waiting:
      case _AnalysisBucket.transferred:
        return _productColumns();
    }
  }

  /// 物料操作组列（采购/委外/自制桶）：物料 / BOM 路径 / 需求 / 缺口 /
  /// 建议路线 / 确认路线 / 下层状态。
  List<MasterColumnDef<_BucketRow>> _materialGroupColumns() {
    final host = _host;
    String routeLabelOf(MaterialSupplyRoute? route) => route?.label ?? '—';
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
      ),
      MasterColumnDef<_BucketRow>(
        key: 'shortageQty',
        label: '缺口',
        width: 90,
        type: 'number',
        value: (row) => host._qty(row.group?.representative.shortageQty),
        cellColor: (context, row) =>
            (row.group?.representative.shortageQty ?? 0) > 0
            ? Theme.of(context).colorScheme.error
            : null,
      ),
      MasterColumnDef<_BucketRow>(
        key: 'suggestion',
        label: '建议路线',
        width: 90,
        value: (row) =>
            routeLabelOf(row.group?.representative.sourceSuggestion),
      ),
      MasterColumnDef<_BucketRow>(
        key: 'confirmed',
        label: '确认路线',
        width: 90,
        value: (row) => routeLabelOf(row.group?.representative.confirmedRoute),
      ),
      MasterColumnDef<_BucketRow>(
        key: 'lowerLevel',
        label: '下层',
        width: 90,
        value: (row) {
          final m = row.group?.representative;
          if (m == null) return null;
          if (m.confirmedRoute != MaterialSupplyRoute.make &&
              m.confirmedRoute != MaterialSupplyRoute.subcontract) {
            return '—';
          }
          return m.lowerLevelPending ? '缺料·可先排' : '已齐套';
        },
      ),
    ];
  }

  /// 产品/候选列（暂不可安排/已转生产桶）。
  List<MasterColumnDef<_BucketRow>> _productColumns() {
    final host = _host;
    return [
      MasterColumnDef<_BucketRow>(
        key: 'goods',
        label: '产品',
        width: 200,
        value: (row) {
          if (row.product != null) {
            final code = row.product!.goodsCode?.trim();
            final name = row.product!.goodsName ?? '';
            return code?.isNotEmpty == true ? '$name（$code）' : name;
          }
          final m = row.candidate?.material;
          if (m == null) return null;
          return m.goodsName ?? m.goodsCode ?? m.materialLineId;
        },
      ),
      MasterColumnDef<_BucketRow>(
        key: 'order',
        label: '订单',
        width: 140,
        value: (row) {
          final no = row.product?.orderNo?.trim();
          return (no == null || no.isEmpty) ? null : no;
        },
      ),
      MasterColumnDef<_BucketRow>(
        key: 'parent',
        label: '上级',
        width: 140,
        value: (row) {
          final parent = row.candidate?.parentLabel?.trim();
          return (parent == null || parent.isEmpty) ? null : parent;
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
        key: 'remainingQty',
        label: '剩余',
        width: 90,
        type: 'number',
        value: (row) =>
            row.product == null ? null : host._qty(row.product!.remainingQty),
      ),
      MasterColumnDef<_BucketRow>(
        key: 'stage',
        label: '执行状态',
        width: 170,
        value: (row) {
          if (row.product != null) {
            return host._productExecutionStage(row.product!)?.label;
          }
          final candidate = row.candidate;
          if (candidate == null) return null;
          return host._canArrangePendingMakeCandidate(candidate)
              ? candidate.material.lowerLevelPending
                    ? '可安排（后续待料）'
                    : '可安排（下层齐套）'
              : '当前状态不可创建';
        },
      ),
      MasterColumnDef<_BucketRow>(
        key: 'blocker',
        label: '阻断摘要',
        width: 240,
        value: (row) {
          final product = row.product;
          if (product != null) {
            if (_bucket == _AnalysisBucket.transferred) {
              return host._productExecutionStage(product)?.detail;
            }
            if (host._canSelectProduct(product)) return null;
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
