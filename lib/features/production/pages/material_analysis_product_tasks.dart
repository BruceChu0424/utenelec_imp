part of 'production_material_analysis_page.dart';

abstract class _MaterialAnalysisProductTasksState
    extends _MaterialAnalysisPlanActionsState {
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

  bool _hasPlanExecutionFacts(ProductionMaterialAnalysisProduct product) =>
      product.planExecutionStatus?.trim().isNotEmpty == true ||
      product.latestPlanId?.trim().isNotEmpty == true ||
      product.latestPlanNo?.trim().isNotEmpty == true ||
      product.planExecutionPlannedQty != null ||
      product.planExecutionInboundQty != null ||
      product.planExecutionProgressRatio != null ||
      product.submittedQty > 0 ||
      product.approvedQty > 0;

  bool _productExecutionCompleted(ProductionMaterialAnalysisProduct product) =>
      _productExecutionStage(product)?.status == 'COMPLETED';

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

  /// MAKE 路线已确认但尚未创建子件任务的候选卡投影：下层未齐 → 暂不可安排
  /// 待办卡（只读，继续处理下方 BOM）；下层齐套 → 可安排区可勾选，批量
  /// 「创建子件任务」后留在本页填数量。已创建（存在活动 MAKE 通知或真实
  /// child）的节点不再出现在这里，由真实 MAKE_COMPONENT 产品卡接管。
  ///
  /// V458/ADR-064 两段式：**有子层级的委外件确认「采用委外」后与自制完全
  /// 同构**——同样进入候选卡（下层未齐=暂不可安排、齐套=可安排勾选提交，
  /// 服务端分流建 SUBCONTRACT_MAKE 任务行），不再要求下达瞬间立即建任务。
  List<_PendingMakeCandidate> _pendingMakeCandidates(
    ProductionMaterialAnalysisView analysis,
  ) {
    final indexes = _analysisIndexes(analysis);
    final result = <_PendingMakeCandidate>[];
    for (final material in analysis.materials) {
      if (material.shortageQty <= 0) continue;
      final route = material.confirmedRoute;
      final isMakeCandidate = route == MaterialSupplyRoute.make;
      final isSubcontractCandidate =
          route == MaterialSupplyRoute.subcontract &&
          _hasProductionBomChildren(material, analysis);
      if (!isMakeCandidate && !isSubcontractCandidate) {
        continue;
      }
      final hasActiveTask = material.notifiedTargets.any(
        (target) =>
            target.target == route &&
            target.status?.toUpperCase() != 'CANCELLED',
      );
      final existingChild = isMakeCandidate
          ? _makeChildProductOf(material)
          : _subcontractMakeChildProductOf(material);
      if (hasActiveTask || existingChild != null) continue;

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
          route: route!,
          parentLabel: parentLabel,
          shortageKindCount: kindCount,
          shortagePathCount: directShortages.length,
          unconfirmedPathCount: unconfirmedCount,
        ),
      );
    }
    result.sort((left, right) {
      final readiness = (_canArrangePendingMakeCandidate(left) ? 0 : 1)
          .compareTo(_canArrangePendingMakeCandidate(right) ? 0 : 1);
      if (readiness != 0) return readiness;
      return left.material.materialLineId.compareTo(
        right.material.materialLineId,
      );
    });
    return result;
  }

  /// 有子层级委外件判定：分析树中该节点存在生产性 BOM 子件
  /// （排除 SHIP/REFERENCE 非生产阶段）。只有这类委外件走「先自制」
  /// 候选两段式；无子层纯外发件确认后仍直接走申请链。
  bool _hasProductionBomChildren(
    ProductionMaterialAnalysisMaterial material,
    ProductionMaterialAnalysisView analysis,
  ) {
    final nodeKey = material.nodeKey;
    if (nodeKey == null) return false;
    return analysis.materials.any(
      (child) =>
          child.analysisLineId == material.analysisLineId &&
          child.parentNodeKey == nodeKey &&
          !_isNonProductionStage(child.controlStage),
    );
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

  /// 与采购/委外同口径的可执行判定：路线已确认 + 有剩余量 + 下层实际齐套。
  /// 下层未齐的候选留在暂不可安排区继续备料，齐套后才进入可安排区勾选。
  bool _canArrangePendingMakeCandidate(_PendingMakeCandidate candidate) {
    final group = candidate.group;
    return !candidate.material.lowerLevelPending &&
        group != null &&
        _isExecutableSupplyGroup(group, candidate.route);
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
    // 已完工产品退出顶部任务区，但仍保留在分析快照与下方 BOM 明细中。
    // 只认服务端 COMPLETED；IN_PROGRESS 100% 仍是执行中，不能提前隐藏。
    final operationalProducts = ordered
        .where((product) => !_productExecutionCompleted(product))
        .toList(growable: false);
    final visibleProducts = operationalProducts
        .take(_productVisibleLimit)
        .toList(growable: false);
    final remainingProducts =
        operationalProducts.length - visibleProducts.length;
    // 主分组只认员工当前能做什么，而不再按「产品 / 待创建 MAKE 子任务」
    // 两种实体各画一套容器。执行中的完成转移项先剥离，避免 readyNowQty=0
    // 被误写成待齐套；部分已转但仍有 remaining 的产品继续按剩余量门槛分组。
    final readyPendingMake = pendingMakeCandidates
        .where(_canArrangePendingMakeCandidate)
        .toList(growable: false);
    final waitingPendingMake = pendingMakeCandidates
        .where((candidate) => !_canArrangePendingMakeCandidate(candidate))
        .toList(growable: false);
    final readyProducts = operationalProducts
        .where(
          (product) =>
              !_productFullyTransferred(product) && _canSelectProduct(product),
        )
        .toList(growable: false);
    final waitingProducts = operationalProducts
        .where(
          (product) =>
              !_productFullyTransferred(product) && !_canSelectProduct(product),
        )
        .toList(growable: false);
    final transferredProducts = operationalProducts
        .where(_productFullyTransferred)
        .toList(growable: false);
    final visibleReadyCards = <Widget>[
      for (final candidate in visiblePendingMake)
        if (_canArrangePendingMakeCandidate(candidate))
          _pendingMakeCard(theme, candidate),
      for (final product in visibleProducts)
        if (!_productFullyTransferred(product) && _canSelectProduct(product))
          _productCard(theme, product),
    ];
    final visibleWaitingCards = <Widget>[
      for (final candidate in visiblePendingMake)
        if (!_canArrangePendingMakeCandidate(candidate))
          _pendingMakeCard(theme, candidate),
      for (final product in visibleProducts)
        if (!_productFullyTransferred(product) && !_canSelectProduct(product))
          _productCard(theme, product),
    ];
    final visibleTransferredCards = <Widget>[
      for (final product in visibleProducts)
        if (_productFullyTransferred(product)) _productCard(theme, product),
    ];
    final readyTaskCount = readyPendingMake.length + readyProducts.length;
    final waitingTaskCount = waitingPendingMake.length + waitingProducts.length;
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
                semanticLabel: '全选当前可直接填写生产计划的产品项',
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '生产准备任务',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    '可安排 $readyTaskCount · 受阻 $waitingTaskCount · '
                    '已转生产 ${transferredProducts.length} · '
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
        if (readyTaskCount > 0) ...[
          const SizedBox(height: UtenSpacing.s8),
          _productionTaskGroup(
            theme,
            key: const Key('material-analysis-ready-section'),
            title: '可安排',
            semanticDescription: '产品与自制候选都可勾选；自制候选勾选后先创建子件任务，再填写计划数量。',
            hint: '产品勾选后直接填数量；自制件先创建子件任务。',
            totalCount: readyTaskCount,
            icon: Icons.play_circle_outline_rounded,
            accent: theme.colorScheme.primary,
            foreground: theme.colorScheme.onPrimaryContainer,
            surface: theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
            cards: visibleReadyCards,
          ),
        ],
        if (waitingTaskCount > 0) ...[
          const SizedBox(height: UtenSpacing.s8),
          _productionTaskGroup(
            theme,
            key: const Key('material-analysis-waiting-section'),
            title: '暂不可安排',
            semanticDescription: '按卡片阻断原因处理；自制候选尚未形成生产任务。',
            totalCount: waitingTaskCount,
            icon: Icons.do_not_disturb_on_outlined,
            accent: theme.colorScheme.error,
            foreground: theme.colorScheme.onErrorContainer,
            surface: theme.colorScheme.errorContainer.withValues(alpha: 0.2),
            cards: visibleWaitingCards,
          ),
        ],
        if (transferredProducts.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          _productionTaskGroup(
            theme,
            key: const Key('material-analysis-transferred-section'),
            title: '已转生产',
            semanticDescription: '不参与本次全选；从卡片进入生产计划跟踪。',
            totalCount: transferredProducts.length,
            icon: Icons.account_tree_outlined,
            accent: theme.colorScheme.secondary,
            foreground: theme.colorScheme.onSurface,
            surface: theme.colorScheme.surfaceContainerLow,
            cards: visibleTransferredCards,
          ),
        ],
        if (remainingPendingMake > 0 || remainingProducts > 0) ...[
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              if (remainingPendingMake > 0)
                UtenButton(
                  key: const Key('material-analysis-show-more-pending-make'),
                  type: UtenButtonType.tonal,
                  icon: Icons.expand_more_rounded,
                  onPressed: () =>
                      setState(() => _pendingMakeVisibleLimit += 20),
                  child: Text('继续显示待自制件(还有 $remainingPendingMake 个)'),
                ),
              if (remainingProducts > 0)
                UtenButton(
                  key: const Key('material-analysis-show-more-products'),
                  type: UtenButtonType.tonal,
                  icon: Icons.expand_more_rounded,
                  onPressed: () => setState(() => _productVisibleLimit += 60),
                  child: Text('继续显示下一批(还有 $remainingProducts 个)'),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _productionTaskGroup(
    ThemeData theme, {
    required Key key,
    required String title,
    required String semanticDescription,
    // 非 InputDecoration：区块级提示文案，不属于表单字段消息契约范围。
    String? hint,
    required int totalCount,
    required IconData icon,
    required Color accent,
    required Color foreground,
    required Color surface,
    required List<Widget> cards,
  }) => Semantics(
    container: true,
    label: '$title，共 $totalCount 项。$semanticDescription',
    child: Container(
      key: key,
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: accent.withValues(alpha: 0.42)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: accent, size: 20),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                '$title · $totalCount',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (hint != null) ...[
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: Text(
                    hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: foreground,
                      height: 1.3,
                    ),
                  ),
                ),
              ] else
                const Spacer(),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          if (cards.isEmpty)
            Text(
              '本批尚未显示，点下方继续加载。',
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            )
          else
            // 卡片高度随缺料摘要、计划入口、选中态输入框变化：瀑布流按列
            // 独立堆叠，各列高度互不影响。
            UtenResponsiveGrid(
              itemCount: cards.length,
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              itemBuilder: (context, index, itemWidth) => cards[index],
            ),
        ],
      ),
    ),
  );

  Widget _productionTaskCardFrame(
    ThemeData theme, {
    required Key key,
    required bool selected,
    required Widget child,
  }) => Card(
    key: key,
    margin: EdgeInsets.zero,
    elevation: 0,
    color: selected ? UtenColors.deepGreen : theme.colorScheme.surface,
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
      child: child,
    ),
  );

  Widget _productionTaskStateIcon({
    Key? key,
    required String semanticLabel,
    required IconData icon,
    required Color accent,
    required Color surface,
  }) => Semantics(
    label: semanticLabel,
    child: SizedBox(
      key: key,
      width: 48,
      height: 48,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: UtenRadius.smAll,
          border: Border.all(color: accent.withValues(alpha: 0.42)),
        ),
        child: Center(child: Icon(icon, color: accent)),
      ),
    ),
  );

  Widget _productionTaskStatusPanel(
    ThemeData theme, {
    Key? key,
    Key? titleKey,
    Key? progressKey,
    Key? detailKey,
    Key? surfaceProgressKey,
    required String title,
    String? trailing,
    String? detail,
    double? progress,
    String? progressLabel,
    double? surfaceProgress,
    required Color accent,
    required Color surface,
    required Color foreground,
    required Color secondaryForeground,
    Color? progressBackground,
    Color? surfaceProgressColor,
    Color? surfaceProgressForeground,
    Color? surfaceProgressSecondaryForeground,
  }) {
    final normalizedDetail = detail?.trim();
    final normalizedSurfaceProgress =
        surfaceProgress == null || !surfaceProgress.isFinite
        ? null
        : surfaceProgress.clamp(0.0, 1.0).toDouble();

    Widget panelContent({
      required Color titleForeground,
      required Color detailForeground,
      required Color trailingForeground,
      required bool includeKeys,
    }) {
      Widget statusText(String value, {Key? key, required TextStyle? style}) {
        if (includeKeys) return Text(value, key: key, style: style);
        return RichText(
          text: TextSpan(text: value, style: style),
          textScaler: MediaQuery.textScalerOf(context),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: statusText(
                  title,
                  key: includeKeys ? titleKey : null,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: titleForeground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: UtenSpacing.s8),
                statusText(
                  trailing,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: trailingForeground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Semantics(
              label: progressLabel,
              child: ClipRRect(
                borderRadius: UtenRadius.smAll,
                child: LinearProgressIndicator(
                  key: includeKeys ? progressKey : null,
                  value: progress,
                  minHeight: 10,
                  backgroundColor:
                      progressBackground ??
                      theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(trailingForeground),
                ),
              ),
            ),
          ],
          if (normalizedDetail?.isNotEmpty == true) ...[
            const SizedBox(height: UtenSpacing.s4),
            statusText(
              normalizedDetail!,
              key: includeKeys ? detailKey : null,
              style: theme.textTheme.bodySmall?.copyWith(
                color: detailForeground,
                height: 1.3,
              ),
            ),
          ],
        ],
      );
    }

    return Container(
      key: key,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: surface, borderRadius: UtenRadius.smAll),
      foregroundDecoration: BoxDecoration(
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: accent.withValues(alpha: 0.45)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final paintedSurfaceProgress = constraints.maxWidth.isFinite
              ? normalizedSurfaceProgress
              : null;
          final filledForeground =
              surfaceProgressForeground ?? theme.colorScheme.onPrimary;
          final filledSecondaryForeground =
              surfaceProgressSecondaryForeground ??
              filledForeground.withValues(alpha: 0.82);
          return Stack(
            children: [
              if (paintedSurfaceProgress != null)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: constraints.maxWidth * paintedSurfaceProgress,
                  child: ColoredBox(
                    key: surfaceProgressKey,
                    color: surfaceProgressColor ?? accent,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s12,
                  vertical: UtenSpacing.s8,
                ),
                child: panelContent(
                  titleForeground: foreground,
                  detailForeground: secondaryForeground,
                  trailingForeground: accent,
                  includeKeys: true,
                ),
              ),
              if (paintedSurfaceProgress != null && paintedSurfaceProgress > 0)
                Positioned.fill(
                  child: ClipRect(
                    clipper: _HorizontalProgressClipper(paintedSurfaceProgress),
                    child: IgnorePointer(
                      child: ExcludeSemantics(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UtenSpacing.s12,
                            vertical: UtenSpacing.s8,
                          ),
                          child: panelContent(
                            titleForeground: filledForeground,
                            detailForeground: filledSecondaryForeground,
                            trailingForeground: filledForeground,
                            includeKeys: false,
                          ),
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

  Widget _pendingMakeCard(ThemeData theme, _PendingMakeCandidate candidate) {
    final material = candidate.material;
    final waiting = material.lowerLevelPending;
    final group = candidate.group;
    final route = candidate.route;
    final isSubcontract = route == MaterialSupplyRoute.subcontract;
    final taskLabel = isSubcontract ? '委外前置自制任务' : '自制子件任务';
    final goodsFallback = isSubcontract ? '待委外自制子件' : '待自制子件';
    final canArrange = _canArrangePendingMakeCandidate(candidate);
    final blocked = !canArrange;
    final selected =
        group != null && _selectedSupplyGroups[route]!.contains(group.key);
    final accent = blocked
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final statusSurface = blocked
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.primaryContainer;
    final onStatusSurface = blocked
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onPrimaryContainer;
    final goodsName = material.goodsName ?? material.goodsCode ?? goodsFallback;
    final description = waiting
        ? candidate.shortageKindCount > 0
              ? '下层还缺 ${candidate.shortageKindCount} 种物料'
                    '${candidate.shortagePathCount > candidate.shortageKindCount ? ' · 共 ${candidate.shortagePathCount} 条 BOM 路径' : ''}'
                    '${candidate.unconfirmedPathCount > 0 ? ' · 其中 ${candidate.unconfirmedPathCount} 条路线待确认' : ''}'
              : '下层物料尚未齐套，请继续处理下方 BOM 缺口'
        : canArrange
        ? '直接子层级已经齐套，可创建$taskLabel并填写生产数量'
        : '当前快照尚未满足${isSubcontract ? '委外前置自制' : '自制'}任务执行门槛，请刷新后再试';
    final statusSemantics = canArrange
        ? '下层已齐套，可安排生产'
        : waiting
        ? '下层备料中，不可排产'
        : '当前不可安排，请刷新后重试';
    final fullMakeQuantityLabel = canArrange && group != null
        ? _fullMakeQuantityLabel(group)
        : null;
    final meta = [
      material.goodsCode,
      material.spec,
      if (material.unitName?.isNotEmpty == true)
        '本批缺口 ${_qty(material.shortageQty)} ${material.unitName}',
    ].whereType<String>().join(' · ');
    return Semantics(
      container: true,
      label: '$goodsFallback $goodsName，$description',
      child: _productionTaskCardFrame(
        theme,
        key: ValueKey(
          'material-analysis-pending-make-${material.materialLineId}',
        ),
        selected: selected,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (canArrange && group != null && !_busy)
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: Checkbox(
                      key: ValueKey(
                        'material-analysis-pending-make-select-${material.materialLineId}',
                      ),
                      value: selected,
                      onChanged: !_canNotify || _busy
                          ? null
                          : (value) =>
                                _toggleSupplyGroup(route, group, value == true),
                      fillColor: selected
                          ? const WidgetStatePropertyAll(Colors.white)
                          : null,
                      checkColor: selected ? UtenColors.deepGreen : null,
                      semanticLabel: '选择$goodsName 创建$taskLabel',
                    ),
                  )
                else
                  _productionTaskStateIcon(
                    key: ValueKey(
                      'material-analysis-task-state-pending-make-${material.materialLineId}',
                    ),
                    semanticLabel: statusSemantics,
                    icon: blocked
                        ? Icons.do_not_disturb_on_outlined
                        : Icons.precision_manufacturing_outlined,
                    accent: accent,
                    surface: statusSurface.withValues(alpha: 0.5),
                  ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        goodsName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        candidate.parentLabel == null
                            ? '已确认${isSubcontract ? '委外自制件' : '自制件'}'
                            : '${isSubcontract ? '委外自制件' : '自制件'} · 用于 ${candidate.parentLabel}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
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
            if (blocked) ...[
              const SizedBox(height: UtenSpacing.s8),
              _productionTaskStatusPanel(
                theme,
                key: ValueKey(
                  'material-analysis-pending-make-status-${material.materialLineId}',
                ),
                title: waiting ? description : '当前不可安排，请刷新后重试',
                detail: waiting ? '待办卡，非生产计划；请继续处理下方 BOM。' : null,
                accent: accent,
                surface: statusSurface.withValues(alpha: 0.5),
                foreground: accent,
                secondaryForeground: onStatusSurface,
              ),
            ],
            if (canArrange) ...[
              const SizedBox(height: UtenSpacing.s8),
              _productionTaskStatusPanel(
                theme,
                key: ValueKey(
                  'material-analysis-pending-make-status-${material.materialLineId}',
                ),
                title: '勾选后创建$taskLabel',
                trailing: fullMakeQuantityLabel,
                detail: _canGenerate ? '创建后留在本页填写本批生产数量' : '创建后由有计划权限的员工填写生产数量',
                accent: theme.colorScheme.primary,
                surface: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.5,
                ),
                foreground: theme.colorScheme.onSurface,
                secondaryForeground: theme.colorScheme.onPrimaryContainer,
              ),
            ],
          ],
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
    final subcontractPreparation =
        product.sourceType == 'SUBCONTRACT_PREPARATION';
    final selected = _selectedPlanLineIds.contains(product.analysisLineId);
    final executionStage = _productExecutionStage(product);
    final fullyTransferred = _productFullyTransferred(product);
    final foreground = selected ? Colors.white : null;
    final secondaryForeground = selected
        ? Colors.white70
        : theme.colorScheme.onSurfaceVariant;
    final shortageSummary = _productShortageSummaryText(product);
    final blockerText = _productReadinessBlockerText(product);
    final statusDetail = [
      shortageSummary,
      blockerText,
    ].whereType<String>().join('\n');
    return _productionTaskCardFrame(
      theme,
      key: ValueKey('material-analysis-product-${product.analysisLineId}'),
      selected: selected,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (fullyTransferred)
                _productionTaskStateIcon(
                  key: ValueKey(
                    'material-analysis-task-state-product-${product.analysisLineId}',
                  ),
                  semanticLabel: executionStage!.label,
                  icon: executionStage.icon,
                  accent: _productExecutionColor(
                    theme,
                    executionStage,
                    selected: selected,
                  ),
                  surface: selected
                      ? Colors.white.withValues(alpha: 0.16)
                      : _productExecutionColor(
                          theme,
                          executionStage,
                          selected: false,
                        ).withValues(alpha: 0.12),
                )
              else if (!selectable)
                _productionTaskStateIcon(
                  key: ValueKey(
                    'material-analysis-task-state-product-${product.analysisLineId}',
                  ),
                  semanticLabel:
                      '暂不可安排，${product.goodsName ?? product.goodsCode ?? '当前产品'}',
                  icon: Icons.do_not_disturb_on_outlined,
                  accent: theme.colorScheme.error,
                  surface: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.5,
                  ),
                )
              else
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
              const SizedBox(width: UtenSpacing.s8),
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
                            ? '自制子件'
                            : '用于组装 ${product.parentGoodsName}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: selected
                              ? Colors.white
                              : theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    else if (subcontractPreparation)
                      Text(
                        '委外前置自制 · 完成合格入仓后交仓库出仓',
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
          if ((selected || subcontractPreparation) &&
              product.sourceReason?.trim().isNotEmpty == true)
            Text(
              '来源原因：${product.sourceReason}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: secondaryForeground,
              ),
            ),
          const SizedBox(height: UtenSpacing.s8),
          _producibleHeadline(
            theme,
            product,
            selected: selected,
            detail: statusDetail.isEmpty ? null : statusDetail,
            detailKey: blockerText == null
                ? null
                : ValueKey(
                    'material-analysis-product-blocker-${product.analysisLineId}',
                  ),
          ),
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
                          RoutePath.productionPlanDetail(product.latestPlanId!),
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
            _batchQuantityField(theme, product),
          ],
        ],
      ),
    );
  }

  Widget _batchQuantityField(
    ThemeData theme,
    ProductionMaterialAnalysisProduct product,
  ) {
    final unitName = product.unitName?.trim();
    final unitLabel = unitName?.isNotEmpty == true ? unitName! : '个';
    final maxLabel = '最多 ${_qty(product.readyNowQty)} $unitLabel';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeSemantics(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '本批生产数量',
                  key: ValueKey('batch-qty-label-${product.analysisLineId}'),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Flexible(
                child: Text(
                  maxLabel,
                  key: ValueKey('batch-qty-helper-${product.analysisLineId}'),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Semantics(
          key: ValueKey('batch-qty-semantics-${product.analysisLineId}'),
          label: '本批生产数量',
          hint: maxLabel,
          textField: true,
          child: TextField(
            key: Key('batch-qty-${product.analysisLineId}'),
            controller: _batchQtyControllers[product.analysisLineId],
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() => _planPreview = null),
            style: const TextStyle(color: UtenColors.docInk),
            decoration: const InputDecoration(
              hintText: '请输入数量',
              filled: true,
              fillColor: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  /// 产品卡缺口摘要：种类按服务端 materialKey/货色单位去重，同时保留
  /// BOM 路径数，避免同一种共享物料在多路径出现时被误写成多种料。
  /// 这里只统计服务端 shortage 快照，不重算任何可生产数量。
  String? _productShortageSummaryText(
    ProductionMaterialAnalysisProduct product,
  ) {
    final analysis = _analysis;
    if (analysis == null || _productFullyTransferred(product)) return null;
    final nodes =
        _analysisIndexes(analysis).materialsByProduct[product.analysisLineId] ??
        const <ProductionMaterialAnalysisMaterial>[];
    final shortageNodes = nodes
        .where((node) => node.shortageQty > 0)
        .toList(growable: false);
    if (shortageNodes.isEmpty) return null;
    final shortageKindCount = shortageNodes
        .map(_materialKindIdentity)
        .toSet()
        .length;
    final unconfirmed = shortageNodes
        .where((node) => node.confirmedRoute == null)
        .length;
    return '还缺 $shortageKindCount 种物料'
        '${shortageNodes.length > shortageKindCount ? ' · 共 ${shortageNodes.length} 条 BOM 路径' : ''}'
        '${unconfirmed > 0 ? ' · 其中 $unconfirmed 条路线待确认' : ''}';
  }

  Widget _transferredProductHeadline(
    ThemeData theme,
    ProductionMaterialAnalysisProduct product,
    _ProductExecutionStage stage, {
    required bool selected,
  }) {
    final accent = _productExecutionColor(theme, stage, selected: selected);
    final detail = stage.detail?.trim();
    final executionProgress = stage.status == 'IN_PROGRESS'
        ? stage.progress
        : null;
    final progressSurface = selected
        ? Colors.white.withValues(alpha: 0.24)
        : theme.colorScheme.primary;
    final progressForeground = selected
        ? Colors.white
        : theme.colorScheme.onPrimary;
    return _productionTaskStatusPanel(
      theme,
      key: ValueKey(
        'material-analysis-product-execution-${product.analysisLineId}',
      ),
      surfaceProgressKey: ValueKey(
        'material-analysis-product-execution-fill-${product.analysisLineId}',
      ),
      title: stage.label,
      detail: detail,
      surfaceProgress: executionProgress,
      accent: accent,
      surface: selected
          ? Colors.white.withValues(alpha: 0.14)
          : accent.withValues(alpha: 0.10),
      foreground: selected ? Colors.white : theme.colorScheme.onSurface,
      secondaryForeground: selected
          ? Colors.white70
          : theme.colorScheme.onSurfaceVariant,
      surfaceProgressColor: progressSurface,
      surfaceProgressForeground: progressForeground,
      surfaceProgressSecondaryForeground: progressForeground.withValues(
        alpha: 0.82,
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
    String? detail,
    Key? detailKey,
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
    final percent = (ratio * 100).toStringAsFixed(0);
    return _productionTaskStatusPanel(
      theme,
      key: ValueKey(
        'material-analysis-product-status-${product.analysisLineId}',
      ),
      titleKey: directMake
          ? ValueKey('material-analysis-direct-make-${product.analysisLineId}')
          : null,
      progressKey: ValueKey(
        'material-analysis-product-progress-${product.analysisLineId}',
      ),
      detailKey: detailKey,
      title: directMake
          ? '可直接自制 ${_qty(maxQty)} 个'
          : producible
          ? '最多可生产 ${_qty(maxQty)} 个'
          : '暂不可生产',
      trailing: directMake ? '无需领料' : '齐套 $percent%',
      detail: detail,
      // DIRECT_MAKE 没有物料齐套分母，但仍使用同一状态卡骨架。满轨道表达
      // “无领料门槛”，文字继续明确写“无需领料”，不伪装成齐套 100%。
      progress: directMake ? 1 : ratio,
      progressLabel: directMake ? '无需领料，可直接自制' : '齐套进度 $percent%',
      accent: accent,
      surface: selected
          ? Colors.white.withValues(alpha: 0.14)
          : producible
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : theme.colorScheme.errorContainer.withValues(alpha: 0.5),
      foreground: onSurface,
      secondaryForeground: selected
          ? Colors.white70
          : producible
          ? theme.colorScheme.onPrimaryContainer
          : theme.colorScheme.onErrorContainer,
      progressBackground: selected
          ? Colors.white24
          : theme.colorScheme.surfaceContainerHighest,
    );
  }

  /// The other two stage quantities are kept (ADR-029 §5.2 forbids merging the
  /// three into one fuzzy number) but demoted to a single small reference line,
  /// with "可开工" relabelled to "开工段就绪" so it can no longer be read as
  /// "you may start production". Neither value caps the batch input.
  /// Explains WHY a non-ready product is blocked and what unblocks it, so the
  /// planner can follow the bottom-up chain without guessing. Hidden once the
  /// product is plan-ready (the headline already says "最多可生产 X 个").
  String? _productReadinessBlockerText(
    ProductionMaterialAnalysisProduct product,
  ) {
    if (product.readyNowQty > 0 || _productFullyTransferred(product)) {
      return null;
    }
    final readiness = _productReadiness(product);
    final parts = <String>[];
    if (readiness.make > 0) parts.add('自制子件 ${readiness.make}');
    if (readiness.buy > 0) parts.add('采购 ${readiness.buy}');
    if (readiness.subcontract > 0) parts.add('委外 ${readiness.subcontract}');
    if (readiness.review > 0) parts.add('待判断路线 ${readiness.review}');
    if (parts.isEmpty) parts.add('物料未齐');
    final hint = readiness.state == _ReadinessState.waitingMake
        ? '先排产并入库下级自制件，齐套量会自动更新'
        : '按下方 BOM 状态处理，合格入库后自动刷新';
    return '等待：${parts.join(' · ')} · $hint';
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
    final requirementView = coverage == null
        ? _requirementStateView(theme, material)
        : null;
    final delegated =
        material.effectiveRequirementState ==
        MaterialRequirementState.delegatedToMakeChild;
    final delegatedOwner = _delegatedOwnerLabel(material);
    final delegatedChildStatus = _delegatedChildStatusLabel(material);
    final detailFacts = <String>[
      if (coverage != null) '本批需求 ${_qty(material.requiredQty)}',
      if (coverage != null)
        '合格库存保障 ${_qty(coverage.covered)}/'
            '${_qty(material.requiredQty)}'
            '(${(coverage.ratio * 100).toStringAsFixed(0)}%)',
      if (requirementView != null) requirementView.title,
      if (requirementView != null) requirementView.detail,
      if (delegated && material.delegatedToRequestedQty != null)
        '接管子任务总需求 ${_qty(material.delegatedToRequestedQty)}',
      if (delegated && delegatedOwner != null) '接管来源 $delegatedOwner',
      if (delegatedChildStatus != null) '接管子任务状态 $delegatedChildStatus',
      if (exactPeggedQty > 0) '本节点合格入库绑定 ${_qty(exactPeggedQty)}',
      if (material.subcontractHandoffFutureQty > 0)
        '委外前置自制已接管供给 ${_qty(material.subcontractHandoffFutureQty)}',
      if (material.reservedQty > 0) '已预留 ${_qty(material.reservedQty)}',
      if (warehouseStock != null &&
          (coverage != null || warehouseStock.publicAvailableQty > 0))
        '公共可用 ${_qty(warehouseStock.publicAvailableQty)}',
      if (material.safetyStockQty > 0) '安全保护 ${_qty(material.safetyStockQty)}',
      if (warehouseStock != null &&
          (coverage != null || warehouseStock.openSafetySupplyQty > 0))
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
                _semanticFact(fact, style: theme.textTheme.bodySmall),
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
  }) {
    final label = material.requiredQty <= 0
        ? (() {
            final view = _requirementStateView(theme, material);
            return '${view.title}；${view.detail}';
          })()
        : material.shortageQty <= 0
        ? '库存已覆盖'
        : '当前节点只读；请查看状态与路径原因';
    return _semanticFact(
      label,
      key: ValueKey('material-inactive-hint-${material.materialLineId}'),
      style: theme.textTheme.bodySmall?.copyWith(
        color: selected ? Colors.white70 : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _makePlanReference(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
    ProductionMaterialAnalysisProduct child, {
    required bool selected,
    bool compact = false,
  }) {
    final latestPlanId = child.latestPlanId!;
    if (!_canViewPlans) {
      return _disabledNodeAction(
        selected ? Colors.white70 : theme.colorScheme.onSurfaceVariant,
        Icons.lock_outline_rounded,
        '无查看生产计划权限',
      );
    }
    return TextButton.icon(
      key: ValueKey('material-view-plan-${material.materialLineId}'),
      style: TextButton.styleFrom(
        minimumSize: Size(48, compact ? 44 : 48),
        foregroundColor: selected ? Colors.white : null,
      ),
      onPressed: () =>
          context.push(RoutePath.productionPlanDetail(latestPlanId)),
      icon: const Icon(Icons.open_in_new_rounded, size: 18),
      label: Text(
        compact
            ? '生产计划 · ${child.latestPlanNo ?? '查看'}'
            : child.latestPlanNo ?? '查看计划',
      ),
    );
  }

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
        return _makePlanReference(theme, material, child!, selected: selected);
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
      if (notifiedRoute == MaterialSupplyRoute.subcontract &&
          _canViewSubcontractPreparations) {
        return FilledButton.tonalIcon(
          key: ValueKey(
            'material-open-subcontract-preparation-${material.materialLineId}',
          ),
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            foregroundColor: selected ? UtenColors.deepGreen : null,
            backgroundColor: selected ? Colors.white : null,
          ),
          onPressed: _busy
              ? null
              : () {
                  final analysis = _analysis;
                  if (analysis == null) return;
                  context.push(
                    RoutePath.productionSubcontractPreparations(
                      sourceAnalysisId: analysis.analysisId,
                      sourceMaterialLineId: material.materialLineId,
                    ),
                  );
                },
          icon: const Icon(Icons.precision_manufacturing_outlined),
          label: Text(_canStartSubcontractPreparations ? '安排前置自制' : '查看前置自制'),
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
      MaterialSupplyRoute.subcontract => '下达委外准备',
      MaterialSupplyRoute.make => '创建子件任务',
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
                ? () => _arrangeMakeProduction(onlyGroup: group)
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
    if (material.requiredQty <= 0) {
      final view = _requirementStateView(theme, material);
      return _StatusView(view.title, view.icon, view.color);
    }
    if (!group.actionable) {
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
        final child = _makeChildProductOf(material);
        final executionStage = child == null
            ? null
            : _productExecutionStage(child);
        if (executionStage != null) {
          final label = covered && executionStage.status != 'COMPLETED'
              ? '本批库存已覆盖 · ${executionStage.label}'
              : executionStage.label;
          return _StatusView(
            label,
            executionStage.icon,
            _productExecutionColor(theme, executionStage, selected: false),
          );
        }
        if (covered) {
          return _StatusView(
            '本批库存已覆盖 · 自制任务状态待回传',
            Icons.inventory_2_outlined,
            theme.colorScheme.primary,
          );
        }
        return _StatusView(
          '待安排生产',
          Icons.precision_manufacturing_outlined,
          theme.colorScheme.primary,
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
        route == MaterialSupplyRoute.subcontract ? '委外准备处理中' : '等待采购入库',
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
}
