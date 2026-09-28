part of 'production_material_analysis_page.dart';

/// 新建物料分析页的两个分段(ADR-130)：勾选销售订单产品 / 录入手工需求单。
/// 两边录入的内容一起构成「本次分析」，由右下角同一个按钮联合分析。
enum _CandidateTab { sales, manual }

/// 分析结果顶部「手工需求」chip 的一组：同一(来源类型, 需求编号)下的货品。
class _ManualDemandSummary {
  _ManualDemandSummary(this.sourceType, this.sourceRef);

  final String sourceType;
  final String sourceRef;
  final Set<String> goods = {};
  final List<String> reasons = [];
}

abstract class _MaterialAnalysisCandidatesState
    extends _MaterialAnalysisPageBase {
  @override
  void initState() {
    super.initState();
    _manualDemandDrafts.add(_createManualDemandDraft());
  }

  /// 候选搜索：防抖由 UtenSearchBar 内置（300ms），停止输入后再检索。
  void _searchCandidates(String value) {
    _candidateKeyword = value.trim();
    _loadCandidates(page: 1);
  }

  bool _candidateSelected(MaterialAnalysisSalesCandidateLine line) =>
      _sourceQtyControllers.containsKey(line.salesOrderItemId);

  /// 各张手工需求单里已选货品的行数(每行 = 一个分析来源)。
  int get _manualGoodsLineCount {
    var count = 0;
    for (final draft in _manualDemandDrafts) {
      count += draft.goodsLineCount;
    }
    return count;
  }

  /// 本次分析项数 = 勾选的销售订单产品 + 手工需求里已选货品的行(合计上限 500)。
  int get _selectedAnalysisSourceCount =>
      _sourceQtyControllers.length + _manualGoodsLineCount;

  int get _remainingSalesSourceSlots =>
      (_MaterialAnalysisPageBase._maxAnalysisItems - _manualGoodsLineCount)
          .clamp(0, _MaterialAnalysisPageBase._maxAnalysisItems);

  void _showCandidateTab(_CandidateTab tab) {
    if (_candidateTab == tab) return;
    setState(() => _candidateTab = tab);
  }

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
        _selectedAnalysisSourceCount >=
            _MaterialAnalysisPageBase._maxAnalysisItems) {
      context.appWarning('单次联合分析最多 500 项(销售订单产品与手工需求合计)，其余请另开一个批次');
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
  /// 数量默认带入当前待排量，员工只需在表内「本次分析数量」列改例外数量。
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
        '单次联合分析最多 500 项(销售订单产品与手工需求合计)，已保留可加入的前 $salesSourceLimit 项；其余请另开一个批次',
      );
    }
  }

  String _candidateLabel(MaterialAnalysisSalesCandidateLine line) => [
    line.orderNo,
    line.goodsName ?? line.goodsCode,
    line.spec,
  ].whereType<String>().where((value) => value.trim().isNotEmpty).join(' · ');

  /// 销售订单产品「本次分析数量」的合格值：能解析、有限且大于 0，否则 null。
  /// 提交校验与表内必填红框共用这一个口径。
  double? _positiveAnalysisQty(String text) {
    final quantity = double.tryParse(text.trim());
    return quantity == null || !quantity.isFinite || quantity <= 0
        ? null
        : quantity;
  }

  /// 本次分析的全部来源：手工需求单的每行货品 + 勾选的销售订单产品。
  /// 任一处不合格就提示原因、切到出问题的分段，并返回 null(不发请求)。
  List<MaterialAnalysisSourceInput>? _candidateSources() {
    // 每次分析前重新判定标红：上一次标红的行即使本人没动(比如删掉的是另一条
    // 重复行)，这次也先清掉，只留这次真正有问题的行。
    for (final draft in _manualDemandDrafts) {
      for (var i = 0; i < draft.grid.length; i++) {
        draft.grid[i].flagged = false;
      }
    }
    final salesSources = <MaterialAnalysisSourceInput>[];
    for (final entry in _sourceQtyControllers.entries) {
      final quantity = _positiveAnalysisQty(entry.value.text);
      if (quantity == null) {
        _showCandidateTab(_CandidateTab.sales);
        context.appWarning(
          '「${_selectedCandidateLabels[entry.key] ?? '所选销售订单产品'}」的本次分析数量必须大于 0',
        );
        return null;
      }
      salesSources.add(
        MaterialAnalysisSourceInput(
          salesOrderItemId: entry.key,
          requestedQty: quantity,
        ),
      );
    }
    final manual = buildMaterialManualDemandSources(
      _manualDemandDrafts,
      defaultDeliveryDate: _deliveryDate,
      otherSourceCount: salesSources.length,
    );
    if (!manual.isValid) {
      for (final line in manual.flaggedLines) {
        line.flagged = true;
      }
      final draftIndex = manual.draftIndex;
      if (draftIndex != null) {
        _showCandidateTab(_CandidateTab.manual);
        _revealManualDemandDraft(_manualDemandDrafts[draftIndex]);
      }
      context.appWarning(manual.error!);
      return null;
    }
    return [...manual.sources, ...salesSources];
  }

  /// 每张手工需求单卡片的定位锚点：新建一张或校验卡在某一张时把它滚进视野。
  /// 随单释放(见 [_releaseManualDemandDrafts])。
  final Map<MaterialManualDemandDraft, GlobalKey> _manualDemandCardKeys = {};

  MaterialManualDemandDraft _createManualDemandDraft() {
    final draft = MaterialManualDemandDraft();
    draft.grid.rowsListenable.addListener(_onManualDemandRowsChanged);
    return draft;
  }

  /// 下一帧把 [draft] 的卡片滚到列表可视区顶部(桌面列表与窄屏滚动页通用)。
  /// 卡片还没建出来(比如不在手工需求分段)就不动。
  void _revealManualDemandDraft(MaterialManualDemandDraft draft) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final cardContext = _manualDemandCardKeys[draft]?.currentContext;
      if (cardContext == null || !cardContext.mounted) return;
      // 默认对齐 = 卡片顶部贴可视区顶部。
      Scrollable.ensureVisible(
        cardContext,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 手工需求单增删行(含右键粘贴/删除)后刷新分段计数与「本次分析 N 项」。
  void _onManualDemandRowsChanged() {
    if (mounted) setState(() {});
  }

  /// 摘下监听后在本帧之后释放：卸载中的表格与输入框还要对这些控制器解除订阅。
  void _releaseManualDemandDrafts(List<MaterialManualDemandDraft> drafts) {
    if (drafts.isEmpty) return;
    for (final draft in drafts) {
      draft.grid.rowsListenable.removeListener(_onManualDemandRowsChanged);
      _manualDemandCardKeys.remove(draft);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final draft in drafts) {
        draft.dispose();
      }
    });
  }

  /// 清空后仍保留一张空白手工需求单(调用方负责 setState)。
  void _resetManualDemandDrafts() {
    final previous = List<MaterialManualDemandDraft>.of(_manualDemandDrafts);
    _manualDemandDrafts
      ..clear()
      ..add(_createManualDemandDraft());
    _releaseManualDemandDrafts(previous);
  }

  /// 新单追加在列表末尾：第一张单货品多时它落在首屏以下，点了像没反应，
  /// 所以建好后把它滚进视野。
  void _addManualDemandDraft() {
    if (_busy || !_canManage) return;
    final draft = _createManualDemandDraft();
    setState(() => _manualDemandDrafts.add(draft));
    _revealManualDemandDraft(draft);
  }

  Future<void> _removeManualDemandDraft(MaterialManualDemandDraft draft) async {
    if (_busy || _manualDemandDrafts.length <= 1) return;
    if (draft.hasInput) {
      final goodsCount = draft.goodsLineCount;
      final confirmed = await UtenDialog.show(
        context,
        title: '删除这张手工需求单？',
        content: Text(
          goodsCount > 0
              ? '单里已选的 $goodsCount 个货品和填写的单头会一起删除。'
              : '单里填写的内容会一起删除。',
        ),
        confirmLabel: '删除',
        danger: true,
      );
      if (confirmed != true || !mounted) return;
    }
    if (!_manualDemandDrafts.contains(draft) ||
        _manualDemandDrafts.length <= 1) {
      return;
    }
    setState(() => _manualDemandDrafts.remove(draft));
    _releaseManualDemandDrafts([draft]);
  }

  void _setManualDemandSourceType(
    MaterialManualDemandDraft draft,
    String? sourceType,
  ) {
    setState(() => draft.sourceType = sourceType);
  }

  /// 点「货品名称」格：多选选货，第一个填这一行，其余依次填后面的空行、不够再追加；
  /// 本单已有的货品跳过；超过本次分析 500 项上限的部分不加入并提示。
  Future<void> _pickManualDemandGoods(
    MaterialManualDemandDraft draft,
    MaterialManualDemandLine line,
  ) async {
    if (_busy || !_canManage) return;
    final picked = await ref.read(materialAnalysisManualGoodsPickerProvider)(
      context,
      ref,
    );
    if (!mounted || picked.isEmpty) return;
    if (!_manualDemandDrafts.contains(draft) ||
        !draft.grid.rows.contains(line)) {
      return;
    }
    final result = applyMaterialManualDemandPick(
      draft,
      line,
      picked,
      remainingSlots:
          _MaterialAnalysisPageBase._maxAnalysisItems -
          _selectedAnalysisSourceCount,
    );
    setState(() {});
    final notes = <String>[
      if (result.duplicates > 0)
        '已跳过 ${result.duplicates} 个这张单里已有的货品，同一货品请直接改原行数量',
      if (result.capped > 0)
        '单次联合分析最多 500 项(销售订单产品与手工需求合计)，'
            '还有 ${result.capped} 个货品没有加入，请另开一个分析批次',
    ];
    if (notes.isNotEmpty) context.appWarning(notes.join('；'));
  }

  Future<void> _startCandidateAnalysis() async {
    final sources = _candidateSources();
    if (sources == null) return;
    _sources = sources;
    await _previewAnalysis();
  }

  @override
  Future<void> _previewAnalysis() async {
    if (_previewingAnalysis || !_canManage) return;
    final warehouseId = _warehouseId;
    if (warehouseId == null) {
      context.appWarning('请先选择分析仓库');
      return;
    }
    final warehouseIds = _warehouseIds.toList()..sort();
    if (!warehouseIds.contains(warehouseId)) {
      context.appWarning('仓库范围不完整，请重新选择主仓库');
      return;
    }
    if (_sources.isEmpty) {
      context.appWarning('请至少选择一个待分析产品');
      return;
    }
    if (_sources.length > _MaterialAnalysisPageBase._maxAnalysisItems) {
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
        warehouseIds.join(','),
        // 行需求日也是来源内容：只改日期的两次提交不能复用同一个幂等键。
        for (final source in canonicalSources)
          '${source.canonicalKey}:${source.requestedQty}:'
              '${source.sourceReason ?? ''}:${source.deliveryDate ?? ''}',
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
            warehouseIds: warehouseIds,
            idempotencyKey: key,
            sources: canonicalSources,
          );
      if (!mounted) return;
      setState(() {
        _previewingAnalysis = false;
        _applyAnalysis(view);
        // 刷新时服务端因主档/BOM 事实变更清空了人工确认路线：明示条数，
        // 不让「路线待确认」无声出现（F8）。
        if (view.routeResetCount > 0) {
          _serverRefreshNotice = '${view.routeResetCount} 条路线因主档变更需重新确认';
        }
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
    final salesTab = _candidateTab == _CandidateTab.sales;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _candidateGuidance(theme)),
              const SizedBox(width: UtenSpacing.s12),
              SizedBox(width: 260, child: _warehouseField()),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          // 分段 + 搜索框(手工需求分段为「再建一张」按钮)：一行放得下就左右分开，
          // 窄窗口(约 600-900 宽)放不下时右侧整体换到下一行，分段始终完整可见。
          Wrap(
            key: const Key('material-analysis-candidate-tab-row'),
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
            children: [
              _candidateTabs(),
              if (salesTab)
                SizedBox(width: 320, child: _candidateSearchBar())
              else if (_canManage)
                _addManualDemandButton(),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          if (_error != null) ...[
            _inlineError(theme, _error!, () => _loadCandidates()),
            const SizedBox(height: UtenSpacing.s8),
          ],
          Expanded(
            child: salesTab
                ? _salesCandidateTable(page, lines)
                // 卡片一次全建出来(不按可视区懒建)：新建或校验出错的卡片即使在
                // 首屏以下，也能按锚点滚过去。每张卡片的明细表本身就是整表展开。
                : SingleChildScrollView(
                    key: const Key('material-manual-demand-list'),
                    padding: const EdgeInsets.only(
                      bottom: UtenFloatingActionGroup.scrollClearance,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _manualDemandIntro(theme),
                        const SizedBox(height: UtenSpacing.s8),
                        ..._manualDemandCards(compact: false),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 顶部一行说明：两个分段录入的内容合在一起联合分析。
  Widget _candidateGuidance(ThemeData theme) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Icon(
          Icons.info_outline_rounded,
          size: 20,
          color: theme.colorScheme.primary,
        ),
      ),
      const SizedBox(width: UtenSpacing.s8),
      Expanded(
        child: Text(
          '勾选销售订单产品，或在「手工需求」录入返工、试制、样品、备库需求，'
          '再点右下角「联合分析」一起分析。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ],
  );

  /// 两个分段的文字；[twoLine] 时计数换到第二行(窄屏大字号用)。
  List<String> _candidateTabLabels({bool twoLine = false}) {
    final gap = twoLine ? '\n' : ' ';
    return [
      '销售订单产品$gap(已选 ${_sourceQtyControllers.length})',
      '手工需求$gap($_manualGoodsLineCount 行)',
    ];
  }

  Widget _candidateTabs({bool twoLine = false}) {
    final labels = _candidateTabLabels(twoLine: twoLine);
    return UtenSegmentedFilter<_CandidateTab>(
      key: const Key('material-analysis-candidate-tabs'),
      segments: [
        UtenSegment(value: _CandidateTab.sales, label: labels[0]),
        UtenSegment(value: _CandidateTab.manual, label: labels[1]),
      ],
      selected: _candidateTab,
      onChanged: _showCandidateTab,
    );
  }

  /// 窄屏分段：一行放不下(手机 + 大字号)时计数换到第二行，两段都完整可见、
  /// 点按区不缩小；分段条本身不带滚动条，不能指望用户横着拖出被遮住的那段。
  Widget _compactCandidateTabs() => LayoutBuilder(
    builder: (context, constraints) => _candidateTabs(
      twoLine: !_candidateTabsFitOneLine(context, constraints.maxWidth),
    ),
  );

  /// 按实际字号估算两段单行铺开的宽度(文字实测 + 选中段左右留白按偏大取)。
  bool _candidateTabsFitOneLine(BuildContext context, double maxWidth) {
    final style = Theme.of(context).textTheme.titleSmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final scaler = MediaQuery.textScalerOf(context);
    var total = 8.0 + 4.0; // 分段条内边距 4×2 + 余量
    for (final label in _candidateTabLabels()) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      total += painter.width + 40; // 选中段左右各 20
      painter.dispose();
    }
    return total <= maxWidth;
  }

  Widget _candidateSearchBar() => UtenSearchBar(
    controller: _candidateSearch,
    hint: '搜索销售单号或货品',
    onChanged: _searchCandidates,
  );

  Widget _salesCandidateTable(
    MaterialAnalysisSalesCandidatePage? page,
    List<MaterialAnalysisSalesCandidateLine> lines,
  ) => MasterDataTableView<MaterialAnalysisSalesCandidateLine>(
    key: const Key('material-analysis-candidate-table'),
    columns: _candidateColumns,
    items: lines,
    selectable: _canManage,
    idOf: (line) => (line.remainingQty ?? 0) > 0 ? line.salesOrderItemId : null,
    selectedIds: _sourceQtyControllers.keys.toSet(),
    showSelectionSummary: false,
    bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
    onSelectedIdsChanged: (ids) => _replaceCandidateIds(ids, lines),
    // 2026-09-25 单号列统一：销售单号值来自服务端 facets
    // (与列表同一过滤上下文)，值筛选走服务端精确匹配。
    facets: {'orderNo': _candidateDocNoFacets['orderNo'] ?? const []},
    nullCounts: const {},
    filters: {'orderNo': _candidateOrderNoFilter},
    onFilterChanged: (key, value) {
      if (key != 'orderNo') return;
      setState(() {
        final next = value?.trim();
        _candidateOrderNoFilter = next == null || next.isEmpty ? null : next;
      });
      _loadCandidates(page: 1);
    },
    // 2026-09-25 单号列统一：表头排序走服务端白名单(orderNo)。
    sortColumn: _candidateSortColumn,
    sortAscending: _candidateSortAscending,
    onSortChange: (column, ascending) {
      setState(() {
        _candidateSortColumn = column;
        _candidateSortAscending = ascending;
      });
      _loadCandidates(page: 1);
    },
    isLoading: _loadingCandidates,
    emptyMessage: '暂无可分析的已审销售订单产品',
    currentPage: page?.page ?? _candidatePageNo,
    totalPages: page?.totalPages ?? 1,
    onPageChange: (value) => _loadCandidates(page: value),
  );

  Widget _manualDemandIntro(ThemeData theme) => Text(
    '一张手工需求单 = 一个需求编号 + 多个货品。同一编号的货品录在同一张单里，'
    '不同编号请再建一张单；需求编号用于后续找回任务，来源原因随分析留痕。',
    style: theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    ),
  );

  List<Widget> _manualDemandCards({required bool compact}) {
    if (!_canManage) {
      return const [UtenEmpty(message: '没有新建物料分析权限，不能录入手工需求')];
    }
    return [
      for (var index = 0; index < _manualDemandDrafts.length; index++) ...[
        if (index > 0) const SizedBox(height: UtenSpacing.s12),
        _manualDemandCard(_manualDemandDrafts[index], index, compact: compact),
      ],
    ];
  }

  Widget _manualDemandCard(
    MaterialManualDemandDraft draft,
    int index, {
    required bool compact,
  }) => KeyedSubtree(
    key: _manualDemandCardKeys.putIfAbsent(
      draft,
      () => GlobalKey(debugLabel: 'manual-demand-card'),
    ),
    child: MaterialManualDemandCard(
      key: ObjectKey(draft),
      draft: draft,
      index: index,
      cardCount: _manualDemandDrafts.length,
      compact: compact,
      enabled: !_busy,
      onSourceTypeChanged: (value) => _setManualDemandSourceType(draft, value),
      onPickGoods: (line) => _pickManualDemandGoods(draft, line),
      onRemove: _manualDemandDrafts.length > 1
          ? () => _removeManualDemandDraft(draft)
          : null,
    ),
  );

  Widget _addManualDemandButton({bool expanded = false}) => UtenButton(
    key: const Key('manual-demand-add-card'),
    type: UtenButtonType.tonal,
    icon: Icons.add_rounded,
    isExpanded: expanded,
    onPressed: _busy ? null : _addManualDemandDraft,
    child: const Text('再建一张手工需求单'),
  );

  Widget _candidateStartButton(int selectedCount) => UtenButton(
    key: const Key('material-analysis-start'),
    size: UtenButtonSize.large,
    type: UtenButtonType.danger,
    icon: Icons.insights_outlined,
    isLoading: _previewingAnalysis,
    onPressed: selectedCount == 0 || _previewingAnalysis
        ? null
        : _startCandidateAnalysis,
    onDisabledTap: selectedCount == 0
        ? () => context.appWarning('请先勾选销售订单产品，或在「手工需求」里选择货品')
        : null,
    child: Text(selectedCount == 0 ? '联合分析' : '联合分析所选 $selectedCount 项'),
  );

  Widget? _candidateFloatingAction() {
    if (!_canManage) return null;
    final selectedCount = _selectedAnalysisSourceCount;
    return UtenFloatingActionGroup(
      children: [
        UtenSelectionSummaryPill(
          key: const Key('material-analysis-candidate-selected-total'),
          clearKey: const Key('material-analysis-candidate-clear-selection'),
          count: selectedCount,
          onClear: selectedCount == 0 || _busy
              ? null
              : _clearCandidateSelection,
        ),
        _candidateStartButton(selectedCount),
      ],
    );
  }

  /// 胶囊「✕」清空本次分析：销售勾选与手工需求单一起清。手工需求里已选了货品时
  /// 先确认——那是一行行录进去的内容，误点一下全没了代价太大。
  Future<void> _clearCandidateSelection() async {
    if (_busy) return;
    final manualCount = _manualGoodsLineCount;
    if (manualCount > 0) {
      final confirmed = await UtenDialog.show(
        context,
        title: '清空本次分析？',
        content: Text(
          '会同时清空已勾选的 ${_sourceQtyControllers.length} 个销售订单产品，'
          '以及手工需求单里已选的 $manualCount 个货品和单头。',
        ),
        confirmLabel: '清空',
        danger: true,
      );
      if (confirmed != true || !mounted || _busy) return;
    }
    setState(() {
      for (final controller in _sourceQtyControllers.values) {
        controller.dispose();
      }
      _sourceQtyControllers.clear();
      _selectedCandidateLabels.clear();
      _resetManualDemandDrafts();
    });
  }

  Widget _compactCandidateBody(
    ThemeData theme,
    MaterialAnalysisSalesCandidatePage? page,
    List<MaterialAnalysisSalesCandidateLine> lines,
  ) {
    const gap = SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s8));
    final salesTab = _candidateTab == _CandidateTab.sales;
    return CustomScrollView(
      key: const Key('material-analysis-candidate-mobile-list'),
      slivers: [
        gap,
        SliverToBoxAdapter(child: _candidateGuidance(theme)),
        gap,
        SliverToBoxAdapter(child: _warehouseField()),
        gap,
        SliverToBoxAdapter(child: _compactCandidateTabs()),
        if (_error != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: _inlineError(theme, _error!, () => _loadCandidates()),
            ),
          ),
        gap,
        if (salesTab) ...[
          SliverToBoxAdapter(child: _candidateSearchBar()),
          if (_loadingCandidates)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(top: UtenSpacing.s8),
                child: LinearProgressIndicator(),
              ),
            ),
          gap,
          if (lines.isEmpty)
            const SliverToBoxAdapter(
              child: UtenEmpty(message: '暂无可分析的已审销售订单产品'),
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
            gap,
            SliverToBoxAdapter(child: _compactSelectedSourceSummary(theme)),
          ],
        ] else ...[
          SliverToBoxAdapter(child: _manualDemandIntro(theme)),
          gap,
          for (final card in _manualDemandCards(compact: true))
            SliverToBoxAdapter(child: card),
          if (_canManage) ...[
            const SliverToBoxAdapter(child: SizedBox(height: UtenSpacing.s12)),
            SliverToBoxAdapter(child: _addManualDemandButton(expanded: true)),
          ],
        ],
        const SliverToBoxAdapter(
          child: SizedBox(height: UtenFloatingActionGroup.scrollClearance),
        ),
      ],
    );
  }

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
                        decoration: UtenInputDecoration(
                          InputDecoration(
                            label: fieldLabel(
                              _selectedCandidateLabels[entry.key] ?? '所选产品',
                              Theme.of(sheetContext),
                              info: '本次分析数量',
                            ),
                          ),
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

  @override
  bool _normalizeNewWarehouseScope() {
    final names = ref.read(masterNameServiceProvider);
    final preferred = _warehouseRootOf(_warehouseId);
    final root =
        (preferred?.status == '禁用' ? null : preferred) ??
        names.warehouseHierarchy
            .where(
              (entry) =>
                  (entry.parentId == null || entry.parentId!.isEmpty) &&
                  entry.status != '禁用',
            )
            .firstOrNull;
    if (root == null) return false;
    // New planning requests name the main warehouse. The server resolves stock scope.
    _warehouseId = root.id;
    _warehouseIds
      ..clear()
      ..add(root.id);
    return true;
  }

  WarehouseDictEntry? _warehouseRootOf(String? warehouseId) =>
      ref.read(masterNameServiceProvider).mainWarehouseOf(warehouseId);

  Widget _warehouseField() {
    final hierarchy = ref.watch(masterNameServiceProvider).warehouseHierarchy;
    final roots = hierarchy
        .where((entry) => entry.parentId == null || entry.parentId!.isEmpty)
        .toList();
    final root = _warehouseRootOf(_warehouseId);
    return Row(
      key: const Key('material-analysis-warehouse'),
      children: [
        Expanded(
          child: UtenDropdownField(
            key: ValueKey('material-analysis-main-warehouse-${root?.id}'),
            value: root?.id,
            label: _l10n.materialMainWarehouse,
            allowClear: false,
            info: _l10n.materialWarehouseScopeExplanation,
            enabled: !_busy && _canManage && roots.isNotEmpty,
            items: [
              for (final entry in roots)
                if (entry.status != '禁用' || entry.id == root?.id)
                  UtenDropdownItem(
                    value: entry.id,
                    label: entry.name,
                    enabled: entry.status != '禁用',
                  ),
            ],
            onChanged: (value) {
              // Displaying an old leaf-backed analysis must not rewrite its identity.
              if (value == null || value == root?.id) return;
              _applyWarehouseSelection(value, {value});
            },
          ),
        ),
      ],
    );
  }

  List<MasterColumnDef<MaterialAnalysisSalesCandidateLine>>
  get _candidateColumns => [
    MasterColumnDef(
      key: 'orderNo',
      label: '销售单号',
      width: 150,
      // 2026-09-25 单号列统一：可排序（服务端白名单 orderNo）+ 值筛选（facets）。
      sortable: true,
      value: (line) => line.orderNo,
    ),
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
    MasterColumnDef(
      key: 'goodsName',
      label: '产品名称',
      width: 200,
      value: (line) => line.goodsName,
    ),
    MasterColumnDef(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      value: (line) => line.goodsCode,
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '颜色',
      width: 96,
      value: (line) => line.colorName,
    ),
    MasterColumnDef(
      key: 'spec',
      label: '规格',
      width: 150,
      value: (line) => line.spec,
    ),
    MasterColumnDef(
      key: 'remainingQty',
      label: '待排数量',
      width: 110,
      type: 'number',
      value: (line) => _qty(line.remainingQty),
    ),
    // ADR-130：勾选即出现本次分析数量输入框(默认 = 待排数量)，只改例外；
    // 取代原先表格下方单独一块「已选产品」数量列表。
    MasterColumnDef(
      key: 'analysisQty',
      label: '本次分析数量',
      width: 136,
      type: 'number',
      info: '勾选后默认等于待排数量，只需改要分析的例外数量',
      value: (line) => _sourceQtyControllers[line.salesOrderItemId]?.text,
      cellBuilder: (context, line) {
        final controller = _sourceQtyControllers[line.salesOrderItemId];
        if (controller == null) {
          return Text(
            '—',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
        }
        // 必填红框与提交校验同一口径(空 / 非数字 / 不大于 0 都算没填好)：
        // 红框出现的时候，点「联合分析」一定会被拦下。
        return RequiredCellFrame(
          listenable: controller,
          isEmpty: () => _positiveAnalysisQty(controller.text) == null,
          child: TextField(
            key: Key('source-qty-${line.salesOrderItemId}'),
            controller: controller,
            enabled: !_busy,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: const UtenInputDecoration(
              InputDecoration(
                isDense: true,
                hintText: '0',
                // 收紧到与纯文本行同高：勾选/取消时整行不跳高。
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
              ),
            ),
          ),
        );
      },
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

  /// 顶部卡片「手工需求」区块(ADR-130)：按(来源类型, 需求编号)分组的只读 chip，
  /// 如「返工 · RW-001 · 3 个货品」，悬停看来源原因。与「关联销售订单」并列，
  /// 让计划员一眼看出这张分析里有哪些手工需求单。
  List<Widget> _manualDemandsSection(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
    final demands = _manualDemandSummaries(analysis);
    if (demands.isEmpty) return const [];
    final refCounts = <String, int>{};
    for (final demand in demands) {
      final ref = demand.sourceRef.toLowerCase();
      refCounts[ref] = (refCounts[ref] ?? 0) + 1;
    }
    // 编号多时默认只露前几个，其余点开再看：顶部卡片不能被几十个 chip 撑高，
    // 把下面的任务入口和主表挤出首屏。
    const chipLimit = 6;
    final folded = !_manualDemandsExpanded && demands.length > chipLimit;
    final visible = folded ? demands.take(chipLimit) : demands;
    return [
      const SizedBox(height: UtenSpacing.s8),
      Align(
        key: const Key('material-analysis-manual-demands'),
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: UtenSpacing.s4),
              child: Text(
                '手工需求 ${demands.length}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            for (final demand in visible)
              ConstrainedBox(
                // 与销售订单 chip 同一护栏：硬封宽 + 省略号，窄屏靠 Wrap 换行。
                constraints: const BoxConstraints(maxWidth: 300),
                child: Tooltip(
                  message: demand.reasons.isEmpty
                      ? '需求编号 ${demand.sourceRef}'
                      : '来源原因：${demand.reasons.join('；')}',
                  child: Chip(
                    // 同一编号挂在两种来源类型下时带上类型，保证 key 唯一。
                    key: ValueKey(
                      (refCounts[demand.sourceRef.toLowerCase()] ?? 0) > 1
                          ? 'analysis-manual-demand-${demand.sourceRef}-${demand.sourceType}'
                          : 'analysis-manual-demand-${demand.sourceRef}',
                    ),
                    avatar: Icon(
                      Icons.assignment_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    label: Text(
                      '${materialManualDemandSourceTypes[demand.sourceType]} · '
                      '${demand.sourceRef} · ${demand.goods.length} 个货品',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            if (demands.length > chipLimit)
              TextButton(
                key: const Key('material-analysis-manual-demands-toggle'),
                onPressed: () => setState(
                  () => _manualDemandsExpanded = !_manualDemandsExpanded,
                ),
                child: Text(
                  folded ? '展开其余 ${demands.length - chipLimit} 个' : '收起',
                ),
              ),
          ],
        ),
      ),
    ];
  }

  /// 来源行按(来源类型, 需求编号)分组；排序按来源类型固定顺序再按编号，保证稳定。
  List<_ManualDemandSummary> _manualDemandSummaries(
    ProductionMaterialAnalysisView analysis,
  ) {
    final groups = <String, _ManualDemandSummary>{};
    for (final product in analysis.products) {
      final sourceType = product.sourceType;
      if (sourceType == null ||
          !materialManualDemandSourceTypes.containsKey(sourceType)) {
        continue;
      }
      final sourceRef = product.sourceRef?.trim();
      if (sourceRef == null || sourceRef.isEmpty) continue;
      final summary = groups.putIfAbsent(
        '$sourceType|${sourceRef.toLowerCase()}',
        () => _ManualDemandSummary(sourceType, sourceRef),
      );
      summary.goods.add(
        '${product.goodsId}|${product.colorId}|${product.unitId}',
      );
      final reason = product.sourceReason?.trim();
      if (reason != null &&
          reason.isNotEmpty &&
          !summary.reasons.contains(reason)) {
        summary.reasons.add(reason);
      }
    }
    final typeOrder = materialManualDemandSourceTypes.keys.toList();
    return groups.values.toList()..sort((left, right) {
      final byType = typeOrder
          .indexOf(left.sourceType)
          .compareTo(typeOrder.indexOf(right.sourceType));
      return byType != 0 ? byType : left.sourceRef.compareTo(right.sourceRef);
    });
  }
}
