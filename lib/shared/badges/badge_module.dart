// 徽章的容器划分 —— 一个 [BadgeModule] 对应工作台上的一张模块卡 / 一个 hub。
//
// 两张注册表共用这一份容器划分, 所以它单独成文件, 不属于其中任何一张:
//   · lib/shared/badges/todo_badge_registry.dart      红色「待办」累加(轮到我动手)
//   · lib/shared/badges/in_progress_badge_registry.dart 黄色「进行中」累加(已在办、没完)
//
// 两条链各自求和、互不相干: 同一张卡右上角并排两枚徽章(黄左红右), 数字分别来自
// 两张表。见 docs/00-项目准则/14-徽章与计数口径.md。
//
// 2026-09-21 从 todo_badge_registry.dart 抽出并改名(原 `TodoModule`): 加了黄色那条链
// 之后, 容器划分不再只服务「待办」, 名字里带 Todo 会让人以为黄色不能用它。

/// 徽章容器: 一个 [BadgeModule] 对应工作台上的一张模块卡 / 一个 hub。
enum BadgeModule {
  /// 人事与访客（我的访客 / 访客审批 / 信息变更审核 / HR 任务中心）。
  people,

  /// 钱流管理 hub。
  finance,

  /// 生产管理（生产调度 + 我的车间任务）。
  production,

  /// 工程研发部任务中心。
  rd,

  /// 仓库管理 hub（三张方向任务中心 + 品质部检查结果）。
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
