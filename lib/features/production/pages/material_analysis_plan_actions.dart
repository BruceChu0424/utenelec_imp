part of 'production_material_analysis_page.dart';

abstract class _MaterialAnalysisPlanActionsState
    extends _MaterialAnalysisSupplyActionsState {
  Future<bool> _previewPlan(List<MaterialAnalysisPlanItemInput> items) async {
    final analysis = _analysis;
    final warehouseId = _warehouseId;
    if (analysis == null || warehouseId == null || _previewingPlan) {
      return false;
    }
    if (!_canGenerate) return false;
    if (_dirtyRouteGroups.isNotEmpty) {
      context.appWarning('请先确认物料路线');
      return false;
    }
    setState(() {
      _previewingPlan = true;
      _planPreview = null;
    });
    try {
      final preview = await ref
          .read(productionPlanRepositoryProvider)
          .previewMaterialAnalysisPlan(
            analysis: analysis,
            warehouseId: warehouseId,
            items: items,
          );
      if (!mounted) return false;
      setState(() {
        _previewingPlan = false;
        _planPreview = preview;
      });
      if (!preview.canSchedule) {
        context.appWarning('计划预览发现不可排产批次，请按行内原因调整数量');
        return false;
      }
      if (preview.allReady) {
        context.appSuccess('计划预览通过，所选批次物料已齐套');
      } else {
        context.appInfo('计划预览通过；缺料批次将以待料状态下达，不占用零散库存');
      }
      return true;
    } catch (error) {
      if (!mounted) return false;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '生产计划预览',
      )) {
        if (!mounted) return false;
        setState(() => _previewingPlan = false);
        return false;
      }
      if (!mounted) return false;
      setState(() => _previewingPlan = false);
      context.appError(
        productionErrorMessage(error, fallback: '计划预览失败，请刷新分析后重试'),
        force: true,
      );
      return false;
    }
  }

  Future<void> _generatePlan(
    List<MaterialAnalysisPlanItemInput> items, {
    bool approveNow = false,
  }) async {
    final preview = _planPreview;
    final warehouseId = _warehouseId;
    if (preview == null || warehouseId == null || _generating) return;
    if (!preview.canSchedule) {
      context.appWarning('计划预览未通过，不能生成生产计划');
      return;
    }
    final key = businessIdempotencyKey(
      'material-analysis-generate-plan',
      [
        preview.analysisId,
        preview.version,
        preview.previewFingerprint,
        _dateText(_billDate),
        _dateText(_deliveryDate),
        approveNow,
        for (final item in items) item.toJson().toString(),
      ].join('|'),
    );
    setState(() => _generating = true);
    try {
      final result = await ref
          .read(productionPlanRepositoryProvider)
          .generateMaterialAnalysisPlan(
            preview: preview,
            warehouseId: warehouseId,
            idempotencyKey: key,
            billDate: _dateText(_billDate)!,
            deliveryDate: _dateText(_deliveryDate),
            departmentId: widget.seed.departmentId,
            workshopName: widget.seed.workshopName,
            workerId: widget.seed.workerId,
            approveNow: approveNow,
            items: items,
          );
      if (!mounted) return;
      setState(() {
        _generating = false;
        _applyAnalysis(result.analysis);
        // The submitted quantities are now persisted business facts. Clear
        // only those drafts so a later planning round receives a fresh
        // complete-kit-first suggestion; unrelated hand-entered rows remain.
        for (final item in items) {
          _batchQtyControllers[item.analysisLineId]?.clear();
          _systemSeededBatchQtyTexts.remove(item.analysisLineId);
        }
      });
      context.appSuccess(
        approveNow
            ? preview.allReady
                  ? '生产计划已审核下达，物料提货单已生成'
                  : _previewHasPartialReadySplit(preview)
                  ? '生产计划已审核下达并拆批；齐套部分已生成提货单，余量继续待料'
                  : '生产计划已审核下达并分配车间；当前待料，齐套后才生成提货单'
            : '生产计划已生成并提交审批',
      );
      await _showGeneratedPlans(result.plans);
    } catch (error) {
      if (!mounted) return;
      if (await _recoverLatestAnalysisAfterConflict(
        error,
        operation: '生成生产计划',
      )) {
        if (!mounted) return;
        setState(() => _generating = false);
        return;
      }
      if (!mounted) return;
      setState(() {
        _generating = false;
        _planPreview = null;
      });
      context.appError(
        productionErrorMessage(error, fallback: '库存或分析状态已变化，请重新计划预览'),
        force: true,
      );
    }
  }

  /// 打开可深链恢复的备料计划汇总单；当前视图只作为首帧快照，
  /// 硬刷新时汇总页按 analysisId 重新读取权威详情。
  Future<void> _openSummarySheet() async {
    final analysis = _analysis;
    if (analysis == null) return;
    await context.push(
      RoutePath.productionMaterialAnalysisSummary(analysis.analysisId),
      extra: analysis,
    );
  }

  /// 生成结果对话框：把「生产计划单 + 物料提货单（领料单）」摆在同一屏。
  /// - 已审核下达（approveNow）：列出随计划包自动生成的提货单，可直接打开；
  /// - 待审核：明说下一步——审核并正式下达后系统自动出提货单，仓库按单发料。
  bool _isGeneratedPlanPrintable(ProductionGeneratedPlanRef plan) =>
      plan.planId.trim().isNotEmpty &&
      plan.status?.trim().toUpperCase() == 'APPROVED' &&
      plan.packageId?.trim().isNotEmpty == true;

  Future<void> _openGeneratedPlansPrint(
    List<ProductionGeneratedPlanRef> plans,
  ) async {
    if (plans.isEmpty ||
        plans.any((plan) => !_isGeneratedPlanPrintable(plan))) {
      context.appWarning('批量打印只接受已审核且已有确认计划包的生产计划');
      return;
    }
    final repo = ref.read(productionPlanRepositoryProvider);
    await showProductionExecutionCardBatchPrintPreview(
      context,
      loader: () async {
        final views = <ProductionWorkCardView>[];
        for (
          var start = 0;
          start < plans.length;
          start += _MaterialAnalysisPageBase._maxConcurrentPrintLoads
        ) {
          final group = plans.sublist(
            start,
            (start + _MaterialAnalysisPageBase._maxConcurrentPrintLoads)
                .clamp(0, plans.length)
                .toInt(),
          );
          final loaded = await Future.wait([
            for (final plan in group)
              () async {
                try {
                  return await repo.productionWorkCards(
                    plan.planId,
                    plan.packageId!.trim(),
                  );
                } on ApiException catch (error) {
                  throw ApiException(
                    error.code,
                    '生产计划 ${plan.planNo ?? plan.planId}：${error.message}',
                    fieldErrors: error.fieldErrors,
                  );
                }
              }(),
          ]);
          views.addAll(loaded);
        }
        return views;
      },
    );
  }

  Future<void> _openGeneratedPlanPrint(ProductionGeneratedPlanRef plan) =>
      _openGeneratedPlansPrint([plan]);

  Future<void> _handleGeneratedPlanDialogAction(
    _GeneratedPlanDialogAction action,
  ) async {
    switch (action.type) {
      case _GeneratedPlanDialogActionType.view:
        await context.push(RoutePath.productionPlanDetail(action.plan!.planId));
        return;
      case _GeneratedPlanDialogActionType.printOne:
        await _openGeneratedPlanPrint(action.plan!);
        return;
      case _GeneratedPlanDialogActionType.printAll:
        await _openGeneratedPlansPrint(action.plans);
        return;
    }
  }

  Future<void> _showGeneratedPlans(
    List<ProductionGeneratedPlanRef> plans,
  ) async {
    final valid = plans.where((plan) => plan.planId.isNotEmpty).toList();
    if (valid.isEmpty || !mounted) return;
    final printablePlans = valid
        .where(_isGeneratedPlanPrintable)
        .toList(growable: false);
    if (valid.length == 1) {
      final action = await showDialog<_GeneratedPlanDialogAction>(
        context: context,
        builder: (dialogContext) {
          final plan = valid.single;
          final approved = plan.status == 'APPROVED';
          final printable = _isGeneratedPlanPrintable(plan);
          return AlertDialog(
            title: Text(
              approved && plan.drawDocuments.isNotEmpty
                  ? '计划单与提货单已生成'
                  : approved
                  ? '生产计划已审核下达'
                  : '生产计划已生成',
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.assignment_turned_in_outlined),
                    title: Text('生产计划单 ${plan.planNo ?? plan.planId}'),
                    subtitle: Text(approved ? '已审核下达' : '待审核'),
                  ),
                  if (plan.drawDocuments.isNotEmpty) ...[
                    const Divider(height: UtenSpacing.s16),
                    for (final draw in plan.drawDocuments)
                      ListTile(
                        key: ValueKey('generated-draw-${draw.drawId}'),
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.outbound_outlined),
                        title: Text('物料提货单(领料单)${draw.billNo ?? ''}'),
                        subtitle: const Text('仓库按单发料 · 点击打开'),
                        onTap: () {
                          Navigator.pop(dialogContext);
                          context.push(
                            RoutePath.stockDocDetail('DRAW', draw.drawId),
                          );
                        },
                      ),
                  ] else ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      approved
                          ? '本批没有下层领用物料，不生成领料单；'
                                '计划审核后可直接报工，再进入 FQC 与完工入库。'
                          : '计划审核并正式下达后，系统自动生成物料提货单(领料单)，'
                                '仓库按单出库后标记备料完毕，车间可直接报工；'
                                '可在「生产计划详情」查看进度。',
                      style: Theme.of(dialogContext).textTheme.bodyMedium
                          ?.copyWith(
                            color: Theme.of(
                              dialogContext,
                            ).colorScheme.onSurfaceVariant,
                            height: 1.45,
                          ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('留在物料分析'),
              ),
              if (printable)
                OutlinedButton.icon(
                  key: ValueKey('generated-plan-print-${plan.planId}'),
                  onPressed: () => Navigator.pop(
                    dialogContext,
                    _GeneratedPlanDialogAction.print(plan),
                  ),
                  icon: const Icon(Icons.print_outlined, size: 18),
                  label: const Text('打印生产计划单'),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _GeneratedPlanDialogAction.view(plan),
                ),
                child: const Text('查看计划'),
              ),
            ],
          );
        },
      );
      if (!mounted || action == null) return;
      await _handleGeneratedPlanDialogAction(action);
      return;
    }
    final pendingCount = valid
        .where((plan) => plan.status != 'APPROVED')
        .length;
    final missingPackageCount = valid
        .where(
          (plan) =>
              plan.status == 'APPROVED' &&
              plan.packageId?.trim().isNotEmpty != true,
        )
        .length;
    final printBatches = <List<ProductionGeneratedPlanRef>>[
      for (
        var start = 0;
        start < printablePlans.length;
        start += _MaterialAnalysisPageBase._maxPlansPerPrintJob
      )
        printablePlans.sublist(
          start,
          (start + _MaterialAnalysisPageBase._maxPlansPerPrintJob)
              .clamp(0, printablePlans.length)
              .toInt(),
        ),
    ];
    while (true) {
      if (!mounted) return;
      final action = await showDialog<_GeneratedPlanDialogAction>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('已生成生产计划'),
          children: [
            for (final plan in valid)
              ListTile(
                key: ValueKey('generated-plan-row-${plan.planId}'),
                onTap: () => Navigator.pop(
                  dialogContext,
                  _GeneratedPlanDialogAction.view(plan),
                ),
                leading: const Icon(Icons.assignment_turned_in_outlined),
                title: Text(plan.planNo ?? plan.planId),
                subtitle: Text(
                  plan.status == 'APPROVED'
                      ? plan.drawDocuments.isNotEmpty
                            ? '已审核下达 · 提货单 ${plan.drawDocuments.length} 张'
                            : '已审核下达 · 本批无需领料'
                      : '待审核 · 审核下达后按需生成提货单',
                ),
                trailing:
                    plan.status == 'APPROVED' &&
                        plan.packageId?.trim().isNotEmpty == true
                    ? IconButton(
                        key: ValueKey('generated-plan-print-${plan.planId}'),
                        tooltip: '打印生产计划单',
                        onPressed: () => Navigator.pop(
                          dialogContext,
                          _GeneratedPlanDialogAction.print(plan),
                        ),
                        icon: const Icon(Icons.print_outlined),
                      )
                    : const Icon(Icons.chevron_right_rounded),
              ),
            if (printablePlans.length >= 2)
              Padding(
                key: const Key('generated-plans-print-batch-section'),
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s16,
                  UtenSpacing.s8,
                  UtenSpacing.s16,
                  UtenSpacing.s12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '批量打印 · 每次最多 $_MaterialAnalysisPageBase._maxPlansPerPrintJob 张计划',
                      style: Theme.of(dialogContext).textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    for (
                      var batchIndex = 0;
                      batchIndex < printBatches.length;
                      batchIndex++
                    ) ...[
                      UtenButton(
                        key: printBatches.length == 1
                            ? const Key('generated-plans-print-all')
                            : ValueKey(
                                'generated-plans-print-batch-$batchIndex',
                              ),
                        type: UtenButtonType.tonal,
                        icon: Icons.print_outlined,
                        onPressed: () => Navigator.pop(
                          dialogContext,
                          _GeneratedPlanDialogAction.printAll(
                            printBatches[batchIndex],
                          ),
                        ),
                        child: Text(
                          printBatches.length == 1
                              ? '打印全部已审核计划（${printablePlans.length}）'
                              : '打印第 '
                                    '${batchIndex * _MaterialAnalysisPageBase._maxPlansPerPrintJob + 1}-'
                                    '${batchIndex * _MaterialAnalysisPageBase._maxPlansPerPrintJob + printBatches[batchIndex].length} '
                                    '张已审核计划',
                        ),
                      ),
                      if (batchIndex < printBatches.length - 1)
                        const SizedBox(height: UtenSpacing.s8),
                    ],
                    if (pendingCount > 0 || missingPackageCount > 0) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      Text(
                        [
                          '仅合并已审核且已有确认计划包的计划',
                          if (pendingCount > 0) '$pendingCount 张待审核不包含',
                          if (missingPackageCount > 0)
                            '$missingPackageCount 张缺确认包不包含',
                        ].join('；'),
                        style: Theme.of(dialogContext).textTheme.bodySmall
                            ?.copyWith(
                              color: Theme.of(
                                dialogContext,
                              ).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext),
              child: const ListTile(
                leading: Icon(Icons.arrow_back_rounded),
                title: Text('留在物料分析'),
              ),
            ),
          ],
        ),
      );
      if (!mounted || action == null) return;
      await _handleGeneratedPlanDialogAction(action);
      if (action.type == _GeneratedPlanDialogActionType.view) return;
      // Printing closes its own preview back to this persistent result list so
      // a second 50-plan group or another individual plan remains reachable.
    }
  }

  /// 底部悬浮动作区的按钮集合（按需出现，见 §3.5）。
  /// 2026-09-04 改版：采购/委外/自制的批量下达与生成生产计划入口移入顶部
  /// 分桶详情页；本页悬浮区只保留路线类动作（采纳建议/确认路线）。
  /// 可点击的主动作统一 danger（红底白字）——出现在悬浮区即表示当前有
  /// 可执行的下一步，用最强的视觉权重把员工视线引到唯一动作上；
  /// 置灰/加载态由 UtenButton 自行呈现。
  List<Widget> _bottomActionButtons() {
    if (_isFqcReplenishmentOnly) return const <Widget>[];
    return <Widget>[
      if (_canRoute && _unconfirmedSuggestedRouteCount > 0)
        UtenButton(
          key: const Key('material-analysis-accept-routes'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          isLoading: _savingRoutes,
          onPressed: _busy ? null : _acceptAllSuggestedRoutes,
          child: Text('采纳建议路线($_unconfirmedSuggestedRouteCount)'),
        ),
      if (_dirtyRouteGroups.isNotEmpty)
        UtenButton(
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: Icons.rule_folder_outlined,
          isLoading: _savingRoutes,
          onPressed: !_canRoute || _busy ? null : _saveRoutes,
          child: Text('确认路线(${_dirtyRouteGroups.length})'),
        ),
    ];
  }

  /// 右下角悬浮动作区：背景透明、不占布局空间（原来是一条白色吸底栏，
  /// 会挡住后面的卡片内容）。按钮各自带悬浮阴影，宽屏横排、窄屏竖排靠右。
  Widget? _floatingActions() {
    final buttons = _bottomActionButtons();
    if (buttons.isEmpty) return null;
    return UtenFloatingActionGroup(children: buttons);
  }

  Widget _planPreviewCard(
    ThemeData theme,
    ProductionMaterialPlanPreview preview,
  ) {
    final hasPartialSplit = _previewHasPartialReadySplit(preview);
    final color = !preview.canSchedule
        ? theme.colorScheme.error
        : preview.allReady
        ? theme.colorScheme.primary
        : theme.colorScheme.tertiary;
    return Container(
      key: const Key('material-analysis-plan-preview-result'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _statusLabel(
            theme,
            _StatusView(
              !preview.canSchedule
                  ? '计划预览不可提交'
                  : preview.allReady
                  ? '可排产 · 物料已齐套'
                  : hasPartialSplit
                  ? '可排产 · 将拆可开工批与待料批'
                  : '可排产 · 当前待料',
              !preview.canSchedule
                  ? Icons.gpp_maybe_outlined
                  : preview.allReady
                  ? Icons.verified_outlined
                  : Icons.hourglass_top_rounded,
              color,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          for (final item in preview.items)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
              child: Row(
                children: [
                  Icon(
                    !item.canSchedule
                        ? Icons.error_outline
                        : item.materialReady
                        ? Icons.check_circle_outline
                        : _previewItemHasPartialReadySplit(item)
                        ? Icons.call_split_rounded
                        : Icons.hourglass_top_rounded,
                    size: 18,
                    color: !item.canSchedule
                        ? theme.colorScheme.error
                        : item.materialReady
                        ? theme.colorScheme.primary
                        : theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: UtenSpacing.s4),
                  Expanded(
                    child: Text(
                      '批次 ${item.analysisLineId}：选择 ${_qty(item.selectedQty)} · '
                      '可排产上限 ${_qty(item.maxSchedulableQty)} · '
                      '当前齐套 ${_qty(item.readyNowQty)} · '
                      '${_previewItemDisposition(item)}'
                      '${item.materialReadinessReason == null ? '' : ' · ${item.materialReadinessReason}'}'
                      '${item.scheduleBlockedReason == null ? '' : ' · ${item.scheduleBlockedReason}'}',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  bool _previewHasPartialReadySplit(ProductionMaterialPlanPreview preview) =>
      preview.items.any(_previewItemHasPartialReadySplit);

  bool _previewItemHasPartialReadySplit(
    ProductionMaterialPlanPreviewItem item,
  ) =>
      item.canSchedule &&
      item.readyNowQty > 0 &&
      item.selectedQty > item.readyNowQty;

  String _previewItemDisposition(ProductionMaterialPlanPreviewItem item) {
    if (item.materialReady) return '生成 READY';
    if (_previewItemHasPartialReadySplit(item)) {
      return '拆分 READY ${_qty(item.readyNowQty)} + '
          'WAITING ${_qty(item.selectedQty - item.readyNowQty)}';
    }
    return '生成 WAITING(待料)';
  }
}

enum _GeneratedPlanDialogActionType { view, printOne, printAll }

class _GeneratedPlanDialogAction {
  const _GeneratedPlanDialogAction.view(this.plan)
    : type = _GeneratedPlanDialogActionType.view,
      plans = const [];

  const _GeneratedPlanDialogAction.print(this.plan)
    : type = _GeneratedPlanDialogActionType.printOne,
      plans = const [];

  _GeneratedPlanDialogAction.printAll(List<ProductionGeneratedPlanRef> plans)
    : type = _GeneratedPlanDialogActionType.printAll,
      plan = null,
      plans = List.unmodifiable(plans);

  final _GeneratedPlanDialogActionType type;
  final ProductionGeneratedPlanRef? plan;
  final List<ProductionGeneratedPlanRef> plans;
}
