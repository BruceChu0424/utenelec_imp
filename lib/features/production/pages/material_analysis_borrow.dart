part of 'production_material_analysis_page.dart';

abstract class _MaterialAnalysisBorrowState
    extends _MaterialAnalysisBomTreeState {
  // ===== 现货层借用（调货） =====
  //
  // 同一分析内把某条直接组件路径已分配的现货覆盖量调给另一产品的同物料
  // 路径。只改分析软分配与齐套投影；服务端逐笔留痕（谁、多少、从哪到哪、
  // 原因、时间），借出/借入双方行上都可见，正式下达前可撤销。

  /// 借用双向徽标：借出方显示"已被调走 · 调给 X"，借入方显示"已调入 ·
  /// 来自 Y"。生效数为 0 时显示"暂未生效"，避免把申请量当成已调量。
  @override
  Widget _borrowBadges(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material, {
    required bool selected,
  }) {
    if (material.borrowRefs.isEmpty && material.crossReallocationRefs.isEmpty) {
      return const SizedBox.shrink();
    }
    final chips = <Widget>[];
    for (final ref in material.borrowRefs) {
      final inbound = ref.isInbound;
      final effective = ref.qty > 0;
      final color = selected
          ? theme.colorScheme.onPrimary
          : !effective
          ? theme.colorScheme.onSurfaceVariant
          : inbound
          ? theme.colorScheme.primary
          : theme.colorScheme.tertiary;
      final label = !effective
          ? '调拨申请 ${_qty(ref.requestedQty)} 件暂未生效'
          : inbound
          ? '已调入 ${_qty(ref.qty)} 件 · 来自 ${ref.counterpartProduct ?? '其它产品'}'
          : '已被调走 ${_qty(ref.qty)} 件 · 调给 ${ref.counterpartProduct ?? '其它产品'}';
      chips.add(
        Semantics(
          label: label,
          child: Container(
            key: ValueKey(
              'material-borrow-ref-${ref.direction}-${material.materialLineId}-${ref.borrowId}',
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s8,
              vertical: UtenSpacing.s4,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: effective ? 0.12 : 0.07),
              borderRadius: UtenRadius.smAll,
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  inbound
                      ? Icons.call_received_rounded
                      : Icons.call_made_rounded,
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
        ),
      );
    }
    for (final allocation in material.crossReallocationRefs) {
      final inbound = allocation.isInbound;
      final label = _crossReallocationChipLabel(allocation);
      final color = selected
          ? theme.colorScheme.onPrimary
          : inbound
          ? theme.colorScheme.primary
          : theme.colorScheme.tertiary;
      chips.add(
        Semantics(
          label: label,
          child: Container(
            key: ValueKey(
              'material-cross-reallocation-ref-${allocation.direction}-'
              '${material.materialLineId}-${allocation.id}',
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s8,
              vertical: UtenSpacing.s4,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: UtenRadius.smAll,
              border: Border.all(color: color.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  inbound
                      ? Icons.move_to_inbox_outlined
                      : Icons.outbox_outlined,
                  size: 16,
                  color: color,
                ),
                const SizedBox(width: UtenSpacing.s4),
                Flexible(
                  child: Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
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

  /// 跨计划让料复用同一物料维度预检，但不受分析内借用的“已下达”门禁限制：
  /// 服务端会以两份分析的当前快照和精确 entitlement 再次校验。
  bool _canCrossReallocateOut(ProductionMaterialAnalysisMaterial material) {
    if (!_canCrossReallocate || _busy) return false;
    if (material.level != 1) return false;
    if (material.requiredQty <= 0 || material.allocatedAvailableQty <= 0) {
      return false;
    }
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
      context.appInfo('当前分析内没有其它产品缺这种料；可使用“跨计划让料”查找其它分析');
      return;
    }
    final indexes = _analysisIndexes(analysis);
    final request = await showDialog<MaterialBorrowRequestDraft>(
      context: context,
      builder: (_) => MaterialBorrowDialog(
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

  Future<void> _showCrossReallocationDialog(
    ProductionMaterialAnalysisMaterial material,
  ) async {
    final analysis = _analysis;
    if (analysis == null || !_canCrossReallocateOut(material)) return;
    final indexes = _analysisIndexes(analysis);
    final product = indexes.productsById[material.analysisLineId];
    final productLabel = product?.goodsName?.trim().isNotEmpty == true
        ? product!.goodsName!.trim()
        : product?.goodsCode?.trim().isNotEmpty == true
        ? product!.goodsCode!.trim()
        : product?.sourceRef?.trim().isNotEmpty == true
        ? product!.sourceRef!.trim()
        : '当前计划产品';
    setState(() => _borrowing = true);
    try {
      final view = await showMaterialReallocationDialog(
        context: context,
        repository: ref.read(productionPlanRepositoryProvider),
        sourceAnalysis: analysis,
        sourceMaterial: material,
        sourceProductLabel: productLabel,
        sourcePathLabel: _pathLabel(material),
        qtyText: _qty,
        onSourceRebased: (latest) {
          if (!mounted) return;
          setState(() => _applyAnalysis(latest));
        },
      );
      if (!mounted) return;
      setState(() {
        _borrowing = false;
        if (view != null) _applyAnalysis(view);
      });
      if (view != null) {
        context.appSuccess('跨计划让料已生效；本计划已标记优先待补，接受计划无需返还');
      }
    } finally {
      if (mounted && _borrowing) setState(() => _borrowing = false);
    }
  }

  Future<void> _submitBorrow(
    ProductionMaterialAnalysisMaterial from,
    MaterialBorrowRequestDraft request,
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
      builder: (_) => const MaterialRequiredReasonDialog(
        title: '撤销这笔借用',
        fieldKey: Key('borrow-revoke-reason'),
        initialValue: '',
        helperMessage: '撤销后借出方恢复分配、借入方重新出现缺口。请填写撤销原因。',
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

  Future<void> _revokeCrossReallocation(
    MaterialCrossReallocationRef allocation,
  ) async {
    final analysis = _analysis;
    if (analysis == null || !_canCrossReallocate || _busy) return;
    final counterpartVersion = allocation.counterpartVersion;
    final counterpartFingerprint = allocation.counterpartFingerprint;
    if (counterpartVersion == null ||
        counterpartVersion <= 0 ||
        counterpartFingerprint?.isNotEmpty != true) {
      context.appInfo('缺少接受计划的最新版本信息，请刷新物料分析后重试');
      return;
    }
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const MaterialRequiredReasonDialog(
        title: '撤销跨计划让料',
        fieldKey: Key('cross-reallocation-revoke-reason'),
        initialValue: '',
        helperMessage: '撤销会重新计算两份计划的物料覆盖。请填写业务原因。',
        confirmLabel: '确认撤销',
      ),
    );
    if (reason == null || !mounted) return;

    final currentIsSource = allocation.isOutbound;
    final sourceAnalysisId = currentIsSource
        ? analysis.analysisId
        : allocation.counterpartAnalysisId;
    final sourceVersion = currentIsSource
        ? analysis.version
        : counterpartVersion;
    final sourceFingerprint = currentIsSource
        ? analysis.fingerprint
        : counterpartFingerprint!;
    final targetAnalysisId = currentIsSource
        ? allocation.counterpartAnalysisId
        : analysis.analysisId;
    final targetVersion = currentIsSource
        ? counterpartVersion
        : analysis.version;
    final targetFingerprint = currentIsSource
        ? counterpartFingerprint!
        : analysis.fingerprint;
    final key = businessIdempotencyKey(
      'material-analysis-cross-reallocation-revoke',
      [
        sourceAnalysisId,
        sourceVersion,
        sourceFingerprint,
        targetAnalysisId,
        targetVersion,
        targetFingerprint,
        allocation.id,
        reason,
      ].join('|'),
    );

    setState(() => _borrowing = true);
    try {
      final sourceView = await ref
          .read(productionPlanRepositoryProvider)
          .revokeMaterialCrossReallocation(
            sourceAnalysisId: sourceAnalysisId,
            sourceVersion: sourceVersion,
            sourceFingerprint: sourceFingerprint,
            targetAnalysisId: targetAnalysisId,
            targetVersion: targetVersion,
            targetFingerprint: targetFingerprint,
            crossReallocationId: allocation.id,
            reason: reason,
            idempotencyKey: key,
          );
      if (!mounted) return;
      final currentView = currentIsSource
          ? sourceView
          : await ref
                .read(productionPlanRepositoryProvider)
                .materialAnalysisDetail(analysis.analysisId);
      if (!mounted) return;
      setState(() {
        _borrowing = false;
        _applyAnalysis(currentView);
      });
      context.appSuccess('跨计划让料已撤销，两份计划的物料覆盖已重新计算');
    } catch (error) {
      if (!mounted) return;
      setState(() => _borrowing = false);
      context.appError(
        productionErrorMessage(error, fallback: '撤销跨计划让料失败，请刷新后重试'),
        force: true,
      );
    }
  }

  String _crossReallocationCounterpart(
    MaterialCrossReallocationRef allocation,
  ) {
    final label = allocation.counterpartLabel?.trim();
    if (label?.isNotEmpty == true) return label!;
    final product = allocation.counterpartProduct?.trim();
    return product?.isNotEmpty == true ? product! : '其它计划';
  }

  String _crossReallocationChipLabel(MaterialCrossReallocationRef allocation) {
    final counterpart = _crossReallocationCounterpart(allocation);
    if (allocation.isReversed) {
      return '跨计划让料已撤销 · 权益已恢复 · $counterpart';
    }
    if (allocation.isCancelled) {
      if (allocation.currentEffectiveQty > 0) {
        return allocation.isInbound
            ? '关系已关闭 · 当前仍保留 ${_qty(allocation.currentEffectiveQty)} 件 · 来自 $counterpart'
            : '关系已关闭 · 对方仍保留 ${_qty(allocation.currentEffectiveQty)} 件 · 给 $counterpart';
      }
      return '关系已关闭 · 当前权益已释放 · $counterpart';
    }
    if (allocation.isInbound) {
      return '已接受 ${_qty(allocation.qty)} 件 · 来自 $counterpart · 无需返还';
    }
    if (allocation.priorityOpenQty > 0) {
      return '已让料 ${_qty(allocation.qty)} 件 · 给 $counterpart · '
          '优先待补 ${_qty(allocation.priorityOpenQty)} 件';
    }
    if (allocation.priorityFulfilledQty > 0) {
      return '已让料 ${_qty(allocation.qty)} 件 · 给 $counterpart · '
          '已优先补齐 ${_qty(allocation.priorityFulfilledQty)} 件';
    }
    return '已让料 ${_qty(allocation.qty)} 件 · 给 $counterpart';
  }

  String _crossReallocationHeadline(MaterialCrossReallocationRef allocation) {
    final counterpart = _crossReallocationCounterpart(allocation);
    if (allocation.isReversed) return '跨计划让料已撤销 · 权益已恢复';
    if (allocation.isCancelled) {
      if (allocation.currentEffectiveQty <= 0) {
        return '让料关系已关闭 · 当前权益已释放';
      }
      return allocation.isInbound
          ? '让料关系已关闭 · 当前保留 ${_qty(allocation.currentEffectiveQty)} 件 · 来自 $counterpart'
          : '让料关系已关闭 · $counterpart 仍保留 ${_qty(allocation.currentEffectiveQty)} 件';
    }
    return allocation.isInbound
        ? '已接受 ${_qty(allocation.qty)} 件 · 来自 $counterpart'
        : '已让料 ${_qty(allocation.qty)} 件 · 接受计划 $counterpart';
  }

  String _crossReallocationExplanation(
    MaterialCrossReallocationRef allocation,
  ) {
    if (allocation.isReversed) {
      return '本次让料已撤销；双方当前权益已按事件恢复。';
    }
    if (allocation.isCancelled) {
      if (allocation.currentEffectiveQty <= 0) {
        return '当前受益切片已释放；记录仅保留用于审计。';
      }
      return allocation.isInbound
          ? '来源分析已取消；仍有效的受益切片继续保留给本计划。'
          : '关系已关闭；仍有效的受益切片继续保留给接受计划。';
    }
    if (allocation.isInbound) {
      return '接受计划无需返还；来源计划保留原始需求。';
    }
    if (allocation.priorityOpenQty > 0) {
      return '优先待补 ${_qty(allocation.priorityOpenQty)} 件'
          '${allocation.priorityFulfilledQty > 0 ? ' · 已优先补齐 ${_qty(allocation.priorityFulfilledQty)} 件' : ''}';
    }
    if (allocation.priorityFulfilledQty > 0) {
      return '已优先补齐 ${_qty(allocation.priorityFulfilledQty)} 件';
    }
    return '后续本计划来源的合格入库会优先补本计划。';
  }

  /// 节点详情内的借用区：逐笔借用明细（可撤销）+ 调出入口。
  @override
  Widget _nodeBorrowSection(
    ThemeData theme,
    ProductionMaterialAnalysisMaterial material,
  ) {
    final refs = material.borrowRefs;
    final crossRefs = material.crossReallocationRefs;
    final canBorrowOut = _canBorrowOut(material);
    final canCrossReallocateOut = _canCrossReallocateOut(material);
    if (refs.isEmpty &&
        crossRefs.isEmpty &&
        !canBorrowOut &&
        !canCrossReallocateOut) {
      return const SizedBox.shrink();
    }
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
                      size: UtenButtonSize.large,
                      type: UtenButtonType.ghost,
                      icon: Icons.undo_rounded,
                      onPressed: _busy ? null : () => _revokeBorrow(ref),
                      child: const Text('撤销'),
                    ),
                ],
              ),
            ),
          for (final allocation in crossRefs)
            Container(
              key: ValueKey(
                'material-cross-reallocation-detail-${allocation.id}',
              ),
              margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
              padding: const EdgeInsets.all(UtenSpacing.s8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: UtenRadius.smAll,
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _crossReallocationHeadline(allocation),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    _crossReallocationExplanation(allocation),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (allocation.reason?.trim().isNotEmpty == true) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Text('业务原因：${allocation.reason}'),
                  ],
                  if (allocation.isOutbound &&
                      allocation.replenishmentRefs.isNotEmpty) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      '补齐来源',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    for (final replenishment in allocation.replenishmentRefs)
                      Text('• ${replenishment.displayLabel}'),
                  ],
                  const SizedBox(height: UtenSpacing.s8),
                  if (_canCrossReallocate && allocation.canRevoke)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: UtenButton(
                        key: ValueKey(
                          'material-cross-reallocation-revoke-${allocation.id}',
                        ),
                        size: UtenButtonSize.large,
                        type: UtenButtonType.ghost,
                        icon: Icons.undo_rounded,
                        onPressed: _busy
                            ? null
                            : () => _revokeCrossReallocation(allocation),
                        child: const Text('撤销跨计划让料'),
                      ),
                    )
                  else if (!allocation.canRevoke)
                    Semantics(
                      label:
                          '当前不可撤销：'
                          '${allocation.revokeBlockedReason ?? '当前业务阶段已锁定'}',
                      child: Text(
                        '不可撤销：'
                        '${allocation.revokeBlockedReason ?? '当前业务阶段已锁定'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    Text(
                      '当前账号无撤销权限',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          if (canBorrowOut || canCrossReallocateOut)
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                if (canBorrowOut)
                  UtenButton(
                    key: ValueKey(
                      'material-borrow-start-${material.materialLineId}',
                    ),
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.swap_horiz_rounded,
                    onPressed: _busy ? null : () => _showBorrowDialog(material),
                    child: const Text('分析内调给产品'),
                  ),
                if (canCrossReallocateOut)
                  UtenButton(
                    key: ValueKey(
                      'material-cross-reallocation-start-${material.materialLineId}',
                    ),
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.compare_arrows_rounded,
                    onPressed: _busy
                        ? null
                        : () => _showCrossReallocationDialog(material),
                    child: const Text('跨计划让料'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
