part of 'production_material_analysis_page.dart';

abstract class _MaterialAnalysisChildCascadeState
    extends _MaterialAnalysisMaterialTableState {
  /// 展开上限：一棵深 BOM 可以炸出几千行，本页不是主表，超过就明说被截断。
  static const int _cascadeRowLimit = 300;

  /// 深度上限：超过一样要明说（BOM 真有 10 层以上时用户必须知道更深的料没列
  /// 出来，否则会以为「下层就这些」）。
  static const int _cascadeDepthLimit = 10;

  /// 上一次展开是否撞上了行数 / 深度上限。页面顶部据此给出**明确**提示。
  bool _cascadeRowLimitHit = false;
  bool _cascadeDepthLimitHit = false;

  // ===== 一、向服务端要「下达之后」的快照（ADR-099） =====

  /// 车间通道种子对应的 issue-plans 行（预览与真实下达同一份输入）。
  List<MaterialAnalysisIssueLine> _cascadeIssueLines(
    List<_ChildCascadeSeed> seeds,
  ) => [
    for (final seed in seeds)
      if (seed.channel == _CascadeParentChannel.workshop &&
          seed.batchQty > 0 &&
          seed.batchQty.isFinite)
        MaterialAnalysisIssueLine(
          materialLineId: seed.materialLineId,
          analysisLineId: seed.materialLineId == null
              ? seed.analysisLineId
              : null,
          qty: seed.batchQty,
          departmentId: seed.departmentId,
          workshopName: seed.departmentName,
          workerId: seed.workerId,
          publicSurplusOnly: seed.publicSurplusOnly,
        ),
  ];

  /// 在树里还带着下层的提交单元：只有这些行的数量值得回服务端重算一遍
  /// (叶子行改量不影响任何人)。同一提交单元在树里出现多次时，任一处有下层
  /// 就算有。
  Set<String> _cascadeSubmitKeysWithChildren(List<_ChildCascadeRow> rows) {
    final keys = <String>{};
    for (var index = 0; index + 1 < rows.length; index++) {
      if (rows[index + 1].depth > rows[index].depth) {
        keys.add(rows[index].submitKey);
      }
    }
    return keys;
  }

  /// 层级表上**用户亲手填过**的那些行的数量(键 = 物料行 id)：服务端按它补齐
  /// 各自节点的**计划产出量**，子层、孙层按新数量重算。
  ///
  /// **只收用户手工改过的行**(2026-09-21 用户口径「如果跟着父类变、但是子类没有
  /// 更改过，父类再变也跟着变」)：没手工改过的行，它格子里那个数只是上一轮父行
  /// 传下来的回声，送回服务端只会经「与缺口取大」把子树钉在旧值上——父件改小时
  /// 孙层就降不下来。不送它，服务端便从父件的新数量一路算到底。
  ///
  /// 还要「下面确实带着层级」且「能下达」；填 0 的追加行自然不进来
  /// (0 不改变任何东西)。
  ///
  /// 树顶那一行不在这里：它由 [_cascadePreviewTypedOutputs] 按「这次要不要真跑
  /// 一遍下达」决定走哪条路。
  /// [willIssue] = 这一行本次真的会下(默认全算)。没勾的行不下单，也就不该
  /// 带动它的子层——「看到的勾选 = 提交的内容」，数字也得跟着这条走。
  Map<String, double> _cascadeTypedOutputs(
    List<_ChildCascadeRow> rows, {
    bool Function(_ChildCascadeRow row)? willIssue,
  }) {
    final withChildren = _cascadeSubmitKeysWithChildren(rows);
    return {
      for (final row in rows)
        if (!row.isSeed &&
            row.ownsInput &&
            row.material != null &&
            row.blockedReason == null &&
            row.userTypedQty != null &&
            withChildren.contains(row.submitKey) &&
            row.userTypedQty! > 0.0001 &&
            (willIssue == null || willIssue(row)))
          // 送**用户亲手填的那个数**，不是框里显示的数：框里可能是页面按父行
          // 比例换算出来的、或按下限替他抬上去的值。服务端那一侧是「加进计划
          // 产出量再与缺口取大」，送一个被放大过的数上去，它就成了整棵子树的
          // 地板，回来又被子层原样采纳，再也降不下来。地板该是多少，服务端
          // 自己会从父行算出来。
          row.material!.materialLineId: row.userTypedQty!,
    };
  }

  /// 本次重算要带给服务端的全部「每行填了多少」。
  ///
  /// 树顶那一行分两种走法：**车间通道**([lines] 里那些)由服务端真跑一遍
  /// issue-plans，量已经落在计划链接上，再补一次就成了双倍，所以不进这里；
  /// **直接外发的委外通道**不模拟下达(它不建计划)，它填的量只能按计划产出量
  /// 补进去——不然「委外件按 1500 下达、我方供料的那颗子件仍按 1000 备」
  /// (2026-09-21 用户口径：委外也要能超量，多下的量要带大子件需求)。
  /// [seedPending] = 父件段还没提交；已提交过的(重试模式)它的量已经是库里的
  /// 事实，不能再补一次。
  Map<String, double> _cascadePreviewTypedOutputs(
    List<_ChildCascadeSeed> seeds,
    List<_ChildCascadeRow> rows,
    List<MaterialAnalysisIssueLine> lines, {
    required bool seedPending,
    bool Function(_ChildCascadeRow row)? willIssue,
  }) {
    final simulated = {
      for (final line in lines) line.materialLineId ?? line.analysisLineId,
    };
    return {
      for (final seed in seeds)
        if (seedPending &&
            seed.materialLineId != null &&
            !simulated.contains(seed.materialLineId) &&
            seed.batchQty > 0 &&
            seed.batchQty.isFinite)
          seed.materialLineId!: seed.batchQty,
      ..._cascadeTypedOutputs(rows, willIssue: willIssue),
    };
  }

  /// 下达预览：服务端按同一套代码真实跑一遍 issue-plans 再整体回滚，返回
  /// 「下达之后」的分析快照——下层需求按计划产出量放大、锚点配额自动增长、
  /// 还需安排量全部是服务端口径。[rows] 里各层填的数量一并带上，中间层改量
  /// 同样带得动它的子层(ADR-099 修订 2026-09-21)。
  ///
  /// 返回 null = 本页还没有快照 / 仓库（调用方按「不进页」处理）。
  Future<ProductionMaterialAnalysisView?> _previewCascadeView(
    List<_ChildCascadeSeed> seeds, {
    List<_ChildCascadeRow> rows = const [],
    bool includeSeedIssue = true,
    bool seedPending = true,
    bool Function(_ChildCascadeRow row)? willIssue,
  }) async {
    final analysis = _analysis;
    final warehouseId = _warehouseId;
    if (analysis == null || warehouseId == null) return null;
    final lines = includeSeedIssue
        ? _cascadeIssueLines(seeds)
        : const <MaterialAnalysisIssueLine>[];
    final typedOutputs = _cascadePreviewTypedOutputs(
      seeds,
      rows,
      lines,
      seedPending: seedPending,
      willIssue: willIssue,
    );
    if (lines.isEmpty && typedOutputs.isEmpty) return analysis;
    // 预览专用的新键：它在服务端随事务一起回滚，不能与真实下达撞键。
    final key = businessIdempotencyKey(
      'material-analysis-issue-preview',
      [
        analysis.analysisId,
        analysis.version,
        analysis.fingerprint,
        DateTime.now().microsecondsSinceEpoch,
        for (final line in lines) line.toJson().toString(),
      ].join('|'),
    );
    return ref
        .read(productionPlanRepositoryProvider)
        .previewIssuePlans(
          analysis: analysis,
          warehouseId: warehouseId,
          idempotencyKey: key,
          billDate: _dateText(_billDate)!,
          deliveryDate: _dateText(_deliveryDate),
          approveNow: _permissions.contains(Perm.productionPlanApprove),
          lines: lines,
          typedOutputs: typedOutputs,
        );
  }

  /// 车间通道的种子必须带车间才能预览（服务端出计划要车间）。分桶页没有
  /// 车间列的入口（委外桶）进来时按学习默认 / 车间主管先补上，级联页照样
  /// 标黄提醒核对；补不上的留空，由级联页选了车间后再预览。
  Future<void> _prefillSeedWorkshops(List<_ChildCascadeSeed> seeds) async {
    final analysis = _analysis;
    if (analysis == null) return;
    final indexes = _analysisIndexes(analysis);
    final pending = [
      for (final seed in seeds)
        if (seed.needsWorkshop && (seed.departmentId?.isEmpty ?? true)) seed,
    ];
    if (pending.isEmpty) return;
    String? goodsOf(_ChildCascadeSeed seed) {
      if (seed.materialLineId != null) {
        return indexes
            .groupsByLine[seed.materialLineId]
            ?.representative
            .goodsId;
      }
      return indexes.productsById[seed.analysisLineId]?.goodsId;
    }

    final goodsIds = {
      for (final seed in pending)
        if (goodsOf(seed)?.isNotEmpty == true) goodsOf(seed)!,
    };
    if (goodsIds.isEmpty) return;
    Map<
      String,
      ({
        String departmentId,
        String? departmentName,
        String? workerId,
        String? workerName,
      })
    >
    learned = const {};
    List<DepartmentNode> workshops = const [];
    try {
      learned = await ref
          .read(productionPlanRepositoryProvider)
          .defaultWorkshops(goodsIds);
      final tree = await ref.read(departmentRepositoryProvider).tree();
      workshops =
          findDepartmentByCode(tree, kDeptCodeProduction)?.children ?? const [];
    } catch (_) {
      // 默认值只是省一步手选，取不到不阻断；级联页仍要求填车间才能下达。
    }
    if (!mounted) return;
    final managers = {
      for (final node in workshops)
        if (node.managerId?.isNotEmpty == true)
          node.id: (id: node.managerId, name: node.managerName),
    };
    for (final seed in pending) {
      final defaults = learned[goodsOf(seed)];
      if (defaults == null) continue;
      seed.departmentId = defaults.departmentId;
      seed.departmentName = defaults.departmentName;
      seed.workshopAutofilled = true;
      final manager = managers[defaults.departmentId];
      seed.workerId = defaults.workerId ?? manager?.id;
      seed.workerName = defaults.workerName ?? manager?.name;
      seed.workerAutofilled = seed.workerId != null;
    }
  }

  // ===== 二、按快照展开下层 =====

  /// 把本次下达的各行按 BOM 自顶向下展开成层级行。数量全部读 [view]
  /// （车间通道 = 服务端下达预览；直接外发委外 / 父件提交后的重建 = 当前
  /// 真实快照）。
  List<_ChildCascadeRow> _buildChildCascadeRows(
    List<_ChildCascadeSeed> seeds,
    ProductionMaterialAnalysisView view,
  ) {
    if (seeds.isEmpty) return const [];
    final nodes = _cascadeNodes(seeds, view);
    if (nodes.isEmpty) return const [];
    return _materializeCascadeRows(nodes, view, _analysisIndexes(view));
  }

  /// 纯展开：只产出层级节点，不建任何 TextEditingController
  /// （只会顺带更新 [_cascadeRowLimitHit] / [_cascadeDepthLimitHit]）。
  /// 「进不进级联页」与「页面里长什么样」由同一次展开回答。
  List<_CascadeNode> _cascadeNodes(
    List<_ChildCascadeSeed> seeds,
    ProductionMaterialAnalysisView view,
  ) {
    final presentation = _bomPresentation(view);
    final indexes = _analysisIndexes(view);
    final childrenByParent =
        <String?, List<ProductionMaterialAnalysisMaterial>>{};
    for (final material in view.materials) {
      if (material.isRootSupply) continue;
      childrenByParent
          .putIfAbsent(
            presentation.parentIdsByMaterial[material.materialLineId],
            () => [],
          )
          .add(material);
    }
    // 兄弟行排序走与准备页主表同一个比较器（先层级、再货品编号）。
    for (final children in childrenByParent.values) {
      children.sort(_compareBomSiblings);
    }
    final byLine = {
      for (final material in view.materials) material.materialLineId: material,
    };
    final anchors = <_ChildCascadeSeed, ({String? parentId, int order})>{};
    for (final seed in seeds) {
      final resolved = _resolveCascadeAnchor(seed, view, indexes);
      if (resolved == null) continue;
      anchors[seed] = (parentId: resolved, order: anchors.length);
    }
    // 别的种子的展开起点：撞上就跳过——那一行是它自己那棵树的树顶，本次按
    // 它在分桶页填的数量单独下达，不在祖先树里重复列出。
    final seedRootIds = {
      for (final entry in anchors.values)
        if (entry.parentId != null) entry.parentId!,
    };
    final nodes = <_CascadeNode>[];
    var rowLimitHit = false;
    var depthLimitHit = false;
    var treeIndex = -1;

    void walk({
      required String? parentId,
      required int depth,
      required String seedLabel,
      required String? scopeAnalysisLineId,
      required Set<String> ancestors,
    }) {
      if (rowLimitHit) return;
      if (depth > _cascadeDepthLimit) {
        depthLimitHit = true;
        return;
      }
      final children = childrenByParent[parentId] ?? const [];
      for (final child in children) {
        if (nodes.length >= _cascadeRowLimit) {
          rowLimitHit = true;
          return;
        }
        // 旧载荷没有 ROOT_SUPPLY 行时按 parent=null 聚齐了所有产品的直接层，
        // 必须再按分析行过滤，否则会把别的产品的料算进来。
        if (parentId == null &&
            scopeAnalysisLineId != null &&
            child.analysisLineId != scopeAnalysisLineId) {
          continue;
        }
        // SHIP / REFERENCE 不写正式生产需求（ADR-029 §4.1），不在办齐范围。
        if (_isNonProductionStage(child.controlStage)) continue;
        // 环保护：只拦「自己是自己的祖先」，不拦兄弟分支重复用同一个物料。
        if (ancestors.contains(child.materialLineId)) continue;
        if (seedRootIds.contains(child.materialLineId)) continue;
        nodes.add((
          material: child,
          product: null,
          depth: depth,
          treeIndex: treeIndex,
          seedLabel: seedLabel,
          isSeed: false,
          seed: null,
        ));
        final group = indexes.groupsByLine[child.materialLineId];
        final route = group == null ? null : _draftRoute(group);
        // 这里问的是「BOM 上还有没有下层要一起办」：V581 的单一子件委外虽然
        // 走 notify，那颗子件仍要我方备出来，必须继续下钻。
        final descend =
            route == MaterialSupplyRoute.make ||
            (route == MaterialSupplyRoute.subcontract &&
                _hasProductionBomChildren(child, view));
        if (!descend) continue;
        walk(
          parentId: child.materialLineId,
          depth: depth + 1,
          seedLabel: seedLabel,
          scopeAnalysisLineId: scopeAnalysisLineId,
          ancestors: {...ancestors, child.materialLineId},
        );
      }
    }

    final ordered = anchors.entries.toList(growable: false)
      ..sort((left, right) => left.value.order.compareTo(right.value.order));
    for (final entry in ordered) {
      final seed = entry.key;
      final before = nodes.length;
      treeIndex++;
      // 树顶先占一行：本次要下达的那个件本身。快照没有 ROOT_SUPPLY 行时
      // 回退到产品行本身当树顶——它只做身份与数量，不参与提交。
      final anchorMaterial = byLine[entry.value.parentId];
      final seedProduct = seed.analysisLineId == null
          ? null
          : indexes.productsById[seed.analysisLineId];
      nodes.add((
        material: anchorMaterial,
        product: anchorMaterial == null ? seedProduct : null,
        depth: 0,
        treeIndex: treeIndex,
        seedLabel: seed.label,
        isSeed: true,
        seed: seed,
      ));
      walk(
        parentId: entry.value.parentId,
        depth: 1,
        seedLabel: seed.label,
        scopeAnalysisLineId: entry.value.parentId == null
            ? seed.analysisLineId
            : null,
        ancestors: {?entry.value.parentId},
      );
      // 这条种子一个下层都没展开出来：树顶那行独自留着只是噪音。
      if (nodes.length == before + 1) {
        nodes.removeLast();
        treeIndex--;
      }
    }
    _cascadeRowLimitHit = rowLimitHit;
    _cascadeDepthLimitHit = depthLimitHit;
    return nodes;
  }

  /// 种子 → 展开起点（子树父节点的物料行 id；null = 顶层产品且无根供给行）。
  /// 返回 null 表示这颗种子在 [view] 里解析不出来。
  String? _resolveCascadeAnchor(
    _ChildCascadeSeed seed,
    ProductionMaterialAnalysisView view,
    _MaterialAnalysisIndexes indexes,
  ) {
    final materialLineId = seed.materialLineId;
    if (materialLineId != null) {
      return indexes
          .groupsByLine[materialLineId]
          ?.representative
          .materialLineId;
    }
    final analysisLineId = seed.analysisLineId;
    final product = analysisLineId == null
        ? null
        : indexes.productsById[analysisLineId];
    if (product == null) return null;
    if (_isEmbeddedMakeChildProduct(product)) {
      // 锚点子件不展开自己的 BOM（ADR-071 §四）：它的料仍留在原树的来源
      // 节点下，展开起点必须回到那个节点。
      return indexes
          .materialsByAnchorProduct[product.analysisLineId]
          ?.materialLineId;
    }
    final rootId = product.rootMaterialLineId;
    final root = rootId == null
        ? null
        : view.materials
              .where(
                (material) =>
                    material.materialLineId == rootId &&
                    material.analysisLineId == product.analysisLineId &&
                    material.isRootSupply,
              )
              .firstOrNull;
    return root?.materialLineId;
  }

  /// 展开结果 → 可提交行：同一提交单元（actionGroupKey）合并到第一处，其余
  /// 保留为层级上下文；需求、还需安排量、可认领在途全部读服务端快照。
  List<_ChildCascadeRow> _materializeCascadeRows(
    List<_CascadeNode> nodes,
    ProductionMaterialAnalysisView view,
    _MaterialAnalysisIndexes indexes,
  ) {
    final pathsBySubmitKey =
        <String, List<ProductionMaterialAnalysisMaterial>>{};
    for (final material in view.materials) {
      // 提交单元的成员集合必须与服务端 `selectedGroups` 同口径：只收
      // actionable / 根供给 / 优先补自制的行。
      if (!material.actionable &&
          !material.isRootSupply &&
          !material.hasPriorityMakeSupplement) {
        continue;
      }
      final key = material.actionGroupKey ?? material.materialLineId;
      pathsBySubmitKey.putIfAbsent(key, () => []).add(material);
    }
    final ownerIndex = <String, int>{};
    final requiredSum = <String, double>{};
    final mergedCount = <String, int>{};
    for (var index = 0; index < nodes.length; index++) {
      final material = nodes[index].material;
      if (nodes[index].isSeed || material == null) continue;
      final key = material.actionGroupKey ?? material.materialLineId;
      ownerIndex.putIfAbsent(key, () => index);
      requiredSum[key] = (requiredSum[key] ?? 0) + material.requiredQty;
      mergedCount[key] = (mergedCount[key] ?? 0) + 1;
    }
    final rows = <_ChildCascadeRow>[];
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      final material = node.material;
      if (material == null) {
        rows.add(_seedOnlyRow(node));
        continue;
      }
      final submitKey = material.actionGroupKey ?? material.materialLineId;
      final group = indexes.groupsByLine[material.materialLineId];
      final ownsInput = !node.isSeed && ownerIndex[submitKey] == index;
      final route = group == null
          ? MaterialSupplyRoute.subcontract
          : _draftRoute(group);
      final kind = _cascadeKindOf(material, route, view);
      final submitGroup = group == null
          ? null
          : _MaterialGroup(
              key: group.key,
              paths: pathsBySubmitKey[submitKey] ?? group.paths,
            );
      // 已建自制子件任务的行按锚点追加：可下达余量 = 锚点剩余可排量（父件
      // 超量下达后服务端已让锚点配额跟着需求增长）。需先自制的委外件不走
      // 锚点——按候选行提交，服务端的 ARRANGE 段自己给既有台账增量。
      final anchor =
          kind == _CascadeKind.workshop &&
              route == MaterialSupplyRoute.make &&
              material.planAnchorAnalysisLineId != null
          ? indexes.productsById[material.planAnchorAnalysisLineId]
          : null;
      // 有自制子层的委外件：已建前置自制任务时按它的锚点判断还能不能再追加。
      // 只做判定与声明，提交通道不变（仍走候选行 ARRANGE，台账才跟得上量）。
      final preparationAnchor =
          kind == _CascadeKind.workshop &&
              route == MaterialSupplyRoute.subcontract &&
              material.planAnchorAnalysisLineId != null
          ? indexes.productsById[material.planAnchorAnalysisLineId]
          : null;
      final residual = anchor != null
          ? (anchor.canSchedule ? anchor.remainingQty : 0.0)
          : submitGroup == null
          ? 0.0
          : _residualSubmitQty(submitGroup, route);
      final claimable = kind == _CascadeKind.workshop
          ? 0.0
          : (submitGroup?.representative.sharedFutureClaimableQty ?? 0.0);
      // 此前下过的单（父层级这里仍可追加）：采购 / 直接外发委外读下游引用；
      // 已建自制任务的行读锚点。
      final ordered = kind == _CascadeKind.workshop || submitGroup == null
          ? null
          : _openSupplyLineOf(submitGroup, route);
      // 超出「还需安排」的部分属主动公共备货：采购 / 直接外发委外要
      // over_supply 权限，没有的账号不给填（免得填完在提交时才被服务端拒）；
      // 车间侧的公共备货产出按 V577 不要这道权限。
      final workshopAnchor = anchor ?? preparationAnchor;
      final allowsExtra = switch (kind) {
        _CascadeKind.buy || _CascadeKind.subcontractLeaf => _canOverSupply,
        _CascadeKind.workshop =>
          workshopAnchor != null &&
              (workshopAnchor.canIssueSurplus || workshopAnchor.canSchedule),
      };
      // 采购行的预填值要和采购桶逐字同源：按最小起订量 / 订货倍数向上抬
      // （软约束，不进下限）。
      final suggested = submitGroup != null && kind == _CascadeKind.buy
          ? _submitQtyWithOrderPolicy(submitGroup, route, residual)
          : residual;
      final row = _ChildCascadeRow(
        material: material,
        product: null,
        groupKey: group?.key ?? 'NONE|${material.materialLineId}',
        submitKey: submitKey,
        depth: node.depth,
        treeIndex: node.treeIndex,
        seedLabel: node.seedLabel,
        route: route,
        kind: kind,
        requiredQty: ownsInput
            ? (requiredSum[submitKey] ?? material.requiredQty)
            : material.requiredQty,
        residual: residual,
        claimableQty: claimable,
        suggested: suggested,
        ownsInput: ownsInput,
        mergedPathCount: ownsInput ? (mergedCount[submitKey] ?? 1) : 1,
        blockedReason: ownsInput
            ? _cascadeBlockedReason(material, group, route, kind, anchor)
            : null,
        allowsExtra: allowsExtra,
        orderedQty: anchor != null
            ? anchor.issuedPlanQty
            : (ordered?.orderedQty ?? 0),
        growableLineQty: ordered?.growableQty,
        orderedDocumentNo: anchor != null
            ? anchor.latestPlanNo
            : ordered?.documentNo,
        isSeed: node.isSeed,
        seed: node.seed,
        anchorAnalysisLineId: anchor?.analysisLineId,
        preparationAnchorAnalysisLineId: preparationAnchor?.analysisLineId,
      )..seedUnitName = node.seed?.unitName;
      rows.add(row);
    }
    return rows;
  }

  /// 没有物料行的树顶：只承担「最上面那一行 + 数量」，不可勾选、不可提交。
  _ChildCascadeRow _seedOnlyRow(_CascadeNode node) => _ChildCascadeRow(
    material: null,
    product: node.product,
    groupKey: 'SEED|${node.product?.analysisLineId ?? node.seedLabel}',
    submitKey: 'SEED|${node.product?.analysisLineId ?? node.seedLabel}',
    depth: node.depth,
    treeIndex: node.treeIndex,
    seedLabel: node.seedLabel,
    route: MaterialSupplyRoute.make,
    kind: _CascadeKind.workshop,
    requiredQty: node.seed?.batchQty ?? 0,
    residual: 0,
    claimableQty: 0,
    suggested: 0,
    ownsInput: false,
    mergedPathCount: 1,
    blockedReason: null,
    isSeed: true,
    seed: node.seed,
  )..seedUnitName = node.seed?.unitName;

  _CascadeKind _cascadeKindOf(
    ProductionMaterialAnalysisMaterial material,
    MaterialSupplyRoute route,
    ProductionMaterialAnalysisView view,
  ) => switch (route) {
    MaterialSupplyRoute.buy => _CascadeKind.buy,
    MaterialSupplyRoute.make => _CascadeKind.workshop,
    // V581：「只有一个叶子子件」的委外件虽然有下层，却不进车间——仓库直接把
    // 那个子件发给委外商，所以父件段走 notify（与无子层同一条通道）。
    MaterialSupplyRoute.subcontract =>
      _subcontractNeedsPreparation(material, view)
          ? _CascadeKind.workshop
          : _CascadeKind.subcontractLeaf,
  };

  /// 本提交单元此前在该路线上下过的单：已下达量（未撤销分摊之和）、最近一张
  /// 单据的单号，以及最近一条**仍未被处理**的申请明细数量（服务端
  /// growableLineQty 非空 = 采购 / 委外部门还没动过，追加会就地改大）。
  ({double orderedQty, double? growableQty, String? documentNo})?
  _openSupplyLineOf(_MaterialGroup group, MaterialSupplyRoute route) {
    var ordered = 0.0;
    double? growable;
    String? documentNo;
    final seenActions = <String>{};
    for (final path in group.paths) {
      for (final target in path.notifiedTargets) {
        if (target.target != route ||
            target.isRootOutput ||
            target.status == 'CANCELLED') {
          continue;
        }
        ordered += target.allocatedQty ?? 0;
        final actionKey = target.actionId ?? target.documentId ?? '';
        if (!seenActions.add(actionKey)) continue;
        if (target.documentNo != null) documentNo = target.documentNo;
        growable = target.growableLineQty;
      }
    }
    if (ordered <= 0.0001 && growable == null && documentNo == null) {
      return null;
    }
    return (orderedQty: ordered, growableQty: growable, documentNo: documentNo);
  }

  /// 本行为什么不能在这里下达。fail-closed：说不清就不放行，让人回主表处理。
  String? _cascadeBlockedReason(
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup? group,
    MaterialSupplyRoute route,
    _CascadeKind kind,
    ProductionMaterialAnalysisProduct? anchor,
  ) {
    if (group == null) return '本行来源无法解析，请回主表核对';
    final planningBlock = _planningBlockForGroup(group);
    if (planningBlock != null) return planningBlock;
    if (!_hasResolvedMaterialSource(material)) return '本行来源无法解析，请回主表核对';
    if (material.confirmedRoute == null) {
      if (!_canRoute) return '没有确认物料路线权限';
      if (!_canEditMaterialRoute(group)) return '本行已有下游行动，路线不可改，请回主表核对';
      // 主档来源为空时 _draftRoute 只能兜底委外——那是缺省值不是决定
      // （生产物料分析页 §3.4），不允许在这里替人确认。
      if (material.sourceSuggestion == null) {
        return '主档来源为空，请先在主表确认路线';
      }
    }
    if (kind == _CascadeKind.workshop) {
      if (!_canGenerate) return '没有生成生产计划权限';
      // 需求已全部转入计划的锚点仍可追加一批纯公共备货产出（canIssueSurplus）。
      if (anchor != null && !anchor.canSchedule && !anchor.canIssueSurplus) {
        return anchor.scheduleBlockedReason ?? '本行的自制任务当前不可排产，请到「下达车间」核对';
      }
      if (anchor == null &&
          route == MaterialSupplyRoute.make &&
          !material.hasPriorityMakeSupplement &&
          _hasIssuedMakeOwnership(material)) {
        return '本行已有下达记录但解析不到对应的子件任务，请刷新物料分析后到「下达车间」核对';
      }
      return null;
    }
    if (!_canNotify) return '没有下达采购/委外权限';
    if (_routeBlockedBySafetyGap(group, route)) {
      return '存在公共安全补库缺口，仅采购路线可下达';
    }
    return null;
  }

  // ===== 三、入口：先进页，一键下单里再提交父件 =====

  /// 进不进「父件 + 下层一起办」整页，以及**为什么**；行集来自哪份快照也一并
  /// 返回。每一条不进页的路径都必须给出非空 reason，不静默跳过。
  @override
  Future<_CascadePending> _pendingChildCascadeRows(
    List<_ChildCascadeSeed> seeds, {
    bool keepUnselectable = false,
  }) async {
    const none = (rows: <_ChildCascadeRow>[], note: null, view: null);
    if (!mounted || seeds.isEmpty || _analysis == null) return none;
    if (!_canNotify && !_canGenerate) {
      return (
        rows: const <_ChildCascadeRow>[],
        note: '没有下达采购/委外或生成生产计划权限，下层物料本次未办理',
        view: null,
      );
    }
    await _prefillSeedWorkshops(seeds);
    if (!mounted) return none;
    // 车间通道的种子都带上了车间才能预览；否则先按当前快照展开，级联页里
    // 选了车间后再向服务端要一份预览。
    final previewable = seeds
        .where((seed) => seed.needsWorkshop)
        .every((seed) => seed.departmentId?.isNotEmpty == true);
    final view = previewable ? await _previewCascadeView(seeds) : _analysis;
    if (view == null || !mounted) return none;
    final nodes = _cascadeNodes(seeds, view);
    final hasChildNode = nodes.any((node) => !node.isSeed);
    if (!hasChildNode) {
      // 没有下层但树顶要在页里填车间/负责人（已下达段追加、委外桶进来的行）：
      // 只带树顶行进页，一键下单时按树顶输入提交父件。
      if (keepUnselectable) {
        return (
          rows: _materializeCascadeRows(nodes, view, _analysisIndexes(view)),
          note: 'BOM 上没有需要本次一起办的生产性子件，本次只需为父件填车间/负责人',
          view: view,
        );
      }
      return (
        rows: const <_ChildCascadeRow>[],
        note: _cascadeRowLimitHit || _cascadeDepthLimitHit
            ? '下层结构过大（超过 $_cascadeRowLimit 行或 $_cascadeDepthLimit 层），'
                  '本次未展开下层，请到物料分析主表逐层办理'
            : '已检查下层：BOM 上没有需要本次一起办的生产性子件'
                  '（出货/参考阶段的子件不形成备料需求），本次只下达所选行',
        view: view,
      );
    }
    final rows = _materializeCascadeRows(nodes, view, _analysisIndexes(view));
    if (rows.any((row) => row.selectable)) {
      return (rows: rows, note: null, view: view);
    }
    final children = rows.where((row) => !row.isSeed && row.ownsInput).toList();
    final blocked = children
        .where((row) => row.blockedReason != null)
        .toList(growable: false);
    // 树顶种子本身要在页面里填车间/负责人时，即便下层一行都不能勾也要进页。
    if (keepUnselectable) {
      return (
        rows: rows,
        note: children.isEmpty
            ? '下层都已由本批其它行接管或已下过单，本次只需为父件填车间/负责人'
            : '下层 ${children.length} 行当前无需/不能在本页下单，本次只需为父件填车间/负责人',
        view: view,
      );
    }
    for (final row in rows) {
      row.dispose();
    }
    if (children.isEmpty) {
      return (
        rows: const <_ChildCascadeRow>[],
        note: _cascadeRowLimitHit || _cascadeDepthLimitHit
            ? '下层结构过大（超过 $_cascadeRowLimit 行或 $_cascadeDepthLimit 层），'
                  '本次未展开下层，请到物料分析主表逐层办理'
            : '已检查下层：这些子件都已由本批其它行接管，本次只下达所选行',
        view: view,
      );
    }
    if (blocked.isNotEmpty) {
      final names = blocked.take(5).map((row) => row.displayName).join('、');
      return (
        rows: const <_ChildCascadeRow>[],
        note:
            '下层 ${blocked.length} 行当前办不了（$names'
            '${blocked.length > 5 ? ' 等' : ''}）：${blocked.first.blockedReason}。'
            '下层请回物料分析主表处理',
        view: view,
      );
    }
    return (
      rows: const <_ChildCascadeRow>[],
      note: '已检查下层：按本批数量算都已下过单，本次只下达所选行',
      view: view,
    );
  }

  /// 进入「父件 + 下层一起下单」整页。[parentAction] = 父件提交段（null =
  /// 重试模式，父件已提交过）。返回 true = 全部段成功。
  @override
  Future<bool> _showChildCascadeDialog({
    required List<_ChildCascadeSeed> seeds,
    required List<_ChildCascadeRow> initialRows,
    required ProductionMaterialAnalysisView? previewView,
    Future<bool> Function()? parentAction,
  }) async {
    if (!mounted) return false;
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _ChildCascadePage(
          host: this,
          seeds: seeds,
          initialRows: initialRows,
          previewView: previewView,
          parentAction: parentAction,
        ),
      ),
    );
    return done == true;
  }

  // ===== 四、一键下单：父件 → 路线确认 → 采购 → 委外 → 车间 =====

  /// 按路线分流依次下达。**不是一个事务**：逐段调用既有的下达链路，每段自带
  /// 幂等键、CAS 与 409 恢复；任一段失败即停下并如实回报。
  ///
  /// [parentAction] = 父件提交段：先提交父件本身，成功后经 [rebuildAfterParent]
  /// 按最新**真实**快照重建下层行并继承已填数量——预览快照此时作废。
  Future<List<_CascadeStepResult>> _executeChildCascade(
    List<_ChildCascadeRow> rows, {
    required List<_ChildCascadeSeed> seeds,
    Future<bool> Function()? parentAction,
    List<_ChildCascadeRow> Function()? rebuildAfterParent,
    int parentCount = 1,
  }) async {
    final results = <_CascadeStepResult>[];
    if (rows.isEmpty) return results;
    // 0) 父件段。
    if (parentAction != null) {
      final ok = await parentAction();
      if (!mounted) return results;
      results.add((
        label: '父件下达',
        count: ok ? parentCount : 0,
        ok: ok,
        note: ok ? null : '父件未提交成功，下层未动，可直接重试',
      ));
      if (!ok) return results;
      if (rebuildAfterParent != null) {
        final before = {for (final row in rows) row.submitKey: row.displayName};
        rows = rebuildAfterParent();
        final afterKeys = {for (final row in rows) row.submitKey};
        // 掉出集合的行分两类：真正被父件顺带办掉的（快照里已无可下达余量）
        // 才是成功；因路线 / 权限 / 资格被挡住而退出的是**没办成**，必须点名。
        final dropped = before.keys
            .where((key) => !afterKeys.contains(key))
            .toList(growable: false);
        if (dropped.isNotEmpty) {
          final analysis = _analysis;
          final fresh = analysis == null
              ? const <_ChildCascadeRow>[]
              : _buildChildCascadeRows(seeds, analysis);
          final blocked = <String>[];
          final delegated = <String>[];
          for (final key in dropped) {
            final row = fresh
                .where((candidate) => candidate.submitKey == key)
                .firstOrNull;
            if (row != null && row.blockedReason != null) {
              blocked.add('${row.displayName}（${row.blockedReason}）');
              continue;
            }
            final name = before[key];
            if (name != null && _isDelegatedAwaySubmitKey(key)) {
              delegated.add(name);
            }
          }
          for (final row in fresh) {
            row.dispose();
          }
          final done = dropped.length - blocked.length - delegated.length;
          if (done > 0) {
            results.add((label: '已随父件下达办妥', count: done, ok: true, note: null));
          }
          if (delegated.isNotEmpty) {
            results.add((
              label: '需求已转交前置自制任务',
              count: delegated.length,
              ok: true,
              note:
                  '${_names(delegated)}：这些料的备料责任已转给刚建的前置自制任务，'
                  '本次没有为它们下单——请在该任务的物料分析里继续办理',
            ));
          }
          if (blocked.isNotEmpty) {
            results.add((
              label: '下层未办理',
              count: blocked.length,
              ok: false,
              note:
                  '${blocked.take(5).join('、')}'
                  '${blocked.length > 5 ? ' 等 ${blocked.length} 行' : ''}'
                  '——父件已下达，这些下层请回物料分析主表处理',
            ));
            return results;
          }
        }
        if (rows.isEmpty) return results;
      }
    }
    // 1) 先确认路线：三条下达链路都以「已确认路线」为硬门槛（ADR-029 §6.1）。
    final needRoute = [
      for (final row in rows)
        if (_analysisGroupOf(row.groupKey)?.representative.confirmedRoute !=
            row.route)
          row,
    ];
    if (needRoute.isNotEmpty) {
      if (!_canRoute) {
        results.add((
          label: '确认物料路线',
          count: needRoute.length,
          ok: false,
          note: '没有确认物料路线权限',
        ));
        return results;
      }
      setState(() {
        for (final row in needRoute) {
          _routeDraft[row.groupKey] = row.route;
          _dirtyRouteGroups.add(row.groupKey);
        }
        _invalidateBucketRowsCache();
      });
      await _saveRoutes(
        onlyGroupKeys: {for (final row in needRoute) row.groupKey},
      );
      if (!mounted) return results;
      final stillPending = [
        for (final row in needRoute)
          if (_analysisGroupOf(row.groupKey)?.representative.confirmedRoute !=
              row.route)
            row,
      ];
      results.add((
        label: '确认物料路线',
        count: needRoute.length - stillPending.length,
        ok: stillPending.isEmpty,
        note: stillPending.isEmpty
            ? null
            : '${stillPending.length} 条未确认，已停止后续下达',
      ));
      if (stillPending.isNotEmpty) return results;
    }
    // 2) 车间：自制 + 需先自制的委外。**按层级自上而下逐层下达**——同一批里
    //    父行的计划必须先落地，下一层的需求与锚点配额才是真的；一次性全发时，
    //    深层那行按父件新数量填的量会被服务端当成超出当时需求的部分，记成公共
    //    备货产出而不是本需求(用户口径 2026-09-21「改上一层，下一层要跟着改」
    //    之后，深层的量本来就常常比下达前的需求大)。
    final workshopRows = rows
        .where((row) => row.kind == _CascadeKind.workshop)
        .toList(growable: false);
    final workshopDepths = (workshopRows.map((row) => row.depth).toSet().toList()
      ..sort());
    for (final depth in workshopDepths) {
      final batch = workshopRows
          .where((row) => row.depth == depth)
          .toList(growable: false);
      final label = workshopDepths.length > 1 ? '下达车间(第 $depth 层)' : '下达车间';
      if (!await _issueCascadeWorkshopBatch(batch, label, results)) {
        return results;
      }
    }
    // 3) 采购 4) 直接外发委外：行内数量交给既有的裁决 / 分批 / 幂等链路；
    //    服务端先自动认领公共在途、再看原申请能不能就地追加，最后才新单。
    //    放在车间之后：它们的服务端余量随父件的计划一起长大，父件还没下达时
    //    按新数量填的采购量会被当成超量。直接外发的委外还要更靠后——它一下达，
    //    我方供料的那颗子件就转由委外申请负责，子件行的需求会归零。
    for (final kind in [_CascadeKind.buy, _CascadeKind.subcontractLeaf]) {
      final batch = rows
          .where((row) => row.kind == kind)
          .toList(growable: false);
      if (batch.isEmpty) continue;
      final route = kind == _CascadeKind.buy
          ? MaterialSupplyRoute.buy
          : MaterialSupplyRoute.subcontract;
      final label = kind == _CascadeKind.buy ? '下达采购' : '下达委外';
      // allowExtra：还需安排为 0 的组也能提交——填的就是追加量，服务端按超量
      // 分账（公共备货），未处理的申请就地改大、已处理的另立新单。
      final executable = {
        for (final group in _executableSupplyGroups(route, allowExtra: true))
          group.key,
      };
      final submittable = batch
          .where((row) => executable.contains(row.groupKey))
          .toList(growable: false);
      final dropped = batch
          .where((row) => !executable.contains(row.groupKey))
          .toList(growable: false);
      if (submittable.isEmpty) {
        results.add((
          label: label,
          count: 0,
          ok: false,
          note:
              '${dropped.length} 行在最新快照里已不可下达'
              '（${dropped.take(5).map((row) => row.displayName).join('、')}），'
              '本段未提交，后续下达已停止',
        ));
        return results;
      }
      final qtyLost = submittable
          .where((row) => row.actionGroupKey == null)
          .toList(growable: false);
      final view = await _notifyRoute(
        route,
        onlyGroupKeys: {for (final row in submittable) row.groupKey},
        qtyByActionGroupKey: {
          for (final row in submittable)
            if (row.actionGroupKey != null)
              row.actionGroupKey!: row.qty.text.trim(),
        },
        silent: true,
        allowExtra: true,
      );
      if (!mounted) return results;
      final notes = <String>[
        if (dropped.isNotEmpty)
          '${dropped.length} 行在最新快照里已不可下达，本次跳过'
              '（${dropped.take(5).map((row) => row.displayName).join('、')}）',
        if (view != null && qtyLost.isNotEmpty)
          '${qtyLost.length} 行没有提交单元标识，服务端按全量剩余下达，填的数量未生效'
              '（${qtyLost.take(5).map((row) => row.displayName).join('、')}）',
        if (view == null) '本段未提交，后续下达已停止',
      ];
      results.add((
        label: label,
        count: view == null ? 0 : submittable.length,
        ok: view != null && dropped.isEmpty,
        note: notes.isEmpty ? null : notes.join('；'),
      ));
      if (view == null) return results;
    }
    return results;
  }

  /// 同一层的车间行一次原子调用(服务端建锚点 / 台账 + 出计划同事务)。
  /// 已有自制锚点的行按锚点追加；其余按候选行提交。返回 false = 本段失败，
  /// 调用方停下后续所有段。
  Future<bool> _issueCascadeWorkshopBatch(
    List<_ChildCascadeRow> workshop,
    String label,
    List<_CascadeStepResult> results,
  ) async {
    if (workshop.isNotEmpty) {
      final submittable = <_ChildCascadeRow>[];
      final dropped = <_ChildCascadeRow>[];
      for (final row in workshop) {
        if (row.anchorAnalysisLineId != null) {
          final anchor = _cascadeAnchorProductOf(row);
          // 锚点还有余量按需求追加；余量为 0 但 canIssueSurplus 的按纯公共备货
          // 产出追加（填的量就是追加量）。
          if (anchor != null &&
              ((anchor.canSchedule && anchor.remainingQty > 0.0001) ||
                  (anchor.canIssueSurplus && row.enteredQty > 0.0001))) {
            submittable.add(row);
          } else {
            dropped.add(row);
          }
          continue;
        }
        // allowExtra：余量为 0 的委外件按「再追加一批公共备货产出」提交——
        // 服务端只对显式声明 publicSurplusOnly 的行放行。
        final group = _analysisGroupOf(row.groupKey);
        if (group != null &&
            _isExecutableSupplyGroup(group, row.route, allowExtra: true)) {
          submittable.add(row);
        } else {
          dropped.add(row);
        }
      }
      if (submittable.isEmpty) {
        results.add((
          label: label,
          count: 0,
          ok: false,
          note:
              '${dropped.length} 行在最新快照里已不可排产'
              '（${_names(dropped.map((row) => row.displayName))}），本段未提交',
        ));
        return false;
      }
      final ok = await _issueWorkshopPlans(
        candidateInputs: [
          for (final row in submittable)
            if (row.anchorAnalysisLineId == null)
              _BucketCandidatePlanInput(
                materialLineId: row.id,
                qty: row.enteredQty,
                departmentId: row.departmentId.value,
                workshopName: row.departmentName,
                workerId: row.workerId.value,
                // 前置自制锚点已没有剩余需求：本次全是追加的公共备货产出，
                // 必须显式声明，服务端才放行（不声明照旧 409）。
                publicSurplusOnly: () {
                  final anchor = _cascadeAnchorProductOf(row);
                  return anchor != null &&
                      !anchor.canSchedule &&
                      anchor.canIssueSurplus;
                }(),
              ),
        ],
        planDrafts: [
          for (final row in submittable)
            if (row.anchorAnalysisLineId != null)
              _BucketPlanDraft(
                analysisLineId: row.anchorAnalysisLineId!,
                qty: row.enteredQty,
                departmentId: row.departmentId.value,
                workshopName: row.departmentName,
                workerId: row.workerId.value,
                // 锚点余量为 0 的追加要明确声明为公共备货产出，服务端才放行。
                publicSurplusOnly: () {
                  final anchor = _cascadeAnchorProductOf(row);
                  return anchor != null &&
                      !anchor.canSchedule &&
                      anchor.canIssueSurplus;
                }(),
              ),
        ],
        silent: true,
      );
      if (!mounted) return false;
      results.add((
        label: label,
        count: ok ? submittable.length : 0,
        ok: ok && dropped.isEmpty,
        note: ok
            ? (dropped.isEmpty
                  ? null
                  : '${dropped.length} 行在最新快照里已不可排产，本次跳过'
                        '（${_names(dropped.map((row) => row.displayName))}）')
            : '生产计划未生成，整批已回滚',
      ));
      if (!ok) return false;
    }
    return true;
  }

  /// 本行物料在**最新快照**里的锚点产品行。车间段提交前按它复核「还能不能
  /// 追加」；行对象上的 [anchorAnalysisLineId] 只是建行时的快照。
  ProductionMaterialAnalysisProduct? _cascadeAnchorProductOf(
    _ChildCascadeRow row,
  ) {
    final analysis = _analysis;
    if (analysis == null ||
        (row.anchorAnalysisLineId == null &&
            row.preparationAnchorAnalysisLineId == null)) {
      return null;
    }
    final material = _analysisIndexes(
      analysis,
    ).groupsByLine[row.id]?.representative;
    return material == null ? null : _taskChildProductOf(material);
  }

  /// 该提交单元在最新快照里是不是「需求被转交出去了」（而不是被下单了）。
  bool _isDelegatedAwaySubmitKey(String submitKey) {
    final analysis = _analysis;
    if (analysis == null) return false;
    for (final material in analysis.materials) {
      final key = material.actionGroupKey ?? material.materialLineId;
      if (key != submitKey) continue;
      final state = material.effectiveRequirementState;
      if (state == MaterialRequirementState.delegatedToMakeChild ||
          state == MaterialRequirementState.delegatedToSubcontractPreparation) {
        return true;
      }
    }
    return false;
  }

  /// 名单统一封顶 8 条（与页面侧 `_names` 同口径）。
  String _names(Iterable<String> labels) {
    const maxShown = 8;
    final all = labels.toList(growable: false);
    return '${all.take(maxShown).join('、')}'
        '${all.length > maxShown ? ' 等 ${all.length} 项' : ''}';
  }

  _MaterialGroup? _analysisGroupOf(String groupKey) {
    final analysis = _analysis;
    if (analysis == null) return null;
    return _analysisIndexes(analysis).groupsByKey[groupKey];
  }
}
