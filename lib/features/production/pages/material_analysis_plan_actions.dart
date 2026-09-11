part of 'production_material_analysis_page.dart';

abstract class _MaterialAnalysisPlanActionsState
    extends _MaterialAnalysisSupplyActionsState {
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

  /// The table owns its floating action in both normal and fullscreen views.
  /// 悬浮区动作 = 选择三件套（见 material_table 的
  /// [_MaterialAnalysisMaterialTableState._materialTableSelectionActions]：
  /// 全选筛选结果 + 路线说明）+ 确认路线(N)。
  List<Widget> _bottomActionButtons() {
    if (_isFqcReplenishmentOnly || !_canRoute) return const [];
    return [
      UtenButton(
        key: const Key('material-analysis-create-routes'),
        size: UtenButtonSize.large,
        type: UtenButtonType.danger,
        icon: Icons.alt_route_rounded,
        isLoading: _savingRoutes,
        onPressed: _busy || _loadingRouteMemory || _selectedRouteCount == 0
            ? null
            : _createSelectedRoutes,
        child: Text(_l10n.materialCreateRoutes(_selectedRouteCount)),
      ),
    ];
  }

  Widget? _floatingActions() => null;
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
