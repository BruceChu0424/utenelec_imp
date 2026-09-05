part of 'production_material_analysis_page.dart';

/// V458 委外件「先自制、后通知委外」账本投影。
///
/// 2026-09-03 收口：不再在分区下方渲染独立「委外件前置自制」区块；2026-09-04
/// 分桶改版后产品卡与卡内「通知委外」面板一并退役——前置自制任务的账本与分批
/// 通知统一由委外准备中心（productionSubcontractPreparations）承载，BOM 树
/// 原委外节点仍内联进度。本文件只保留继承链占位。
abstract class _MaterialAnalysisSubcontractMakeState
    extends _MaterialAnalysisMaterialTableState {}
