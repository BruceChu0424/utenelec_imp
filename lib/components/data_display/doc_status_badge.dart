// DocStatusBadge - 单据 0/1/-1 状态机 → UtenStatusBadge 语义类型
// 文档：docs/02-组件库/DocStatusBadge.md
//
// 生产计划/生产日报/财务单据/销售单据/委外单据/采购单据共用同一套状态码
// （草稿 0 / 已审 1 / 红冲 -1）。列表页状态列统一用 UtenStatusBadge（small）
// 渲染：草稿中性灰、已审成功绿、红冲危险红；`MasterColumnDef.value` 仍保留
// 纯文本供列宽/排序/筛选桶/无障碍使用，徽章只是 cellBuilder 的展示层。
//
// 基础资料主档的「使用/停用」不走本映射（不是审批态，保持文本）。

import 'uten_status_badge.dart';

/// 单据通用状态码 → 徽章语义类型。未知/空码按中性处理（列表里通常显示「—」）。
///
/// 常量定义在各域模型（`kProductionStatusDraft` 等），值一致（0/1/-1）；本组件
/// 不依赖 feature 层，直接按值映射。
UtenStatusBadgeType docStatusBadgeType(int? code) => switch (code) {
  1 => UtenStatusBadgeType.success,
  -1 => UtenStatusBadgeType.danger,
  _ => UtenStatusBadgeType.neutral,
};
