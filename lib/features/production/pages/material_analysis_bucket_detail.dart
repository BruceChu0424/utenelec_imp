part of 'production_material_analysis_page.dart';

/// Preparation is organized by route; issue state remains inside each list.
/// Commands continue to use the host's permission, version and idempotency flow.
enum _AnalysisBucket { buy, subcontract, workshop }

enum _PreparationTaskFilter { pending, inProgress, issued, blocked }

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
    this.publicSurplusOnly = false,
  });

  final String materialLineId;
  final double qty;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;

  /// ADR-099：该候选的前置自制锚点已无剩余需求，本次全是追加的公共备货产出。
  final bool publicSurplusOnly;
}

/// 生成计划的已有产品行输入（可安排详情页收集，宿主页校验后单次下达）。
class _BucketPlanDraft {
  const _BucketPlanDraft({
    required this.analysisLineId,
    required this.qty,
    required this.departmentId,
    required this.workshopName,
    required this.workerId,
    this.publicSurplusOnly = false,
  });

  final String analysisLineId;
  final double qty;
  final String? departmentId;
  final String? workshopName;
  final String? workerId;

  /// ADR-099：锚点剩余需求已为 0，本行是明确的「再追加一批公共备货产出」。
  final bool publicSurplusOnly;
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
  const _MaterialAnalysisBucketPage({
    required this.host,
    required this.bucket,
    required this.initialFilter,
  });

  /// 宿主页状态（分桶投影/权限/执行编排都在宿主页链上；运行时实例永远是
  /// 最终实现类 _ProductionMaterialAnalysisPageState）。
  final _MaterialAnalysisProductTasksState host;
  final _AnalysisBucket bucket;
  final _PreparationTaskFilter initialFilter;

  @override
  State<_MaterialAnalysisBucketPage> createState() =>
      _MaterialAnalysisBucketPageState();
}

