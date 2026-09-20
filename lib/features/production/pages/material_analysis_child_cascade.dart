part of 'production_material_analysis_page.dart';

abstract class _MaterialAnalysisChildCascadeState
    extends _MaterialAnalysisMaterialTableState {
  /// 展开上限：一棵深 BOM 可以炸出几千行，本页不是主表，超过就明说被截断。
  static const int _cascadeRowLimit = 300;

  /// 深度上限：同样是保护，超过一样要明说（BOM 真有 10 层以上时用户必须知道
  /// 更深的料没列出来，否则会以为「下层就这些」）。
  static const int _cascadeDepthLimit = 10;

  /// 上一次展开是否撞上了行数 / 深度上限。页面顶部据此给出**明确**提示——
  /// 原来只在内部算了个 truncated 就丢掉，用户完全看不出下层被截断了
  /// （对应用户「很多数据都没有显示」）。
  bool _cascadeRowLimitHit = false;
  bool _cascadeDepthLimitHit = false;

  // ===== 一、按本批数量展开下层 =====

  /// 把本次下达车间的各行按 BOM 自顶向下展开成层级行。
  ///
  /// 根产品换算基本量，逐边按包装/批次计算；中间件按待制造产出驱动子树。
  /// 同提交单元汇总后扣除既有覆盖，采购策略只作用于本批净需。
  /// 纯计量函数与输入重算共用，提交仍由服务端实时复核。
  List<_ChildCascadeRow> _buildChildCascadeRows(List<_ChildCascadeSeed> seeds) {
    final analysis = _analysis;
    if (analysis == null || seeds.isEmpty) return const [];
    final nodes = _cascadeNodes(seeds, analysis);
    if (nodes.isEmpty) return const [];
    return _materializeCascadeRows(nodes, analysis, _analysisIndexes(analysis));
  }

  /// 纯展开：只产出层级节点，不建任何 TextEditingController
  /// （只会顺带更新 [_cascadeRowLimitHit] / [_cascadeDepthLimitHit] 两个截断标记）。
  ///
  /// 「进不进级联页」与「页面里长什么样」必须由**同一次展开**回答
  /// （2026-09-15）：此前入口门槛用 `_analysisMaterialHasChildren`（看的是
  /// 分析快照的全部子行，含 SHIP/REFERENCE、含失效行），建树却要跳过
  /// 非生产阶段、要按 `_bomPresentation` 的父子图走——门槛宽、建树窄，于是
  /// 「只有出货/参考子件的委外件」会被判成有子层、进来却一行都展不出来，
  /// 而判定阶段已经把几百个 controller 建了又逐个 dispose。
  List<_CascadeNode> _cascadeNodes(
    List<_ChildCascadeSeed> seeds,
    ProductionMaterialAnalysisView analysis,
  ) {
    final presentation = _bomPresentation(analysis);
    final indexes = _analysisIndexes(analysis);
    final childrenByParent =
        <String?, List<ProductionMaterialAnalysisMaterial>>{};
    for (final material in analysis.materials) {
      if (material.isRootSupply) continue;
      childrenByParent
          .putIfAbsent(
            presentation.parentIdsByMaterial[material.materialLineId],
            () => [],
          )
          .add(material);
    }
    // 兄弟行排序走与准备页主表**同一个**比较器([_compareBomSiblings]：先层级、
    // 再货品编号)。原来按 nodeKey 排，同一棵 BOM 在两个页面里行序不同，用户从
    // 准备页点进来还得重新找一遍物料(2026-09-15 用户口径「里面的顺序按照物料
    // 分析里准备下面的顺序一样」)。
    for (final children in childrenByParent.values) {
      children.sort(_compareBomSiblings);
    }
    // 2026-09-16 起勾选行之间按 BOM 祖先关系合并成树：先解析每颗种子的展开
    // 起点，按层级从浅到深处理；祖先展开时撞上「也被勾选」的后代，不再跳过，
    // 而是把它当普通下层行留在祖先树里并标记 absorbedBy，轮到它自己时不再
    // 单独成树。原来这里是「本批一起下达的行互为已安排：撞上就 continue」，
    // 每个勾选行各成一棵树、互不驱动——用户改顶层数量，其它勾选行纹丝不动。
    // 只有真被祖先展开到的才会被吸收：中间隔着采购件 (采购不下钻)、或展开
    // 被行数/层数上限截断时，后代仍各自成树，与原行为一致。
    for (final seed in seeds) {
      seed.absorbedBy = null;
    }
    final byLine = {
      for (final material in analysis.materials)
        material.materialLineId: material,
    };
    final anchors =
        <String, ({String? parentId, double divisor, int depth, int order})>{};
    final seedByAnchor = <String, _ChildCascadeSeed>{};
    for (final seed in seeds) {
      final resolved = _resolveCascadeAnchor(seed, analysis, indexes);
      if (resolved == null) continue;
      final anchorMaterial = byLine[resolved.parentId];
      anchors[resolved.key] = (
        parentId: resolved.parentId,
        divisor: resolved.divisor,
        // 层级用来决定处理顺序：祖先一定先于后代展开，后代才有机会被吸收。
        depth: anchorMaterial == null
            ? 0
            : (anchorMaterial.isRootSupply ? 0 : anchorMaterial.level),
        order: anchors.length,
      );
      seedByAnchor[resolved.key] = seed;
    }
    // 后代种子的展开起点 (物料行 id) → 种子；祖先展开撞上时据此吸收。
    final seedByAnchorMaterialId = <String, _ChildCascadeSeed>{
      for (final entry in anchors.entries)
        if (entry.value.parentId != null)
          entry.value.parentId!: seedByAnchor[entry.key]!,
    };
    final nodes = <_CascadeNode>[];
    var rowLimitHit = false;
    var depthLimitHit = false;
    var treeIndex = -1;

    void walk({
      required _ChildCascadeSeed seed,
      required String? parentId,
      required String? parentMaterialLineId,
      required double parentPerProduct,
      required double driverQty,
      required int depth,
      required String seedLabel,
      required String? scopeAnalysisLineId,
      // 祖先链（只在本条路径上去重）：原来用一个**全局** visited，同一物料
      // 只要在别处出现过，第二处连同它的整棵子树都被整段跳过，那条路径的
      // 下层需求凭空消失。真正要防的只是坏数据造成的环。
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
        // 撞上也被勾选的后代：吸收进本树 (第一次撞上的那棵树成为它的归属，
        // 同一物料再从别的路径撞上只是多一条合并路径，与普通节点同款)。
        final absorbedSeed = seedByAnchorMaterialId[child.materialLineId];
        if (absorbedSeed != null &&
            !identical(absorbedSeed, seed) &&
            absorbedSeed.absorbedBy == null) {
          absorbedSeed.absorbedBy = seed;
        }
        final required = _cascadeRequiredQty(
          child,
          driverQty,
          parentPerProduct,
        );
        final grossNeed = required ?? child.requiredQty;
        nodes.add((
          material: child,
          product: null,
          depth: depth,
          treeIndex: treeIndex,
          seedLabel: seedLabel,
          parentMaterialLineId: parentMaterialLineId,
          parentPerProduct: parentPerProduct,
          grossNeed: grossNeed,
          scaled: required != null,
          isSeed: false,
          seed: null,
          absorbedSeed: absorbedSeed != null && !identical(absorbedSeed, seed)
              ? absorbedSeed
              : null,
        ));
        final group = indexes.groupsByLine[child.materialLineId];
        final route = group == null ? null : _draftRoute(group);
        // 这里问的是「BOM 上还有没有下层要一起办」，**不是**「父件走哪条通道」：
        // V581 的单一子件委外虽然走 notify，那颗子件仍要我方备出来（采购或自制），
        // 必须继续下钻，否则下达完委外没人给仓库备料。
        final descend =
            route == MaterialSupplyRoute.make ||
            (route == MaterialSupplyRoute.subcontract &&
                _hasProductionBomChildren(child, analysis));
        if (!descend) continue;
        walk(
          seed: seed,
          parentId: child.materialLineId,
          parentMaterialLineId: child.materialLineId,
          parentPerProduct: child.perProductQty,
          driverQty: _cascadeManufacturingQty(child, grossNeed),
          depth: depth + 1,
          seedLabel: seedLabel,
          scopeAnalysisLineId: scopeAnalysisLineId,
          ancestors: {...ancestors, child.materialLineId},
        );
      }
    }

    // 祖先先展开、后代后展开 (同层按勾选顺序)，后代才有机会被祖先吸收。
    final ordered = anchors.entries.toList(growable: false)
      ..sort((left, right) {
        final byDepth = left.value.depth.compareTo(right.value.depth);
        return byDepth != 0
            ? byDepth
            : left.value.order.compareTo(right.value.order);
      });
    for (final entry in ordered) {
      final seed = seedByAnchor[entry.key]!;
      // 已被祖先那棵树吸收：它在祖先树里就是一行普通下层行，不再单独成树。
      if (!seed.isTop) continue;
      final before = nodes.length;
      treeIndex++;
      // 树顶先占一行：本次要下达的那个件本身（用户口径「最上面就是点击下达
      // 车间的，下面是子层级、孙层级」）。数量就是下层的驱动量，可直接改。
      //
      // 2026-09-14：快照没有 ROOT_SUPPLY 行时（顶层产品的旧载荷）原来
      // 整行不生成，「最上面是被下达的那个件」当场不成立，而且下面的
      // depth-1 行会在树结构推导里去认**上一棵树**的树顶当父亲。改为回退到
      // 产品行本身当树顶——它只做身份与驱动量，不参与提交。
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
        parentMaterialLineId: null,
        parentPerProduct: entry.value.divisor,
        grossNeed: seed.batchQty,
        scaled: true,
        isSeed: true,
        seed: seed,
        absorbedSeed: null,
      ));
      walk(
        seed: seed,
        parentId: entry.value.parentId,
        // 子行要挂到**树顶行的 row.id** 上，不是可能为 null 的 materialLineId：
        // 没有 ROOT_SUPPLY 行的顶层产品（子件任务、旧载荷）树顶 id 是
        // `PRODUCT|<analysisLineId>`，原来这里传 null，重算时 depth-1 行找不到
        // 驱动量而整段跳过——页面顶上承诺的「改父件数量，下层一起变」对这类
        // 分析静默失效（2026-09-15）。
        parentMaterialLineId:
            anchorMaterial?.materialLineId ??
            'PRODUCT|${seedProduct?.analysisLineId ?? ''}',
        parentPerProduct: entry.value.divisor,
        driverQty: materialCascadeBaseOutputQty(
          seed.batchQty,
          seed.outputUnitRate,
        ),
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

  /// 种子 → 展开起点。返回子树父节点（null = 顶层产品且无根供给行）与
  /// 旧线性载荷的单位耗用除数；正式计量读取直属 BOM 边。
  ({String key, String? parentId, double divisor})? _resolveCascadeAnchor(
    _ChildCascadeSeed seed,
    ProductionMaterialAnalysisView analysis,
    _MaterialAnalysisIndexes indexes,
  ) {
    final materialLineId = seed.materialLineId;
    if (materialLineId != null) {
      final anchor = indexes.groupsByLine[materialLineId]?.representative;
      if (anchor == null) return null;
      return (
        key: 'MATERIAL|$materialLineId',
        parentId: anchor.materialLineId,
        divisor: anchor.perProductQty,
      );
    }
    final analysisLineId = seed.analysisLineId;
    final product = analysisLineId == null
        ? null
        : indexes.productsById[analysisLineId];
    if (product == null) return null;
    if (_isEmbeddedMakeChildProduct(product)) {
      // 锚点子件不展开自己的 BOM（ADR-071 §四）：它的料仍留在原树的来源
      // 节点下，展开起点必须回到那个节点。
      final origin = indexes.materialsByAnchorProduct[product.analysisLineId];
      if (origin == null) return null;
      return (
        key: 'PRODUCT|$analysisLineId',
        parentId: origin.materialLineId,
        divisor: origin.perProductQty,
      );
    }
    final root = _rootSupplyMaterialOf(product);
    return (
      key: 'PRODUCT|$analysisLineId',
      parentId: root?.materialLineId,
      divisor: seed.outputUnitRate,
    );
  }

  /// 展开结果 → 可提交行：同一提交单元（actionGroupKey）合并到第一处，
  /// 其余保留为层级上下文；数量按服务端口径算建议值并标注阻断原因。
  List<_ChildCascadeRow> _materializeCascadeRows(
    List<_CascadeNode> nodes,
    ProductionMaterialAnalysisView analysis,
    _MaterialAnalysisIndexes indexes,
  ) {
    final pathsBySubmitKey =
        <String, List<ProductionMaterialAnalysisMaterial>>{};
    for (final material in analysis.materials) {
      // 提交单元的成员集合必须与服务端 `selectedGroups` 同口径：只收
      // actionable / 根供给 / 优先补自制的行。原来这里收全量，失效路径的
      // 在途会照扣、需求却不计入，同一个提交单元在本页算出来的「还可下达」
      // 比服务端小——少下单（2026-09-15，与 `_supplyQuantityEntry` 对齐）。
      if (!material.actionable &&
          !material.isRootSupply &&
          !material.hasPriorityMakeSupplement) {
        continue;
      }
      final key = material.actionGroupKey ?? material.materialLineId;
      pathsBySubmitKey.putIfAbsent(key, () => []).add(material);
    }
    final ownerIndex = <String, int>{};
    final gross = <String, double>{};
    final snapshot = <String, double>{};
    final mergedCount = <String, int>{};
    for (var index = 0; index < nodes.length; index++) {
      // 树顶只读行不参与提交单元合并：它是刚下达的件本身，不在这里下单。
      final material = nodes[index].material;
      if (nodes[index].isSeed || material == null) continue;
      final key = material.actionGroupKey ?? material.materialLineId;
      ownerIndex.putIfAbsent(key, () => index);
      gross[key] = (gross[key] ?? 0) + nodes[index].grossNeed;
      snapshot[key] = (snapshot[key] ?? 0) + material.requiredQty;
      mergedCount[key] = (mergedCount[key] ?? 0) + 1;
    }
    final rows = <_ChildCascadeRow>[];
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      final material = node.material;
      // 无物料行的树顶（顶层产品旧载荷）：只作层级与驱动量，不参与任何提交。
      if (material == null) {
        rows.add(_seedOnlyRow(node));
        continue;
      }
      final submitKey = material.actionGroupKey ?? material.materialLineId;
      final group = indexes.groupsByLine[material.materialLineId];
      final ownsInput = ownerIndex[submitKey] == index;
      final route = group == null
          ? MaterialSupplyRoute.subcontract
          : _draftRoute(group);
      final kind = _cascadeKindOf(material, route, analysis);
      final submitGroup = group == null
          ? null
          : _MaterialGroup(
              key: group.key,
              paths: pathsBySubmitKey[submitKey] ?? group.paths,
            );
      // 已建自制子件任务 / 委外前置自制任务的行 (2026-09-16)：可下达余量改按
      // 那条锚点产品行的剩余可排量算，本页按锚点追加下达 (planDrafts)，不再
      // 一律「本页不重复下达」。优先补自制的行仍按服务端补量口径走候选通道。
      final anchor =
          kind == _CascadeKind.workshop && !material.hasPriorityMakeSupplement
          ? _taskChildProductOf(material)
          : null;
      final residual = anchor != null
          ? (anchor.canSchedule ? anchor.remainingQty : 0.0)
          : submitGroup == null
          ? 0.0
          : _residualSubmitQty(submitGroup, route);
      final grossNeed = ownsInput ? (gross[submitKey] ?? 0) : node.grossNeed;
      // 原位需求保留真实覆盖；只有历史整块转交导致物料需求归零时，才回退
      // 锚点总需求。不能使用 remaining 作需求基准，否则已排产份额会再做一遍。
      final snapshotNeed =
          anchor != null &&
              material.requiredQty <= 0 &&
              material.requirementState ==
                  MaterialRequirementState.delegatedToMakeChild
          ? anchor.requestedQty
          : ownsInput
          ? (snapshot[submitKey] ?? 0)
          : material.requiredQty;
      final overspill = grossNeed - snapshotNeed > 0.0001
          ? grossNeed - snapshotNeed
          : 0.0;
      final allowOver =
          kind == _CascadeKind.workshop ||
          (_canOverSupply &&
              (kind == _CascadeKind.buy ||
                  kind == _CascadeKind.subcontractLeaf));
      final overCapped = overspill > 0.0001 && !allowOver;
      // 先扣除已有覆盖，只为本批尚未覆盖的那一份创建新下达。
      final minQty = materialCascadeNetQty(
        grossNeed: grossNeed,
        snapshotNeed: snapshotNeed,
        residual: residual,
        allowOver: allowOver,
      );
      // 采购行的预填值要和采购桶逐字同源：货品维护了最小起订量 / 订货倍数时
      // 按它向上抬（富余归公共备货，需 over_supply；没权限就不抬）。
      // 这是**软约束**——抬出来的部分不进下限，用户可以改回 minQty
      // （2026-09-15：原来 minQty 直接等于抬过量的 suggested，把软约束变成
      // 硬下限，430 的真实需求被一张 500 的起订量拦死）。
      final suggested = submitGroup == null
          ? minQty
          : _submitQtyWithOrderPolicy(submitGroup, route, minQty);
      final row =
          _ChildCascadeRow(
              material: material,
              product: null,
              groupKey: group?.key ?? 'NONE|${material.materialLineId}',
              submitKey: submitKey,
              depth: node.depth,
              treeIndex: node.treeIndex,
              seedLabel: node.seedLabel,
              route: route,
              kind: kind,
              parentMaterialLineId: node.parentMaterialLineId,
              parentPerProduct: node.parentPerProduct,
              grossNeed: grossNeed,
              pathGrossNeed: node.grossNeed,
              snapshotNeed: snapshotNeed,
              residual: residual,
              overspill: overspill,
              minQty: minQty,
              suggested: suggested,
              scaled: node.scaled,
              ownsInput: ownsInput,
              mergedPathCount: ownsInput ? (mergedCount[submitKey] ?? 1) : 1,
              overCapped: overCapped,
              isSeed: node.isSeed,
              seed: node.seed,
              anchorAnalysisLineId: anchor?.analysisLineId,
              blockedReason: ownsInput && !node.isSeed
                  ? (!node.scaled &&
                            material.consumptionBasis != null &&
                            material.consumptionBasis != 'PER_UNIT'
                        ? '包装或批次用量不完整，请刷新物料分析后重试'
                        : _cascadeBlockedReason(
                            material,
                            group,
                            route,
                            kind,
                            anchor,
                          ))
                  : null,
            )
            ..seedUnitName = node.seed?.unitName
            ..stats = _cascadeStats(material, ownsInput ? submitGroup : null);
      // 被祖先吸收的勾选行：分桶页填的车间/负责人带过来；数量默认跟祖先算
      // (这正是用户要的「改顶层、其它一起变」)，只有分桶页填得比算出来的还多
      // (明确想多做) 才当手工值保留——可以多不能少，且手工值不被祖先重算覆盖。
      final absorbed = node.absorbedSeed;
      if (absorbed != null && ownsInput) {
        if (absorbed.departmentId?.isNotEmpty == true) {
          row.departmentId.value = absorbed.departmentId;
          row.departmentName = absorbed.departmentName;
          row.workshopAutofilled = absorbed.workshopAutofilled;
        }
        if (absorbed.workerId?.isNotEmpty == true) {
          row.workerId.value = absorbed.workerId;
          row.workerName = absorbed.workerName;
          row.workerAutofilled = absorbed.workerAutofilled;
        }
        if (absorbed.quantityExplicit &&
            row.blockedReason == null &&
            absorbed.batchQty > row.suggested + 0.0001) {
          row.qty.text = _bucketQtyText(absorbed.batchQty);
          row.qtyTouched = true;
          row.manualDriverQty = absorbed.batchQty;
        }
      }
      rows.add(row);
    }
    return rows;
  }

  double? _cascadeRequiredQty(
    ProductionMaterialAnalysisMaterial material,
    double parentOutputQty,
    double legacyParentPerProduct,
  ) => materialCascadeRequiredQty(
    parentOutputQty: parentOutputQty,
    bomQty: material.bomQty,
    consumptionBasis: material.consumptionBasis,
    basisOutputQty: material.basisOutputQty,
    allowPartialPackage: material.allowPartialPackage,
    legacyPerProductQty: material.perProductQty,
    legacyParentPerProductQty: legacyParentPerProduct,
  );

  double _cascadeManufacturingQty(
    ProductionMaterialAnalysisMaterial material,
    double grossNeed,
  ) => materialCascadeManufacturingQty(
    grossNeed: grossNeed,
    allocatedAvailableQty: material.allocatedAvailableQty,
    externalFutureCoverageQty: material.externalFutureCoverageQty,
    internalCommittedOutputQty: material.internalCommittedOutputQty,
  );

  /// 本行物料在**最新快照**里的锚点产品行 (自制子件任务 / 委外前置自制任务)。
  /// 车间段提交前按它复核「还能不能追加」；行对象上的 [anchorAnalysisLineId]
  /// 只是建行时的快照。
  ProductionMaterialAnalysisProduct? _cascadeAnchorProductOf(
    _ChildCascadeRow row,
  ) {
    final analysis = _analysis;
    if (analysis == null || row.anchorAnalysisLineId == null) return null;
    final material = _analysisIndexes(
      analysis,
    ).groupsByLine[row.id]?.representative;
    return material == null ? null : _taskChildProductOf(material);
  }

  /// 库存/供给口径（与准备页主表逐列同义，见 _ChildCascadeRow.stats）。
  /// [group] 非空 = 本行持有输入框，按整个提交单元汇总；null = 只看本路径。
  ({
    double? available,
    double? shortage,
    double? inbound,
    double? sharedFuturePending,
    double? additionalRecommended,
    String? expectedReadyDate,
  })
  _cascadeStats(
    ProductionMaterialAnalysisMaterial material,
    _MaterialGroup? group,
  ) {
    final paths = group?.paths ?? [material];
    double? uniform(double? Function(ProductionMaterialAnalysisMaterial) pick) {
      final values = paths.map(pick).toSet();
      return values.length == 1 ? values.single : null;
    }

    return (
      available: material.availableQty,
      shortage: paths.fold<double>(0, (sum, path) => sum + path.shortageQty),
      inbound: uniform((path) => path.inboundQty),
      sharedFuturePending: uniform((path) => path.sharedFuturePendingQty),
      additionalRecommended: paths.fold<double>(
        0,
        (sum, path) => sum + path.additionalSupplyRecommendedQty,
      ),
      expectedReadyDate: material.expectedReadyDate,
    );
  }

  /// 没有物料行的树顶：只承担「最上面那一行 + 驱动量」，不可勾选、不可提交。
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
    parentMaterialLineId: null,
    parentPerProduct: node.parentPerProduct,
    grossNeed: node.grossNeed,
    pathGrossNeed: node.grossNeed,
    snapshotNeed: node.grossNeed,
    residual: 0,
    overspill: 0,
    minQty: 0,
    suggested: 0,
    scaled: true,
    ownsInput: false,
    mergedPathCount: 1,
    blockedReason: null,
    overCapped: false,
    isSeed: true,
    seed: node.seed,
  )..seedUnitName = node.seed?.unitName;

  _CascadeKind _cascadeKindOf(
    ProductionMaterialAnalysisMaterial material,
    MaterialSupplyRoute route,
    ProductionMaterialAnalysisView analysis,
  ) => switch (route) {
    MaterialSupplyRoute.buy => _CascadeKind.buy,
    MaterialSupplyRoute.make => _CascadeKind.workshop,
    // V581：「只有一个叶子子件」的委外件虽然有下层，却不进车间——仓库直接把
    // 那个子件发给委外商，所以父件段走 notify（与无子层同一条通道）。判定用
    // _subcontractNeedsPreparation（服务端给的形态），不是 BOM 形状。
    MaterialSupplyRoute.subcontract =>
      _subcontractNeedsPreparation(material, analysis)
          ? _CascadeKind.workshop
          : _CascadeKind.subcontractLeaf,
  };

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
    if (kind == _CascadeKind.workshop && !_canGenerate) {
      return '没有生成生产计划权限';
    }
    // 已经建过自制子件任务 / 前置自制任务的行 (2026-09-16 改口径)：不再一律
    // 「本页不重复下达」，而是按那条锚点产品行追加下达——锚点还有剩余可排量
    // 就能下 (超出部分按 V577 记公共备货)；剩余为 0 才阻断，因为服务端的
    // 排产资格闸 (canSchedule) 早于数量校验，硬提交只会 409 把整条编排卡在
    // 车间段。锚点解析不到但快照说已有生产计划的，按刷新处理。
    if (kind == _CascadeKind.workshop && !material.hasPriorityMakeSupplement) {
      if (anchor != null) {
        if (!anchor.canSchedule) {
          return anchor.scheduleBlockedReason ?? '本行的自制任务当前不可排产，请到「下达车间」核对';
        }
        if (anchor.remainingQty <= 0.0001) {
          return '本行的自制任务需求已全部下达 (剩余 0)，多做的量无法在本页追加，请另立需求';
        }
      } else if (_hasIssuedMakeOwnership(material)) {
        return '本行已有下达记录但解析不到对应的子件任务，请刷新物料分析后到「下达车间」核对';
      }
    }
    if (kind != _CascadeKind.workshop && !_canNotify) {
      return '没有下达采购/委外权限';
    }
    if (kind != _CascadeKind.workshop &&
        _routeBlockedBySafetyGap(group, route)) {
      return '存在公共安全补库缺口，仅采购路线可下达';
    }
    return null;
  }

  // ===== 二、入口：先弹窗（弹窗前置），一键下单里再提交父件 =====

  /// 进不进「父件 + 下层一起办」整页，以及**为什么**。
  ///
  /// 2026-09-15 起这是唯一的进页判定：门槛与建树共用同一次展开
  /// （[_cascadeNodes]），不再由调用点各自用 `_analysisMaterialHasChildren`
  /// 猜一遍；并且**每一条不进页的路径都必须给出非空 reason**——原来
  /// 「展开不出下层」那一支返回 null，用户点了「下达委外」既不进页也没有
  /// 任何一句话，与 ADR-081 §8.5「不再静默跳过」直接相违。
  /// 「有没有被下单」由服务端口径的可下达余量决定，不靠界面猜。
  @override
  ({List<_ChildCascadeRow> rows, String? note}) _pendingChildCascadeRows(
    List<_ChildCascadeSeed> seeds, {
    bool keepUnselectable = false,
  }) {
    const none = (rows: <_ChildCascadeRow>[], note: null);
    if (!mounted || seeds.isEmpty) return none;
    final analysis = _analysis;
    if (analysis == null) return none;
    if (!_canNotify && !_canGenerate) {
      return (
        rows: const <_ChildCascadeRow>[],
        note: '没有下达采购/委外或生成生产计划权限，下层物料本次未办理',
      );
    }
    // 第一关：纯展开（不建任何输入控件）。展不出非树顶节点就说明「BOM 上
    // 没有需要一起办的下层」——含「子件全是出货/参考阶段」「子件已被本批
    // 其它种子接管」这两种真实情形，都要如实说，不能静默。
    final nodes = _cascadeNodes(seeds, analysis);
    final hasChildNode = nodes.any((node) => !node.isSeed);
    if (!hasChildNode) {
      return (
        rows: const <_ChildCascadeRow>[],
        note: _cascadeRowLimitHit || _cascadeDepthLimitHit
            ? '下层结构过大（超过 $_cascadeRowLimit 行或 $_cascadeDepthLimit 层），'
                  '本次未展开下层，请到物料分析主表逐层办理'
            : '已检查下层：BOM 上没有需要本次一起办的生产性子件'
                  '（出货/参考阶段的子件不形成备料需求），本次只下达所选行',
      );
    }
    final rows = _materializeCascadeRows(
      nodes,
      analysis,
      _analysisIndexes(analysis),
    );
    if (rows.any((row) => row.selectable)) return (rows: rows, note: null);
    final children = rows.where((row) => !row.isSeed && row.ownsInput).toList();
    final blocked = children
        .where((row) => row.blockedReason != null)
        .toList(growable: false);
    // 树顶种子本身要在页面里填车间/负责人 (委外桶进来的 issue-plans 行) 时，
    // 即便下层一行都不能勾也要进页——父件段没有车间就提交不了。
    if (keepUnselectable) {
      return (
        rows: rows,
        note: children.isEmpty
            ? '下层都已由本批其它行接管或已下过单，本次只需为父件填车间/负责人'
            : '下层 ${children.length} 行当前无需/不能在本页下单，本次只需为父件填车间/负责人',
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
      );
    }
    return (rows: const <_ChildCascadeRow>[], note: '已检查下层：都已下过单，本次只下达所选行');
  }

  /// 进入「父件 + 下层一起下单」整页（2026-09-14 修订：**不再弹窗**——用户口径
  /// 「不要弹窗了直接去新的页面，弹窗看的东西太少」；提交前置——先让用户在
  /// 页面里看清下层并核对数量，点「一键下单」才按序提交父件与下层，不再先把
  /// 父件落库再补问）。[parentAction] = 父件提交段（null = 重试模式，父件已
  /// 提交过）。返回 true = 全部段成功。
  @override
  Future<bool> _showChildCascadeDialog({
    required List<_ChildCascadeSeed> seeds,
    required List<_ChildCascadeRow> initialRows,
    Future<bool> Function()? parentAction,
  }) async {
    if (!mounted) return false;
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _ChildCascadePage(
          host: this,
          seeds: seeds,
          initialRows: initialRows,
          parentAction: parentAction,
        ),
      ),
    );
    return done == true;
  }

  // ===== 三、一键下单：父件 → 路线确认 → 并入申请 → 采购 → 委外 → 车间 =====

  /// 按路线分流依次下达。**不是一个事务**：逐段调用既有的下达链路，
  /// 每段自带幂等键、CAS 与 409 恢复；任一段失败即停下并如实回报，
  /// 已成功的段保留在服务端（重试按幂等键回放，不会重复建单）。
  ///
  /// [parentAction] = 父件提交段（弹窗前置模式）：先提交用户在分桶页填好的
  /// 父件本身，成功后经 [rebuildAfterParent] 按最新快照重建下层行并继承已填
  /// 数量——父件提交会让分析快照整体换一份（锚点/缺口/在途重算），提交前
  /// 抓到的行对象立刻过期；被父件顺带办妥的行（如委外前置自制任务接手的
  /// 子件）会自然变成「已下达」，从后续段里退出并如实回报。
  Future<List<_CascadeStepResult>> _executeChildCascade(
    List<_ChildCascadeRow> rows, {
    required List<_ChildCascadeSeed> seeds,
    Future<bool> Function()? parentAction,
    List<_ChildCascadeRow> Function()? rebuildAfterParent,
    int parentCount = 1,
  }) async {
    final results = <_CascadeStepResult>[];
    if (rows.isEmpty) return results;
    // 0) 父件段：先把本次下达的父件提交了，下层才有「按本批数量」的权威驱动量。
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
      // 0.5) 走 notify 整量接管的委外种子：服务端在同一事务里建了「前置自制
      // 任务」产品行，但不出计划、不写路线，需要再排一次产。2026-09-16 起这
      // 只剩顶层供给行与无生成计划权限两种；非根的有子层委外件已在父件段用
      // issue-plans 一步建好台账 + 锚点 + 计划，不进这一段。
      final premakeResult = await _issuePremakeAnchors(seeds);
      if (!mounted) return results;
      if (premakeResult != null) {
        results.add(premakeResult);
        if (!premakeResult.ok) return results;
      }
      if (rebuildAfterParent != null) {
        final before = {for (final row in rows) row.submitKey: row.displayName};
        rows = rebuildAfterParent();
        final afterKeys = {for (final row in rows) row.submitKey};
        // 掉出集合的行分两类，绝不能都算成「已办妥」：
        // 真正被父件顺带办掉的（快照里已无可下达余量）才是成功；
        // 因为路线 / 权限 / 资格被挡住而退出的是**没办成**，必须点名，
        // 否则整页报全绿而那几样料根本没人下单。
        final dropped = before.keys
            .where((key) => !afterKeys.contains(key))
            .toList(growable: false);
        if (dropped.isNotEmpty) {
          final fresh = _buildChildCascadeRows(seeds);
          final blocked = <String>[];
          // 「需求被转交出去」≠「已经下单了」：委外前置自制一建，原节点下层的
          // 需求会整块搬到新的 SUBCONTRACT_MAKE 子树名下（requirementState 变成
          // DELEGATED_*），这些料一件都还没下单。原来只要行从集合里消失就计入
          // 「已随父件下达办妥」，把「换了个负责人」误报成「已办妥」。
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
    // 2) 并入已有申请：基础需求已生成采购申请且尚未分解出订货单的行，直接把
    //    追加量写进同一张申请（V477 sanctioned 入口，权限与守卫由该端点自裁）。
    final adjustBatch = rows
        .where((row) => row.adjustIntoRequest)
        .toList(growable: false);
    if (adjustBatch.isNotEmpty) {
      // 逐行串行、失败即停，且**已改的不会回滚**——所以失败时必须把「哪几张
      // 申请已经改大了」逐张写清楚，否则重试时用户无从判断会不会加两遍。
      final done = <String>[];
      String? failNote;
      for (final row in adjustBatch) {
        final link = row.supplyLink!;
        final name = row.displayName;
        try {
          await ref
              .read(purchaseRepositoryProvider(PurchaseDocType.request))
              .adjustRequestItemQty(
                requestId: link.documentId,
                itemId: link.documentItemId!,
                qty: link.itemQty + row.enteredQty,
              );
          done.add(
            '${link.documentNo}「$name」→ ${_qty(link.itemQty + row.enteredQty)}',
          );
        } catch (error) {
          failNote =
              '「$name」'
              '${productionErrorMessage(error, fallback: '申请数量修改失败')}'
              '${done.isEmpty ? '；本段没有任何申请被改动' : '；已改大：${done.join('、')}——重试前请先核对这几张，避免重复加量'}';
          break;
        }
      }
      results.add((
        label: '并入已有采购申请',
        count: done.length,
        ok: failNote == null,
        note: failNote ?? (done.isEmpty ? null : done.join('、')),
      ));
      if (failNote != null) return results;
    }
    // 3) 采购 4) 无子层委外：行内数量交给既有的裁决/分批/幂等链路。
    //    「已分解出订货单」的追加行也走这里（notify 超量通道另立追加申请）。
    for (final kind in [_CascadeKind.buy, _CascadeKind.subcontractLeaf]) {
      final batch = rows
          .where((row) => row.kind == kind && !row.adjustIntoRequest)
          .toList(growable: false);
      if (batch.isEmpty) continue;
      final route = kind == _CascadeKind.buy
          ? MaterialSupplyRoute.buy
          : MaterialSupplyRoute.subcontract;
      final label = kind == _CascadeKind.buy ? '下达采购' : '下达委外';
      // `_notifyRoute` 只认「当前可执行」的提交单元，勾了但已不可执行的行会被
      // 静默丢掉；而结果原来一律按 `batch.length` 上报，于是「下少了却报下达
      // 采购 5 行」。这里先按同一口径把差集算出来，如实点名。
      final executable = {
        for (final group in _executableSupplyGroups(route)) group.key,
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
      // 行内数量只能按 actionGroupKey 传；没有这个键的行在服务端会回落成
      // 「全量剩余」，用户填的数字被无声换掉——这种行必须当面说明。
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
    // 5) 车间：自制 + 有子层委外一次原子调用（服务端建锚点 + 出计划同事务）。
    final workshop = rows
        .where((row) => row.kind == _CascadeKind.workshop)
        .toList(growable: false);
    if (workshop.isNotEmpty) {
      // 与采购 / 委外两段同一条口径：先按最新快照算出本段真正还能提交的行，
      // 被剔除的点名。原来车间段把勾选行原样送进 issue-plans，只要其中一行
      // 已经不可排产，服务端 409 会把整批回滚，而结果里还写着「下达车间 N 行」
      //（2026-09-15）。
      final submittable = <_ChildCascadeRow>[];
      final dropped = <_ChildCascadeRow>[];
      for (final row in workshop) {
        // 已有锚点任务的行按锚点产品行追加：资格看锚点 (canSchedule + 剩余)，
        // 不看分析侧提交单元——后者对已建任务的 MAKE 组恒为不可执行。
        if (row.anchorAnalysisLineId != null) {
          final anchor = _cascadeAnchorProductOf(row);
          if (anchor != null &&
              anchor.canSchedule &&
              anchor.remainingQty > 0.0001) {
            submittable.add(row);
          } else {
            dropped.add(row);
          }
          continue;
        }
        final group = _analysisGroupOf(row.groupKey);
        if (group != null && _isExecutableSupplyGroup(group, row.route)) {
          submittable.add(row);
        } else {
          dropped.add(row);
        }
      }
      if (submittable.isEmpty) {
        results.add((
          label: '下达车间',
          count: 0,
          ok: false,
          note:
              '${dropped.length} 行在最新快照里已不可排产'
              '（${_names(dropped.map((row) => row.displayName))}），本段未提交',
        ));
        return results;
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
              ),
        ],
        silent: true,
      );
      if (!mounted) return results;
      results.add((
        label: '下达车间',
        count: ok ? submittable.length : 0,
        ok: ok && dropped.isEmpty,
        note: ok
            ? (dropped.isEmpty
                  ? null
                  : '${dropped.length} 行在最新快照里已不可排产，本次跳过'
                        '（${_names(dropped.map((row) => row.displayName))}）')
            : '生产计划未生成，整批已回滚',
      ));
    }
    return results;
  }

  /// 该提交单元在最新快照里是不是「需求被转交出去了」（而不是被下单了）。
  ///
  /// 转交有两种：自制子任务接管（DELEGATED_TO_MAKE_CHILD）与委外前置自制
  /// 接管（DELEGATED_TO_SUBCONTRACT_PREPARATION）。两种都只是换了负责人，
  /// 料一件没下——编排的结果汇报必须把它与「已随父件下达办妥」区分开。
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

  /// 把父件段刚建出来的「委外前置自制任务」一并下达车间。
  ///
  /// 只有走 notify 整量接管的委外种子 (`subcontractMakeFirst`) 需要这一段——
  /// 2026-09-16 起那只剩两种：**顶层供给行** (服务端 `candidateRoutesByMaterialLine`
  /// 明确排除 ROOT_SUPPLY，根件不能当 issue-plans 候选，只能 notify 建台账再按
  /// 锚点排产)，以及**没有生成生产计划权限**的账号。非根的有子层委外件已改走
  /// issue-plans 的 ARRANGE 段，台账 + 锚点 + 计划同一事务建好，不进这里。
  ///
  /// 返回 null = 本批没有这类种子。
  Future<_CascadeStepResult?> _issuePremakeAnchors(
    List<_ChildCascadeSeed> seeds,
  ) async {
    final pending = seeds
        .where(
          (seed) =>
              seed.isTop &&
              seed.channel == _CascadeParentChannel.subcontractMakeFirst,
        )
        .toList(growable: false);
    if (pending.isEmpty) return null;
    final analysis = _analysis;
    if (analysis == null) return null;
    // 按最新快照解析：父件提交后快照整体换了一份，进页面时抓的对象已过期。
    final drafts = <_BucketPlanDraft>[];
    final unresolved = <String>[];
    for (final seed in pending) {
      final materialLineId = seed.materialLineId;
      final material = materialLineId == null
          ? null
          : analysis.materials
                .where((item) => item.materialLineId == materialLineId)
                .firstOrNull;
      final child = material == null
          ? null
          : _subcontractMakeChildProductOf(material);
      if (child == null) {
        unresolved.add(seed.label);
        continue;
      }
      // 已经排过产的锚点不再重复下达（重试 / 幂等回放时会走到这里）。
      if (_productExecutionStage(child) != null) continue;
      final remaining = child.remainingQty;
      drafts.add(
        _BucketPlanDraft(
          analysisLineId: child.analysisLineId,
          qty: remaining > 0 ? remaining : seed.batchQty,
          departmentId: seed.departmentId,
          workshopName: seed.departmentName,
          workerId: seed.workerId,
        ),
      );
    }
    if (drafts.isEmpty) {
      if (unresolved.isEmpty) return null;
      return (
        label: '前置自制任务下达车间',
        count: 0,
        ok: true,
        note:
            '${_names(unresolved)} 的前置自制任务未能在最新快照里解析出来，'
            '请刷新物料分析后到「下达车间」确认',
      );
    }
    if (!_canGenerate) {
      return (
        label: '前置自制任务下达车间',
        count: 0,
        ok: true,
        note:
            '已创建 ${drafts.length} 个前置自制任务，但当前账号没有生成生产计划权限，'
            '尚未下达车间——请让有该权限的人到「下达车间」排产',
      );
    }
    final ok = await _issueWorkshopPlans(planDrafts: drafts, silent: true);
    if (!mounted) {
      return (label: '前置自制任务下达车间', count: 0, ok: false, note: '页面已关闭');
    }
    return (
      label: '前置自制任务下达车间',
      count: ok ? drafts.length : 0,
      ok: ok,
      note: ok
          ? (unresolved.isEmpty
                ? null
                : '${_names(unresolved)} 未能解析出前置自制任务，请刷新后核对')
          : '前置自制任务已创建，但排产未成功；委外那一步已完成，'
                '可到「下达车间」对这些任务单独排产',
    );
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
