part of 'production_material_analysis_page.dart';

/// V458 委外件「先自制、后通知委外」账本投影。
///
/// 2026-09-03 收口：不再在分区下方渲染独立「委外件前置自制」区块（与自制
/// 子件割裂、且和产品卡重复显示）。前置自制任务与 MAKE 完全同构——子件以
/// 真实产品卡出现在「生产准备任务」分区，produced/notified/available 数量
/// 与「通知委外」分批入口内嵌在该卡上；BOM 树也不新增第二个根，进度内联在
/// 原委外节点。本文件只保留数据源与卡内面板。
final _subcontractMakeTasksProvider = FutureProvider.autoDispose
    .family<PagedResult<SubcontractMakeTask>, String>((ref, analysisId) {
      return ref
          .watch(productionPlanRepositoryProvider)
          .subcontractMakeTasks(analysisId: analysisId, size: 50);
    });

abstract class _MaterialAnalysisSubcontractMakeState
    extends _MaterialAnalysisBorrowState {
  // 面板实现位于继承链更上游的 material_analysis_product_tasks.dart
  // （_subcontractMakeTaskPanel），本层只保留链路占位。
}
