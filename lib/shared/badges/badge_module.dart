// 徽章的容器划分 —— 一个 [BadgeModule] 对应工作台上的一张模块卡 / 一个 hub。
//
// 与服务端 WorkbenchBadgeCatalog.Module 逐字一致(ADR-108): 容器之和由服务端算好随
// GET /api/workbench/badges 带回, 前端只按容器取数, 不做加法。
// 红黄两条链共用这一份容器划分: 同一张卡右上角并排两枚徽章(黄左红右)。
// 见 docs/00-项目准则/14-徽章与计数口径.md。

/// 徽章容器: 一个 [BadgeModule] 对应工作台上的一张模块卡 / 一个 hub。
enum BadgeModule {
  /// 人事与访客(我的访客 / 访客审批 / 信息变更审核 / HR 任务中心 / 我的报销)。
  people,

  /// 钱流管理 hub。
  finance,

  /// 生产管理(计划员视角: 待排产 / 进行中批次 / 生产草稿)。
  production,

  /// 我的车间任务(车间工视角, 工作台单独一张卡, 与生产管理卡分开计)。
  workshop,

  /// 工程研发部任务中心。
  rd,

  /// 仓库管理 hub(三张方向任务中心 + 品质部检查结果 + 仓库草稿)。
  warehouse,

  /// 采购管理 hub。
  purchase,

  /// 委外管理 hub。
  subcontract,

  /// 品质任务中心。
  quality,

  /// 销售管理 hub。
  sales,

  /// 系统管理（服务器状态告警）。
  system,
}
