part of 'production_material_analysis_page.dart';

abstract class _MaterialAnalysisCandidatesState
    extends _MaterialAnalysisPageBase {
  /// 候选搜索：防抖由 UtenSearchBar 内置（300ms），停止输入后再检索。
  void _searchCandidates(String value) {
    _candidateKeyword = value.trim();
    _loadCandidates(page: 1);
  }

  bool _candidateSelected(MaterialAnalysisSalesCandidateLine line) =>
      _sourceQtyControllers.containsKey(line.salesOrderItemId);

  int get _selectedAnalysisSourceCount =>
      _sourceQtyControllers.length + _manualSources.length;

  int get _remainingSalesSourceSlots =>
      (_MaterialAnalysisPageBase._maxAnalysisItems - _manualSources.length)
          .clamp(0, _MaterialAnalysisPageBase._maxAnalysisItems);

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
    if (result.length > _MaterialAnalysisPageBase._maxAnalysisItems) {
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
        _selectedAnalysisSourceCount >=
            _MaterialAnalysisPageBase._maxAnalysisItems) {
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
            warehouseIds: warehouseIds,
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
                      for (final entry
                          in _MaterialAnalysisPageBase
                              ._manualSourceTypes
                              .entries)
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
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        label: fieldLabel(
                          '需求编号',
                          theme,
                          required: true,
                          info: '同一需求请始终使用同一个编号',
                        ),
                        hintText: '例：RW-20260808-001',
                      ),
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
                    '${_MaterialAnalysisPageBase._manualSourceTypes[source.sourceType] ?? source.sourceType} · '
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
        child: UtenSearchBar(
          controller: _candidateSearch,
          hint: '搜索销售单号或货品',
          onChanged: _searchCandidates,
        ),
      ),
      SizedBox(width: 260, child: _warehouseField()),
    ],
  );

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
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        label: fieldLabel(
                          _selectedCandidateLabels[entry.key] ?? '所选产品',
                          theme,
                          info: '本次分析数量',
                        ),
                      ),
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
}