class _MaterialAnalysisBucketPageState
    extends State<_MaterialAnalysisBucketPage> {
  final Set<String> _selectedIds = {};
  late _PreparationTaskFilter _taskFilter;
  int _preparedChildCount = 0;

  /// 采购/委外桶的表头筛选（进度/缺口；视图级过滤，切段清空）。
  final Map<String, String?> _tableFilters = {};

  /// 已下达段的输入框是「追加量」：默认空，填了才追加。
  bool get _appendMode =>
      _taskFilter == _PreparationTaskFilter.issued ||
      _taskFilter == _PreparationTaskFilter.inProgress;

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
          _PreparationTaskFilter.inProgress => _host._bucketRowInProgress(
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

  bool _canSelectTask(_BucketRow row) => switch (_taskFilter) {
    _PreparationTaskFilter.pending => _host._bucketRowCanAct(row, _bucket),
    // ADR-099：已下达段里仍可追加的行也能勾（填追加量，属公共备货）。
    _PreparationTaskFilter.issued || _PreparationTaskFilter.inProgress =>
      _host._bucketRowCanAppend(row, _bucket),
    _PreparationTaskFilter.blocked => false,
  };

  /// 只读桶（MasterDataTableView）的分页：每页 [_pageSize] 行，只构建当页。
  /// 几百上千产品的分析里 waiting/buy 桶动辄数千行——一次性构建在网页端
  /// （CanvasKit 布局更慢）是分钟级卡死；分页后翻页即切页。勾选按业务 id
  /// 由本页持有，跨页天然保留。
  static const int _pageSize = 200;
  int _pageNo = 1;

  _MaterialAnalysisProductTasksState get _host => widget.host;
  _AnalysisBucket get _bucket => widget.bucket;

  @override
  void initState() {
    super.initState();
    _taskFilter = widget.initialFilter;
    // 宿主页「创建子件任务」后自动选中的子件：进桶时先勾上(能办的才勾)。
    for (final row in _host._bucketRows(_bucket)) {
      if (_host._selectedPlanLineIds.contains(row.id) && _canSelectTask(row)) {
        _selectedIds.add(row.id);
      }
    }
  }

  /// Only a successful workshop-bucket submission may return after its result
  /// dialog closes. A conflict/error stays on the page for inspection.
  ///
  /// 「关不关本页」看的是**本页是哪个桶**，不是请求类型（2026-09-16）：委外桶
  /// 里有子层的委外件如今也走 issue-plans 请求，但委外桶按既定契约永远留在
  /// 本页供计划员接着办下一批；只有下达车间桶成功才退出。
  void _popIfWorkshopIssued(bool issued) {
    if (!mounted ||
        !issued ||
        _bucket != _AnalysisBucket.workshop ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    Navigator.of(context).pop();
  }

  /// 提交 + 原地刷新（不退出本页）。[silent] = 父件段由「一起下单」弹窗编排
  /// （ADR-081）：跳过成功提示与生成结果弹层，由弹窗在最后统一汇报，避免
  /// 一次一键下单弹出多层结果。返回是否下达成功。
  Future<bool> _executeAndRefresh(
    _BucketActionRequest request, {
    bool silent = false,
  }) async {
    final before = _host._analysis;
    var issued = false;
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
      issued = await _host._executeBucketAction(request, silent: silent);
    } finally {
      if (mounted) {
        // Cancelled confirmations and rejected requests leave the authoritative
        // snapshot intact. Preserve the user's quantities, selections and staff
        // assignments so retrying does not require rebuilding the entire form.
        if (identical(before, _host._analysis)) {
          setState(() => _running = false);
        } else {
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
          setState(() {
            if (_bucket == _AnalysisBucket.workshop &&
                (_host._canGenerate || _host._canNotify)) {
              _taskFilter = _PreparationTaskFilter.pending;
            }
            _selectedIds.clear();
            // 刚建好的前置自制 / 委外子件任务默认勾上，接着就能为它们下达车间。
            for (final row in _host._bucketRows(_bucket)) {
              if (preparedIds.contains(row.id) && _canSelectTask(row)) {
                _selectedIds.add(row.id);
              }
            }
            _running = false;
          });
        }
      }
    }
    return issued;
  }

  /// 进「父件 + 下层一起下单」页提交(ADR-081 修订；2026-09-22 起三个桶**一律**
  /// 进页)：树顶是本次要下达的件，数量 / 车间 / 负责人都在那一页填，下层数量
  /// 按本批数量算好可改，点「一键下单」才按序提交父件与下层。没有下层的行
  /// (采购件、叶子委外件、追加行)也进页——那一页对它就是「核对并下单」；外层
  /// 桶表只是只读清单，上面没有任何输入框。
  ///
  /// [requests] 是父件段要依次提交的请求：采购桶一条 notify；车间桶一条
  /// issue-plans；委外桶最多两条——直接外发行的 notify + 需先自制行的
  /// issue-plans (2026-09-16)。请求里的数量 / 车间 / 负责人都是占位，提交时按
  /// 种子的当前内容重打([_patchRequestWithSeedInputs])。
  Future<void> _submitWithCascade(
    List<_BucketActionRequest> requests,
    List<_ChildCascadeSeed> seeds,
  ) async {
    if (_running || requests.isEmpty || seeds.isEmpty) return;
    // ADR-117：下单前记下每件的累计已下单量，下完比一比就知道这次刚下了什么。
    final issuedBefore = _host._issuedQtySnapshot();
    // ADR-099：下层数字由服务端算——车间通道先请求「下达预览」（服务端真实
    // 跑一遍 issue-plans 再整体回滚），期间挂加载遮罩；预览失败如实报错、
    // 不提交父件。采购件没有下层，不发请求。
    _CascadePending pending;
    _host.bucketActionBusyMessage.value = '正在按本批数量计算下层需求';
    try {
      pending = await _host._pendingChildCascadeRows(
        seeds,
        keepUnselectable: true,
      );
    } catch (error) {
      if (!mounted) return;
      context.appError(
        productionErrorMessage(error, fallback: '下层需求计算失败，请稍后重试'),
      );
      return;
    } finally {
      _host.bucketActionBusyMessage.value = null;
    }
    if (!mounted) return;
    if (pending.rows.isEmpty) {
      // 只有拿不到快照 / 没权限才会一行都没有：说清原因，什么都不提交。
      context.appWarning(pending.note ?? '当前不能进入下单页，请刷新后重试');
      return;
    }
    // 父件段逐条提交、逐条记住成功，重试只补没成功的那条：重发已成功的那条
    // 会因为快照换版拿到新幂等键，等于真实重复下单。
    final done = List<bool>.filled(requests.length, false);
    // 有下层要一起办时，成功提示与生成结果弹层由级联页最后统一汇报(silent)；
    // 没有下层的页就是原来的直接提交，计划单 / 提货单结果弹层、数量确认弹窗都
    // 照旧弹出，不能因为多过了一页就把它们吞掉。
    final silent = pending.rows.any((row) => !row.isSeed);
    final finished = await _host._showChildCascadeDialog(
      seeds: seeds,
      initialRows: pending.rows,
      previewView: pending.view,
      // 父件段提交时按种子**当前**内容重打请求——用户可能在「跟父件一起办」
      // 页面里改过树顶的本批数量 / 车间 / 负责人（改完既驱动下层重算，也改
      // 这里提交的量）；被祖先吸收的勾选行从父件请求里剔除，由级联页的车间段
      // 按算好的数量提交。委外 notify 同样支持按 actionGroupKey 传数量
      // （超量另需 over_supply 权限，由服务端自裁）。
      parentAction: () async {
        for (var index = 0; index < requests.length; index++) {
          if (done[index]) continue;
          final patched = _patchRequestWithSeedInputs(requests[index], seeds);
          // 这条请求的行全被祖先吸收：没有要单独提交的父件，视同已办。
          if (patched == null) {
            done[index] = true;
            continue;
          }
          final ok = await _executeAndRefresh(patched, silent: silent);
          if (!mounted || !ok) return false;
          done[index] = true;
        }
        return true;
      },
    );
    // 与 [_run] 同一条口径：只有下达车间桶成功才退出分桶页；采购/委外留在
    // 本页供计划员接着办下一批（2026-09-14：原来级联成功一律 pop，把委外桶也关了）。
    _popIfWorkshopIssued(finished);
    // ADR-117：下完之后看刚下单的件下面还缺不缺料——「父件 + 下层一起下单」页里
    // 取消勾选的下层、以后才下的更深一层，都在这里补一句提醒。弹窗叠在当前最上层
    // (车间桶已退回物料分析页，采购 / 委外桶仍在本页)。父件下成、下层那段失败或中途
    // 退出(finished=false)也要提醒；什么都没下成时前后快照一样，自然不弹。
    await _host._checkChildShortagesAfterOrder(issuedBefore);
    if (mounted) setState(() {});
  }

  /// 委外桶的一颗种子：通道、上限与驱动量三者必须与**服务端实际会收到的那
  /// 次提交**逐字一致。数量在级联页树顶填，这里只给默认值(= 原来桶表格里的
  /// 预填：还需安排量；已下达段是追加，默认 0)。
  ///
  /// 2026-09-16：有生成生产计划权限时，要先自制目标件的行改走 issue-plans 的
  /// ARRANGE 段(`_CascadeParentChannel.workshop`)——数量可改、超量按 V589 跟到
  /// 台账与行动、台账 + 锚点 + 计划同一事务建好；没有该权限才退回 notify
  /// 整量接管。
  _ChildCascadeSeed _subcontractSeed(_MaterialGroup group) {
    final material = group.representative;
    final channel = _subcontractChannelOf(group);
    const route = MaterialSupplyRoute.subcontract;
    return _ChildCascadeSeed(
      label: material.goodsName ?? material.goodsCode ?? group.key,
      channel: channel,
      maxQty: _host._residualSubmitQty(group, route),
      batchQty: _appendMode ? 0 : _host._defaultSubmitQty(group, route),
      materialLineId: material.materialLineId,
      actionGroupKey: material.actionGroupKey,
      groupKey: group.key,
      unitName: material.unitName,
      // 直接外发的 notify 通道自己会弹数量确认并裁决超量；改走 issue-plans 的
      // 行由级联页提交前补问。
      overQtyConfirmed: channel != _CascadeParentChannel.workshop,
    );
  }

  /// 采购桶的一颗种子：采购件没有下层，级联页对它只是「核对 / 改数量再提交」。
  /// 数量默认与原来桶表格里的预填一致(还需安排量，按起订量 / 订货倍数抬过)；
  /// 已下达段是追加，默认 0 = 本次不追加，要追加才在页里改成正数。
  _ChildCascadeSeed _buySeed(_MaterialGroup group) {
    final material = group.representative;
    const route = MaterialSupplyRoute.buy;
    return _ChildCascadeSeed(
      label: material.goodsName ?? material.goodsCode ?? group.key,
      channel: _CascadeParentChannel.buyDirect,
      maxQty: _host._residualSubmitQty(group, route),
      batchQty: _appendMode ? 0 : _host._defaultSubmitQty(group, route),
      materialLineId: material.materialLineId,
      actionGroupKey: material.actionGroupKey,
      groupKey: group.key,
      unitName: material.unitName,
      // notify 通道自己会弹数量确认并裁决超量，级联页不再重复问。
      overQtyConfirmed: true,
    );
  }

  /// 委外桶一行的父件段通道（ADR-099 起只有两条）：要先自制目标件的（有生产性
  /// 子层且不是 V581 单一子件件）走 issue-plans 的 ARRANGE 段——含顶层供给行，
  /// 服务端接受确认为委外的根行当候选，台账 + 锚点 + 计划同一事务建好；其余
  /// 直接外发走 notify。拿不到快照时保守按「要先自制」处理。
  _CascadeParentChannel _subcontractChannelOf(_MaterialGroup group) {
    final analysis = _host._analysis;
    final material = group.representative;
    final needsPreparation =
        analysis == null ||
        _host._subcontractNeedsPreparation(material, analysis);
    return needsPreparation
        ? _CascadeParentChannel.workshop
        : _CascadeParentChannel.subcontractDirect;
  }

  /// 把父件请求按种子的**当前**内容重打一遍：数量、生产车间、负责人——
  /// 级联页树顶可以改这三样，必须一起回写，否则界面显示 A 车间、提交的还是
  /// 上一页那个 B 车间。委外直接外发入口只回写数量（`NotifyRequest` 没有车间
  /// 字段，整件发给委外商不需要我方车间）。
  _BucketActionRequest? _patchRequestWithSeedInputs(
    _BucketActionRequest request,
    List<_ChildCascadeSeed> seeds,
  ) {
    if (request.type == _BucketActionType.buy ||
        request.type == _BucketActionType.subcontractOnly) {
      final keys = request.groupKeys;
      final patched = <String, String>{...?request.qtyByActionGroupKey};
      for (final seed in seeds) {
        final key = seed.actionGroupKey;
        if (key == null || key.isEmpty || seed.batchQty <= 0) continue;
        patched[key] = _bucketQtyText(seed.batchQty);
      }
      return request.type == _BucketActionType.buy
          ? _BucketActionRequest.buy(keys, qtyByActionGroupKey: patched)
          : _BucketActionRequest.subcontract(
              keys,
              qtyByActionGroupKey: patched,
            );
    }
    final byAnalysisLine = {
      for (final seed in seeds)
        if (seed.analysisLineId != null) seed.analysisLineId!: seed,
    };
    final byMaterialLine = {
      for (final seed in seeds)
        if (seed.materialLineId != null) seed.materialLineId!: seed,
    };
    final candidateInputs = <_BucketCandidatePlanInput>[
      for (final input
          in request.candidateInputs ?? const <_BucketCandidatePlanInput>[])
        () {
          final seed = byMaterialLine[input.materialLineId];
          return _BucketCandidatePlanInput(
            materialLineId: input.materialLineId,
            qty: seed?.batchQty ?? input.qty,
            departmentId: seed?.departmentId ?? input.departmentId,
            workshopName: seed?.departmentName ?? input.workshopName,
            workerId: seed?.workerId ?? input.workerId,
            publicSurplusOnly:
                input.publicSurplusOnly || (seed?.publicSurplusOnly ?? false),
          );
        }(),
    ];
    final planDrafts = <_BucketPlanDraft>[
      for (final draft in request.planDrafts ?? const <_BucketPlanDraft>[])
        () {
          final seed = byAnalysisLine[draft.analysisLineId];
          return _BucketPlanDraft(
            analysisLineId: draft.analysisLineId,
            qty: seed?.batchQty ?? draft.qty,
            departmentId: seed?.departmentId ?? draft.departmentId,
            workshopName: seed?.departmentName ?? draft.workshopName,
            workerId: seed?.workerId ?? draft.workerId,
            publicSurplusOnly:
                draft.publicSurplusOnly || (seed?.publicSurplusOnly ?? false),
          );
        }(),
    ];
    if (candidateInputs.isEmpty && planDrafts.isEmpty) return null;
    return _BucketActionRequest.createProductionPlans(
      candidateInputs: candidateInputs,
      planDrafts: planDrafts,
    );
  }

  bool _running = false;

  List<_MaterialGroup> _supplyGroupsForRow(_BucketRow row) {
    if (row.group != null) return [row.group!];
    if (row.candidate?.group != null) return [row.candidate!.group!];
    final product = row.product;
    final analysis = _host._analysis;
    if (product == null || analysis == null) return const [];
    // 车间桶的行是产品（如待生产的柜）：物料/调拨既可选产品本身（根供给
    // 行——把其它计划已下达的外部供给调进来冲减自制量），也可选其直接
    // 子件；调入只改覆盖数量，下达车间流程不变（2026-09-13 口径）。
    final root = _host._rootSupplyMaterialOf(product);
    final materials = [
      ?root,
      ..._host
          ._depth1MaterialsFor(product)
          .where((material) => material.materialLineId != root?.materialLineId),
    ];
    final indexes = _host._analysisIndexes(analysis);
    return [
      for (final material in materials)
        if (indexes.groupsByLine[material.materialLineId] != null)
          indexes.groupsByLine[material.materialLineId]!,
    ];
  }

  Future<void> _openSupplyDetails(_BucketRow row) async {
    if (_actionsLocked) return;
    final groups = _supplyGroupsForRow(row);
    if (groups.isEmpty) return;
    final before = _host._analysis;
    // 2026-09-13：车间桶的产品行（如待生产的柜）点「物料 / 调拨」直达
    // 根供给行的调拨选择器，不再先弹物料选择；根供给行缺失时才回退选择框。
    final isProductRow =
        row.product != null &&
        row.group == null &&
        row.candidate?.group == null;
    final _MaterialGroup group;
    if (isProductRow) {
      group = groups.firstWhere(
        (group) => group.representative.isRootSupply,
        orElse: () => groups.first,
      );
    } else if (groups.length == 1) {
      group = groups.single;
    } else {
      final selected = await showDialog<_MaterialGroup>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('选择需要查看或调拨的物料'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final group in groups)
                    ListTile(
                      title: Text(
                        group.representative.goodsName ??
                            group.representative.goodsCode ??
                            '物料',
                      ),
                      subtitle: Text(
                        '需求 ${_host._qty(group.representative.requiredQty)} · 物理缺口 ${_host._qty(group.representative.shortageQty)}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).pop(group),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      if (selected == null) return;
      group = selected;
    }
    if (!mounted) return;
    // 2026-09-13 起「物料 / 调拨」先进简化选择器（三个调入入口+完整详情），
    // 供给明细与记录留在完整详情里。
    await _host._showTransferLauncher(group);
    if (!mounted || identical(before, _host._analysis)) return;
    // 调拨改了缺口与在途：本页没有输入框要保，重建行集即可(数量在级联页里
    // 按进页那一刻的快照重新给默认值)。
    setState(() {
      _selectedIds.clear();
      _pageNo = 1;
    });
  }

  // ===== 与主表统一的身份四列：物料名称 / 编号 / 颜色 / 单位 =====
  // 2026-09-14 用户口径「三个入口的列表也用这样的形式，都统一，不要物料分析
  // 页面的表头一种、其他的不一样」。原先分桶详情把编号/规格/颜色塞在身份格里
  // （格式与主表副行各不相同），现在与主表同一组独立列，顺序也一致。

  /// 本行的物料事实来源：物料组 → 候选物料 → 产品的根供给行。
  ProductionMaterialAnalysisMaterial? _rowMaterial(_BucketRow row) {
    final group = row.group ?? row.candidate?.group;
    if (group != null) return group.representative;
    final material = row.candidate?.material;
    if (material != null) return material;
    final product = row.product;
    return product == null ? null : _host._rootSupplyMaterialOf(product);
  }

  String? _rowGoodsName(_BucketRow row) {
    final product = row.product;
    if (product != null) return product.goodsName ?? product.goodsCode;
    final material = _rowMaterial(row);
    return material?.goodsName ?? material?.goodsCode;
  }

  String? _rowGoodsCode(_BucketRow row) =>
      (row.product?.goodsCode ?? _rowMaterial(row)?.goodsCode)?.trim();

  String? _rowColorName(_BucketRow row) =>
      (row.product?.colorName ?? _rowMaterial(row)?.colorName)?.trim();

  String? _rowUnitName(_BucketRow row) =>
      (row.product?.unitName ?? _rowMaterial(row)?.unitName)?.trim();

  String? _rowSpec(_BucketRow row) =>
      (row.product?.spec ?? _rowMaterial(row)?.spec)?.trim();

  List<MasterColumnDef<_BucketRow>> _identityColumns() => [
    MasterColumnDef<_BucketRow>(
      key: 'goods',
      label: '物料名称',
      width: 220,
      value: _rowGoodsName,
      cellBuilderHandlesSemantics: true,
      // 顶层成品行名称后挂红色「顶层」小框；采购/委外桶的物料行没有 product，
      // 这些表照旧只出身份格。
      cellBuilder: (context, row) => _goodsNameCell(
        context,
        name: _rowGoodsName(row) ?? row.id,
        spec: _rowSpec(row),
        product: row.product,
      ),
    ),
    MasterColumnDef<_BucketRow>(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      value: _rowGoodsCode,
    ),
    MasterColumnDef<_BucketRow>(
      key: 'colorName',
      label: '颜色',
      width: 96,
      value: _rowColorName,
    ),
    MasterColumnDef<_BucketRow>(
      key: 'unitName',
      label: '单位',
      width: 76,
      value: _rowUnitName,
    ),
  ];

  /// 本行改路线时作用的操作组（产品行走它的根供给行）。
  _MaterialGroup? _rowRouteGroup(_BucketRow row) {
    final group = row.group ?? row.candidate?.group;
    if (group != null) return group;
    final product = row.product;
    final analysis = _host._analysis;
    if (product == null || analysis == null) return null;
    final root = _host._rootSupplyMaterialOf(product);
    return root == null
        ? null
        : _host._analysisIndexes(analysis).groupsByLine[root.materialLineId];
  }

  /// 供应方式列（2026-09-14）：三个入口都能就地改，确认后本行自动换到对应
  /// 入口；已下达 / 已有下游行动的行只读显示。
  MasterColumnDef<_BucketRow> _routeColumn() => MasterColumnDef<_BucketRow>(
    key: 'route',
    label: _host._l10n.materialRoute,
    width: 132,
    info:
        '这批物料怎么准备：采购 = 向供应商买；委外 = 发给加工商加工；'
        '自制 = 自己车间生产。在这里改并确认后，本行会立刻移到对应的入口，'
        '同时记为该货品下次的默认供料方式。',
    value: (row) {
      final group = _rowRouteGroup(row);
      return group == null ? null : _host._draftRoute(group).label;
    },
    cellBuilderHandlesSemantics: true,
    cellBuilder: (context, row) => _routeCell(context, row),
  );

  Widget _routeCell(BuildContext context, _BucketRow row) {
    final theme = Theme.of(context);
    final group = _rowRouteGroup(row);
    if (group == null) return const Text('—');
    final current = _host._draftRoute(group);
    final editable =
        !_actionsLocked &&
        _host._canRoute &&
        _host._canEditMaterialRoute(group);
    if (!editable) {
      return Text(
        current.label,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    // 2026-09-16 用户口径：表格内下拉统一用自家 UtenDropdownField（统一弹层/
    // 单行省略号/描边与同行格一致），不再用原生 DropdownButton。
    return UtenDropdownField(
      key: ValueKey('material-bucket-route-${row.id}'),
      dense: true,
      value: current.name,
      items: [
        for (final option in MaterialSupplyRoute.values)
          UtenDropdownItem(value: option.name, label: option.label),
      ],
      onChanged: (next) {
        if (next == null) return;
        _changeRoute(row, group, MaterialSupplyRoute.values.byName(next));
      },
    );
  }

  Future<void> _changeRoute(
    _BucketRow row,
    _MaterialGroup group,
    MaterialSupplyRoute? next,
  ) async {
    if (next == null || next == _host._draftRoute(group)) return;
    await _host._confirmRouteChange(group, next);
    if (!mounted) return;
    // 换桶后本页行集要跟着变：桶投影按 confirmed_route 算，宿主 setState
    // 不会重建本页。
    setState(() {
      _selectedIds.remove(row.id);
      _pageNo = 1;
    });
  }

  bool get _hasWriteAction => _canAct;

  /// 动作执行窗口（含宿主页 busy 与本页 _running——宿主页 busy 变化不通知
  /// 本页重建，故两态都压住批量入口）。
  bool get _actionsLocked => _host._busy || _running;

  bool get _canAct =>
      (_taskFilter == _PreparationTaskFilter.pending || _appendMode) &&
      switch (_bucket) {
        _AnalysisBucket.workshop => _host._canGenerate || _host._canNotify,
        _AnalysisBucket.buy || _AnalysisBucket.subcontract => _host._canNotify,
      };

  // ===== 提交：勾选的行一律进「父件 + 下层一起下单」页 =====

  /// 勾选的行 → 进「父件 + 下层一起下单」页(2026-09-22 用户口径「外面的不填数值，
  /// 得进到详情页才能填」)：数量 / 车间 / 负责人都在那一页填，外层表只是只读
  /// 清单。没有下层的行(采购件、叶子委外件、追加行)也进页，那一页对它就是
  /// 「核对并下单」。
  void _submitMaterialBucket(Set<String> selectedIds) {
    if (!_canAct || _actionsLocked) return;
    final rows = _filterRows(_host._bucketRows(_bucket));
    final allowedRows = [
      for (final row in rows)
        if (selectedIds.contains(row.id) && _canSelectTask(row)) row,
    ];
    if (allowedRows.isEmpty) return;
    switch (_bucket) {
      case _AnalysisBucket.buy:
        final groups = [for (final row in allowedRows) ?row.group];
        if (groups.isEmpty) return;
        unawaited(
          _submitWithCascade(
            [
              _BucketActionRequest.buy({
                for (final row in allowedRows)
                  if (row.group != null) row.id,
              }),
            ],
            [for (final group in groups) _buySeed(group)],
          ),
        );
      case _AnalysisBucket.subcontract:
        // 要先自制目标件的委外行(有生产性子层且不是 V581 单一子件件)在有生成
        // 生产计划权限时走 issue-plans 的 ARRANGE 段——数量可改、超量按 V589 跟
        // 到台账，台账 + 锚点 + 计划同一事务建好；其余直接外发走 notify。两类
        // 同时勾选时父件段按顺序提交两条请求(notify 在前)。
        final makeFirstRows = <_BucketRow>[];
        final notifyIds = <String>{};
        for (final row in allowedRows) {
          final group = row.group;
          if (group == null) continue;
          if (_subcontractChannelOf(group) == _CascadeParentChannel.workshop) {
            makeFirstRows.add(row);
          } else {
            notifyIds.add(row.id);
          }
        }
        // 要先自制目标件的委外件走 issue-plans：没有生成生产计划权限就下不了，
        // 当面说清，不让请求跑到服务端再被 403。
        if (makeFirstRows.isNotEmpty && !_host._canGenerate) {
          context.appWarning('所选委外件要先自制目标件再发外，需要生成生产计划权限才能下达');
          return;
        }
        unawaited(
          _submitWithCascade(
            [
              if (notifyIds.isNotEmpty)
                _BucketActionRequest.subcontract(notifyIds),
              if (makeFirstRows.isNotEmpty)
                _BucketActionRequest.createProductionPlans(
                  candidateInputs: [
                    for (final row in makeFirstRows)
                      _BucketCandidatePlanInput(
                        materialLineId:
                            row.group!.representative.materialLineId,
                        qty: _host._residualSubmitQty(
                          row.group!,
                          MaterialSupplyRoute.subcontract,
                        ),
                        // 数量 / 车间 / 负责人在级联页树顶填，提交时由
                        // `_patchRequestWithSeedInputs` 按种子回写。
                        departmentId: null,
                        workshopName: null,
                        workerId: null,
                      ),
                  ],
                ),
            ],
            [
              for (final row in allowedRows)
                if (row.group != null) _subcontractSeed(row.group!),
            ],
          ),
        );
      case _AnalysisBucket.workshop:
        if (_appendMode) {
          _submitAppendPlans(allowedRows);
        } else {
          _submitWorkshopPlans(allowedRows);
        }
    }
  }

  /// 排产下钻进来时路线种子上带的负责人(与原计划表「显式路线种子 > 学习记忆 >
  /// 车间主管」同一优先级)；没有就 null。
  ({String id, String? name})? _routeSeedWorker() {
    final id = _host.widget.seed.workerId;
    if (id == null || id.isEmpty) return null;
    final name = _host.ref.read(masterNameServiceProvider).employee(id);
    return (id: id, name: name == '—' ? null : name);
  }

  /// 下达车间未下达段：产品行与自制候选一起进级联页，数量默认 = 剩余需求
  /// (ADR-71：齐套拆批由执行段完成)，车间 / 负责人由级联页按货品学习默认带出
  /// (黄框提醒核对)、在页里改；超量在页里提交前确认(超出部分记公共备货产出)。
  void _submitWorkshopPlans(List<_BucketRow> rows) {
    final drafts = <_BucketPlanDraft>[];
    final candidateInputs = <_BucketCandidatePlanInput>[];
    final seeds = <_ChildCascadeSeed>[];
    final routeWorker = _routeSeedWorker();
    for (final row in rows) {
      final product = row.product;
      final candidate = row.candidate;
      if (product != null) {
        final qty = product.remainingQty;
        drafts.add(
          _BucketPlanDraft(
            analysisLineId: row.id,
            qty: qty,
            departmentId: null,
            workshopName: null,
            workerId: null,
          ),
        );
        seeds.add(
          _ChildCascadeSeed(
            label: product.goodsName ?? product.goodsCode ?? row.id,
            channel: _CascadeParentChannel.workshop,
            maxQty: qty,
            batchQty: qty,
            analysisLineId: row.id,
            unitName: product.unitName,
            // 显式路线种子的负责人先带上；级联页只在空着时才补学习默认。
            workerId: routeWorker?.id,
            workerName: routeWorker?.name,
            workerAutofilled: routeWorker != null,
          ),
        );
      } else if (candidate != null && candidate.group != null) {
        final qty = _host._residualSubmitQty(candidate.group!, candidate.route);
        candidateInputs.add(
          _BucketCandidatePlanInput(
            materialLineId: candidate.material.materialLineId,
            qty: qty,
            departmentId: null,
            workshopName: null,
            workerId: null,
          ),
        );
        seeds.add(
          _ChildCascadeSeed(
            label:
                candidate.material.goodsName ??
                candidate.material.goodsCode ??
                row.id,
            channel: _CascadeParentChannel.workshop,
            maxQty: qty,
            batchQty: qty,
            materialLineId: candidate.material.materialLineId,
            groupKey: candidate.group!.key,
            unitName: candidate.material.unitName,
          ),
        );
      }
    }
    if (drafts.isEmpty && candidateInputs.isEmpty) {
      context.appInfo('所选候选当前不可创建，请刷新后重试');
      return;
    }
    unawaited(
      _submitWithCascade([
        _BucketActionRequest.createProductionPlans(
          candidateInputs: candidateInputs,
          planDrafts: drafts,
        ),
      ], seeds),
    );
  }

  /// 下达车间已下达段的追加(ADR-099)：需求已全部转入计划的产品行进级联页填
  /// 追加量——本批全是**纯公共备货产出**(publicSurplusOnly)，树顶填车间 / 负责人，
  /// 下层按放大后的需求一起办；服务端只对显式声明的行放行。追加量默认 0，在
  /// 页里改成正数才下。
  void _submitAppendPlans(List<_BucketRow> rows) {
    final drafts = <_BucketPlanDraft>[];
    final seeds = <_ChildCascadeSeed>[];
    for (final row in rows) {
      final product = row.product;
      if (product == null) continue;
      drafts.add(
        _BucketPlanDraft(
          analysisLineId: row.id,
          qty: 0,
          departmentId: null,
          workshopName: null,
          workerId: null,
          publicSurplusOnly: true,
        ),
      );
      seeds.add(
        _ChildCascadeSeed(
          label: product.goodsName ?? product.goodsCode ?? row.id,
          channel: _CascadeParentChannel.workshop,
          // 需求已全部转入计划：上限 0，本批全是追加的公共备货产出，级联页
          // 提交前照常过一次超量确认。
          maxQty: 0,
          batchQty: 0,
          analysisLineId: row.id,
          unitName: product.unitName,
          publicSurplusOnly: true,
        ),
      );
    }
    if (drafts.isEmpty) return;
    unawaited(
      _submitWithCascade([
        _BucketActionRequest.createProductionPlans(planDrafts: drafts),
      ], seeds),
    );
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
          // 2026-09-12：下达采购/委外的通用加载遮罩（车间仍走下方专用遮罩）。
          ValueListenableBuilder<String?>(
            valueListenable: _host.bucketActionBusyMessage,
            builder: (context, message, _) => message != null
                ? Positioned.fill(
                    child: UtenBusyOverlay(
                      title: message,
                      description: '同一事务内批量处理所选行，完成后自动刷新。',
                    ),
                  )
                : const SizedBox.shrink(),
          ),
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
                    value: _PreparationTaskFilter.inProgress,
                    label: '进行中',
                    count: allRows
                        .where(
                          (row) => _host._bucketRowInProgress(row, _bucket),
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
                  });
                },
              ),
              const SizedBox(height: UtenSpacing.s8),
              // 2026-09-22 起三个桶同一张只读清单(原下达车间的可编辑计划表退役)：
              // 勿传 virtualized(它强制表体撑满剩余高度 → 横滚条恒钉屏底)；保持
              // 默认 content-tall，内容少横滚条贴末行、超高才钉底。
              Expanded(child: _bucketTable(rows)),
            ],
          ),
        ),
      ),
    );
  }

  /// 分页切片：只构建当页行(大分析数千行一次性构建在网页端是分钟级卡死)。
  int _pageTotal(List<_BucketRow> rows) =>
      rows.length <= _pageSize ? 1 : (rows.length / _pageSize).ceil();

  List<_BucketRow> _pageRows(List<_BucketRow> rows, int page) {
    if (rows.length <= _pageSize) return rows;
    final start = (page - 1) * _pageSize;
    if (start >= rows.length) return rows.sublist(0);
    final end = (start + _pageSize).clamp(0, rows.length);
    return rows.sublist(start, end);
  }

  /// 三个桶共用的只读清单(2026-09-22 用户口径「外面的不填数值，得进到详情页
  /// 才能填；表格只显示对应重要的信息」)：身份四列 + 供应方式 / 需求量 / 缺口 /
  /// 进度；已下达段把缺口换成下达数量并多一列已下达单据。勾选行点底部按钮、
  /// 或双击一行，都进「父件 + 下层一起下单」页；其余信息(所属仓库、归属车间、
  /// BOM 路径、仓库余量、公共认领未实收)搬进那一页。
  Widget _bucketTable(List<_BucketRow> rows) {
    final theme = Theme.of(context);
    // 进度 / 缺口两列表头可点筛选(视图级过滤不动选择)，三个桶都给。
    final progressCounts = <String, int>{};
    var gapCount = 0;
    for (final row in rows) {
      final label = _rowProgress(theme, row).label;
      if (label != null) {
        progressCounts[label] = (progressCounts[label] ?? 0) + 1;
      }
      if ((_rowShortageQty(row) ?? 0) > 0) gapCount++;
    }
    final progressFacets = [
      for (final entry in progressCounts.entries)
        MasterFacetBucket(
          value: entry.key,
          count: entry.value,
          label: entry.key,
        ),
    ]..sort((a, b) => a.display.compareTo(b.display));
    final columns = _bucketColumns(theme);
    // 文本列(物料名称 / 编号 / 颜色 / 单位 / 供应方式)按单元格文本分桶：用户口径
    // 2026-09-11「同一张表里类型 / 货品也要有筛选箭头」——桶表改只读后「类型」列
    // 退役, 其余文本列一个不落, 同名货品合并成一桶。
    const textFacetKeys = {
      'goods',
      'goodsCode',
      'colorName',
      'unitName',
      'route',
    };
    final textColumns = {
      for (final column in columns)
        if (textFacetKeys.contains(column.key)) column.key: column.value,
    };
    final textCounts = <String, Map<String, int>>{};
    for (final row in rows) {
      for (final entry in textColumns.entries) {
        final text = entry.value(row)?.trim();
        if (text == null || text.isEmpty) continue;
        final counts = textCounts.putIfAbsent(entry.key, () => {});
        counts[text] = (counts[text] ?? 0) + 1;
      }
    }
    final textFacets = {
      for (final entry in textCounts.entries)
        entry.key: [
          for (final bucket in entry.value.entries)
            MasterFacetBucket(value: bucket.key, count: bucket.value),
        ]..sort((a, b) => a.display.compareTo(b.display)),
    };
    final progressFilter = _tableFilters['taskState'];
    final gapFilter = _tableFilters['shortageQty'];
    final textFilters = {
      for (final entry in _tableFilters.entries)
        if (entry.value != null && textColumns.containsKey(entry.key))
          entry.key: entry.value!,
    };
    final filtered =
        progressFilter == null && gapFilter == null && textFilters.isEmpty
        ? rows
        : rows
              .where((row) {
                if (progressFilter != null &&
                    _rowProgress(theme, row).label != progressFilter) {
                  return false;
                }
                if (gapFilter != null && (_rowShortageQty(row) ?? 0) <= 0) {
                  return false;
                }
                for (final entry in textFilters.entries) {
                  if (textColumns[entry.key]!(row)?.trim() != entry.value) {
                    return false;
                  }
                }
                return true;
              })
              .toList(growable: false);
    final filteredTotalPages = _pageTotal(filtered);
    final filteredPage = _pageNo.clamp(1, filteredTotalPages);
    // 已下达段只在真有可追加的行时才出勾选列与动作组(ADR-099)。
    final selectable = _canAct && (!_appendMode || rows.any(_canSelectTask));
    return MasterDataTableView<_BucketRow>(
      columns: columns,
      items: _pageRows(filtered, filteredPage),
      facets: {
        ...textFacets,
        if (progressFacets.isNotEmpty) 'taskState': progressFacets,
        if (!_appendMode && gapCount > 0)
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
      selectable: selectable,
      idOf: (row) => _canSelectTask(row) ? row.id : null,
      rowKeyOf: (row) => row.id,
      selectedIds: _selectedIds,
      onSelectedIdsChanged: (next) => setState(() {
        _selectedIds
          ..clear()
          ..addAll(next);
      }),
      batchActionsBuilder: selectable ? _batchActions : null,
      rowMenuBuilder: _rowMenu,
      // 单击选中、双击打开：能办的行双击直接进下单页办它这一行。
      onRowTap: _onRowTap,
      enableTextSelection: false,
      showFullscreenToggle: false,
      canOpenRow: (row) =>
          _canSelectTask(row) ||
          row.group != null ||
          (_host._canViewPlans &&
              (row.product?.latestPlanId?.trim().isNotEmpty ?? false)),
      emptyMessage: _host._l10n.materialTaskEmpty,
      currentPage: filteredPage,
      totalPages: filteredTotalPages,
      onPageChange: (next) => setState(() => _pageNo = next),
    );
  }

  /// 底部动作组：跨页全选 + 一颗「进下单页」按钮。省略号 = 这一下不是提交，
  /// 是进「父件 + 下层一起下单」页；真正的提交在那一页的「一键下单 / 下单」里。
  /// 文案不能更长：悬浮动作组在窄屏下会溢出。
  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    if (!_hasWriteAction) return const [];
    final count = selectedIds.length;
    final append = _appendMode;
    final label = switch (_bucket) {
      _AnalysisBucket.buy => append ? '追加采购($count)…' : '提交采购需求($count)…',
      _AnalysisBucket.subcontract => append ? '追加委外($count)…' : '下达委外($count)…',
      _AnalysisBucket.workshop =>
        append ? '追加生产计划($count)…' : '创建生产计划($count)…',
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
      UtenButton(
        // 下达车间沿用既有键名(一批用例按它定位)。
        key: Key(
          _bucket == _AnalysisBucket.workshop
              ? 'material-analysis-bucket-action-ready'
              : 'material-analysis-bucket-action-${_bucket.name}',
        ),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: _bucket == _AnalysisBucket.workshop
            ? Icons.factory_outlined
            : Icons.notifications_active_outlined,
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

  /// 行右键 / 长按菜单：进下单页办这一行、物料调拨、全链路进度。
  List<UtenContextMenuEntry> _rowMenu(_BucketRow row) => [
    if (_canSelectTask(row))
      UtenMenuItem(
        label: _appendMode ? '进详情页追加' : '进详情页下单',
        icon: Icons.open_in_new_rounded,
        enabled: _canAct && !_actionsLocked,
        onTap: () => _submitMaterialBucket({row.id}),
      ),
    UtenMenuItem(
      label: '物料调拨与公共在途',
      icon: Icons.inventory_2_outlined,
      enabled: !_actionsLocked && _supplyGroupsForRow(row).isNotEmpty,
      onTap: () => _openSupplyDetails(row),
    ),
    if (row.group != null ||
        (_host._canViewPlans &&
            (row.product?.latestPlanId?.trim().isNotEmpty ?? false)))
      UtenMenuItem(
        label: row.group != null ? '全链路进度' : '查看生产计划',
        icon: Icons.timeline_rounded,
        enabled: !_actionsLocked,
        onTap: () => _showProgress(row),
      ),
  ];

  /// 双击一行：能办的行直接进「父件 + 下层一起下单」页办它这一行；不能办的
  /// 行看进度。
  void _onRowTap(_BucketRow row) {
    if (_canAct && !_actionsLocked && _canSelectTask(row)) {
      _submitMaterialBucket({row.id});
      return;
    }
    _showProgress(row);
  }

  /// 物料行弹全链路进度；已下达的产品行进它的生产计划详情。
  void _showProgress(_BucketRow row) {
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

  // ===== 三种行形态(物料组 / 产品 / 自制候选)的同名取值 =====

  /// 需求量：物料行 = 本批需求；产品行 = 本批产品数量；候选 = 让料后补自制量或
  /// 本批需求。
  double? _rowRequiredQty(_BucketRow row) {
    final group = row.group;
    if (group != null) return group.representative.requiredQty;
    final product = row.product;
    if (product != null) return product.requestedQty;
    final candidate = row.candidate;
    if (candidate == null) return null;
    return candidate.material.hasPriorityMakeSupplement
        ? candidate.material.priorityMakeSupplementQty
        : candidate.material.requiredQty;
  }

  /// 缺口：物料行 = 服务端物理缺口；产品行 = 还没转入计划的剩余需求；候选 =
  /// 还需安排量。
  double? _rowShortageQty(_BucketRow row) {
    final group = row.group;
    if (group != null) return group.representative.shortageQty;
    final product = row.product;
    if (product != null) return product.remainingQty;
    final candidate = row.candidate;
    if (candidate?.group == null) return null;
    return _host._residualSubmitQty(candidate!.group!, candidate.route);
  }

  /// 已下达段的「下达数量」：物料行 = 已下达单据的真实下单总量(含公共备货 /
  /// 安全补库；无行动快照时回落分摊合计)；产品行 = 生产计划量。
  double? _rowIssuedQty(_BucketRow row) {
    final group = row.group;
    final route = _bucket.supplyRoute;
    if (group != null && route != null) {
      return _issuedOrderTotal(group, route)?.total ??
          _issuedSubmitQty(group, route);
    }
    return row.product?.planExecutionPlannedQty;
  }

  /// 进度：物料行走供给进度词表；产品行走执行阶段(未下达统一「等待下达车间」，
  /// 路线待确认给红字原因)；候选看还能不能创建。
  ({String? label, Color? color}) _rowProgress(
    ThemeData theme,
    _BucketRow row,
  ) {
    final group = row.group;
    if (group != null) {
      final status = _host._materialStatus(theme, group);
      return (label: status.label, color: status.color);
    }
    final product = row.product;
    if (product != null) {
      final stage = _host._productExecutionStage(product);
      if (stage != null) {
        return (
          label: stage.displayLabel,
          color: _host._productExecutionColor(theme, stage),
        );
      }
      if (product.canSchedule) return (label: '等待下达车间', color: null);
      // 顶层路线待确认：红色浅底与物料行一致(cellColor 组件层保证文字对比度)。
      return (
        label:
            _host._rootRouteScheduleHint(product) ??
            product.scheduleBlockedReason ??
            _host._l10n.materialTaskBlocked,
        color: _host._rootRoutePending(product)
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.3)
            : null,
      );
    }
    final candidate = row.candidate;
    if (candidate == null) return (label: null, color: null);
    return (
      label: _host._canArrangePendingMakeCandidate(candidate)
          ? '等待下达车间'
          : '当前状态不可创建',
      color: null,
    );
  }

  /// 这条产品行是不是**顶层**成品(销售 / 手工来源),而不是自制 / 委外子件。
  ///
  /// `parentAnalysisLineId` 是服务端给的结构事实:只有子件行才有父装配行
  /// (模型注释「Null for top-level sales/manual sources」)。`sourceType` 再兜一道,
  /// 脏数据缺父指针时也不会把子件当顶层。
  bool _isTopLevelProduct(ProductionMaterialAnalysisProduct? product) =>
      product != null &&
      (product.parentAnalysisLineId?.isEmpty ?? true) &&
      product.sourceType != 'MAKE_COMPONENT' &&
      product.sourceType != 'SUBCONTRACT_MAKE';

  /// 物料名称格：身份格 + 顶层产品的红色「顶层」小框。
  ///
  /// 2026-09-15 用户口径：下达车间里一眼看不出哪一行是顶层——2026-09-05 起
  /// 「顶层与子层自制同构」，类型列一律写「自制候选」，顶层和子件长得一模一样。
  /// 名称后挂个红框就分得清「这一行是成品」。
  ///
  /// **不走 [UtenGoodsIdentityCell.trailing]**：那会在名称外面包一层 `Row`，而
  /// 本页族既有用例按「离名称最近的 Row = 整行」定位数量框与复选框
  /// (`material_analysis_root_routes_test` 等)，包了就全定位不到。`Wrap` 不是
  /// `Row`，排版等效(列窄时徽章换行而不是溢出)，定位契约因此不变。
  Widget _goodsNameCell(
    BuildContext context, {
    required String name,
    String? spec,
    ProductionMaterialAnalysisProduct? product,
  }) {
    // 编号/颜色已各自成列，身份格只补规格(它没有独立列，丢了就看不到)。
    final cell = UtenGoodsIdentityCell(name: name, spec: spec);
    if (!_isTopLevelProduct(product)) return cell;
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: UtenSpacing.s4,
      children: [
        cell,
        Container(
          key: const ValueKey('material-analysis-top-level-badge'),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: UtenRadius.smAll,
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Text(
            '顶层',
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  /// 「未下达」筛选段的路线化标签（与流程词表第一步同名）。
  String get _pendingIssueFilterLabel => switch (_bucket) {
    _AnalysisBucket.buy => '等待下发采购',
    _AnalysisBucket.subcontract => '等待下发委外',
    _AnalysisBucket.workshop => '等待下达车间',
  };

  /// 三个桶同一组列(2026-09-22)：身份四列 / 供应方式 / 需求量 / 缺口(未下达段) /
  /// 下达数量(已下达段) / 已下达单据(采购、委外的已下达段) / 进度。
  List<MasterColumnDef<_BucketRow>> _bucketColumns(ThemeData theme) {
    final host = _host;
    final issued = _appendMode;
    final route = _bucket.supplyRoute;
    return [
      ..._identityColumns(),
      _routeColumn(),
      MasterColumnDef<_BucketRow>(
        key: 'requiredQty',
        label: '需求量',
        width: 100,
        type: 'number',
        value: (row) => host._qty(_rowRequiredQty(row)),
        info: '本批生产需要的总量（按产品数量 × 单件用量算出）。',
      ),
      // 缺口始终使用服务端实际缺料事实；下达量和公共备货不改变本批需求。
      // 仅未下达段保留(已下达段看已下总量与到货进度)。
      if (!issued)
        MasterColumnDef<_BucketRow>(
          key: 'shortageQty',
          label: '缺口',
          width: 90,
          type: 'number',
          value: (row) => host._qty(_rowShortageQty(row)),
          info:
              '${host._l10n.materialPhysicalShortageHint}'
              '下达车间的行显示还没转入计划的剩余需求。',
          cellBuilder: (context, row) {
            final shortage = _rowShortageQty(row);
            if (shortage == null) return const SizedBox.shrink();
            // key 供测试/语义锚定「物理缺口」单元格；颜色与主表同一口径。
            return KeyedSubtree(
              key: const Key('bucket-shortage-qty-cell'),
              child: Text(
                host._qty(shortage),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: host._shortageTextColor(theme, shortage),
                  fontWeight: FontWeight.w700,
                ),
              ),
            );
          },
          cellColor: (context, row) {
            final shortage = _rowShortageQty(row);
            return shortage == null
                ? null
                : host._shortageCellColor(Theme.of(context), shortage);
          },
        ),
      if (issued)
        MasterColumnDef<_BucketRow>(
          key: 'issuedQty',
          label: '下达数量',
          width: 110,
          type: 'number',
          value: (row) => host._qty(_rowIssuedQty(row)),
          info:
              '已下达单据的真实下单总量(含公共备货与安全补库)；下达车间的行显示'
              '生产计划量。要追加就勾上这一行进详情页填追加量。',
        ),
      if (issued && route != null)
        MasterColumnDef<_BucketRow>(
          key: 'supplyProgress',
          label: '${host._l10n.materialTaskIssued}单据',
          width: 240,
          // 只展示单号：状态与全链路进度走行菜单「全链路进度」。
          value: (row) => row.group?.paths
              .expand((path) => path.notifiedTargets)
              .where((target) => target.target == route)
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
        value: (row) => _rowProgress(theme, row).label,
        cellColor: (context, row) => _rowProgress(Theme.of(context), row).color,
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

  /// 行动 id → 权威数量快照（服务端 supplyActions 投影）。每次重建 columns
  /// 时建一次即可：分析视图整体替换，缓存与视图同生命周期。
  Map<String, MaterialAnalysisSupplyAction>? _supplyActionIndexCache;
  ProductionMaterialAnalysisView? _supplyActionIndexOwner;

  Map<String, MaterialAnalysisSupplyAction> get _supplyActionsById {
    final analysis = _host._analysis;
    if (!identical(analysis, _supplyActionIndexOwner)) {
      _supplyActionIndexOwner = analysis;
      _supplyActionIndexCache = {
        for (final action
            in analysis?.supplyActions ??
                const <MaterialAnalysisSupplyAction>[])
          if (action.actionId.isNotEmpty) action.actionId: action,
      };
    }
    return _supplyActionIndexCache ?? const {};
  }

  /// 已下达段每行「订单总量 / 公共备货量」：按 actionId 关联到服务端行动快照，
  /// total = requested + safety + public_surplus（服务端已算好 totalRequestedQty），
  /// surplus = 公共备货 + 公共安全补库（都不绑定本需求，ADR-070 §2.7）。
  ///
  /// 同一 action 会分摊到同组多条 BOM 路径，**必须按 actionId 去重**否则翻倍；
  /// 非 SUPPLY 行动（在途调入 / 公共认领）只搬在途份额、没有自己的订单量，跳过。
  /// 2026-09-15 起「已下达」段该值直接作为「下达数量」显示（真实下单总量），
  /// 独立的「订单总量」列退役。
  ({double total, double surplus})? _issuedOrderTotal(
    _MaterialGroup group,
    MaterialSupplyRoute route,
  ) {
    final index = _supplyActionsById;
    if (index.isEmpty) return null;
    final counted = <String>{};
    var total = 0.0;
    var surplus = 0.0;
    var matched = false;
    for (final path in group.paths) {
      for (final target in path.notifiedTargets) {
        if (target.target != route) continue;
        if (target.status == 'CANCELLED') continue;
        final actionId = target.actionId;
        if (actionId == null || !counted.add(actionId)) continue;
        final action = index[actionId];
        if (action == null) continue;
        final operation = action.operationType?.trim().toUpperCase();
        if (operation != null &&
            operation.isNotEmpty &&
            operation != 'SUPPLY') {
          continue;
        }
        matched = true;
        total += action.totalRequestedQty;
        surplus += action.publicSurplusQty + action.safetyReplenishmentQty;
      }
    }
    return matched ? (total: total, surplus: surplus) : null;
  }
}
