part of 'production_material_analysis_page.dart';

/// V458 委外件「先自制、后通知委外」账本投影。
///
/// 有子层级的委外件在「下达委外」后不出本页：前置自制任务与本节展示的
/// produced/notified/available 数量都来自服务端权威账本；满批自动通知由
/// 服务端在成品入库事务内完成，本节的手动「通知委外」只负责分批场景。
final _subcontractMakeTasksProvider = FutureProvider.autoDispose
    .family<PagedResult<SubcontractMakeTask>, String>((ref, analysisId) {
      return ref
          .watch(productionPlanRepositoryProvider)
          .subcontractMakeTasks(analysisId: analysisId, size: 50);
    });

abstract class _MaterialAnalysisSubcontractMakeState
    extends _MaterialAnalysisBorrowState {
  bool get _canNotifySubcontractMake =>
      _permissions.contains(Perm.productionMaterialAnalysisNotify);

  Widget _subcontractMakeSection(
    ThemeData theme,
    ProductionMaterialAnalysisView analysis,
  ) {
    final tasksAsync = ref.watch(
      _subcontractMakeTasksProvider(analysis.analysisId),
    );
    return tasksAsync.maybeWhen(
      data: (page) {
        if (page.items.isEmpty) return const SizedBox.shrink();
        return Container(
          key: const Key('material-analysis-subcontract-make'),
          padding: const EdgeInsets.all(UtenSpacing.s12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: UtenRadius.mdAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.precision_manufacturing_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Text(
                    '委外件前置自制',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Tooltip(
                    message:
                        '有子层级的委外件先走自制：成品入库后满批自动通知委外部；'
                        '未满批可按「可通知量」分批通知。委外申请生成前委外部不参与。',
                    child: Icon(
                      Icons.info_outline,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              for (final task in page.items)
                SubcontractMakeTaskTile(
                  task: task,
                  canNotify: _canNotifySubcontractMake,
                  onNotified: () {
                    ref.invalidate(
                      _subcontractMakeTasksProvider(analysis.analysisId),
                    );
                    _reloadAnalysisSilently(protectUnsavedEditing: true);
                  },
                ),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}
