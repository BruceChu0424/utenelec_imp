// 车间内料仓界面文案与数字格式 (ADR-131)。
//
// 面向员工的文案一律傻瓜化中文, 不出现代号、表名、英文标识; 括号一律半角。
// 服务端状态码只在这里翻成中文, 页面不直接显示状态码。
import '../../../../components/data_display/uten_status_badge.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../shared/formatters/quantity_display.dart';
import '../models/workshop_material_models.dart';

/// 数量显示: 最多 [maxDecimals] 位小数, 去掉末尾的 0。（实现升位 shared/formatters。）
String wmQty(num? value, {int maxDecimals = 2}) =>
    formatQty(value, maxDecimals: maxDecimals);

/// 输入框文本 → 数量; 空或非法为 null。
double? wmParseQty(String text) => parseQty(text);

/// 期间显示名: 第 N 期 (起 至 止)。
String wmPeriodLabel(WmPeriod period) {
  final end = period.endDate;
  final range = end == null || end.isEmpty
      ? '${period.startDate} 起'
      : '${period.startDate} 至 $end';
  return period.periodNo > 0 ? '第 ${period.periodNo} 期 ($range)' : range;
}

String wmPeriodStatusLabel(String status) => switch (status) {
  WmPeriodStatus.open => '开着',
  WmPeriodStatus.counting => '盘点中',
  WmPeriodStatus.counted => '已盘点, 待结算',
  WmPeriodStatus.closed => '已结算',
  _ => '',
};

/// 期间状态 → 档位（ADR-169）：开着=绿（正常运转、可发料可盘点，本页的
/// 「就绪」档）/ 盘点中=蓝（正在执行）/ 已盘点待结算=黄（等自动结算，无异常）/
/// 已结算=灰——结算是封存的历史终态而非「成功办结的工作项」，且开着已占绿档，
/// 同页撞色会让两种最常见的期间状态分不清（2026-10-08 口径）。
UtenStatusBadgeType wmPeriodStatusBadgeType(String status) => switch (status) {
  WmPeriodStatus.open => UtenStatusBadgeType.success,
  WmPeriodStatus.counting => UtenStatusBadgeType.info,
  WmPeriodStatus.counted => UtenStatusBadgeType.warning,
  _ => UtenStatusBadgeType.neutral,
};

String wmCloseStateLabel(String closeState) => switch (closeState) {
  WmCloseState.queued => '系统正在自动结算',
  WmCloseState.blocked => '差资料, 暂时结不了账',
  WmCloseState.held => '已撤销结算, 暂停自动结算',
  WmCloseState.failed => '结算没成功, 系统会自动再试',
  _ => '',
};

String wmRequisitionKindLabel(AppLocalizations l10n, String kind) =>
    kind == 'RETURN' ? l10n.wmReturn : l10n.wmRequestIssue;

String wmRequisitionStatusLabel(String status) => switch (status) {
  'PENDING' => '待处理',
  'DONE' => '已完成',
  'CANCELLED' => '已取消',
  _ => '',
};

/// 领料/退回单状态 → 档位（ADR-169 逐页独立口径）。
///
/// [taskView] = 任务视角（待发料 / 待收退回分段）：PENDING 是「轮到仓库动手」
/// 的就绪单 → 绿灯；记录 / 历史视角里 PENDING 与 DONE 同现，取琥珀（挂起等
/// 仓库处理）与绿（已完成）、灰（已取消）区分——同一状态在不同视角可取不同档。
UtenStatusBadgeType wmRequisitionStatusBadgeType(
  String status, {
  bool taskView = false,
}) => switch (status) {
  'PENDING' =>
    taskView ? UtenStatusBadgeType.success : UtenStatusBadgeType.warning,
  'DONE' => UtenStatusBadgeType.success,
  _ => UtenStatusBadgeType.neutral,
};

/// 结算状态 → 档位（ADR-169）：自动结算中=蓝（正在执行）/ 差资料暂时结不了账
/// =红（硬阻断——资料不齐锁住不能结算，2026-10-08 用户口径「不能执行/锁住=深红」，
/// 同 ADR-169 委外等物料齐套案例）/ 结算没成功=红（失败）/ 已撤销暂停=灰。
/// null = 期间开着没有结算状态, 不上色。
UtenStatusBadgeType? wmCloseStateBadgeType(String closeState) =>
    switch (closeState) {
      WmCloseState.queued => UtenStatusBadgeType.info,
      WmCloseState.blocked => UtenStatusBadgeType.danger,
      WmCloseState.failed => UtenStatusBadgeType.danger,
      WmCloseState.held => UtenStatusBadgeType.neutral,
      _ => null,
    };

String wmRequisitionOriginLabel(String? origin) => switch (origin) {
  'WAREHOUSE_DIRECT' => '仓库直接发料',
  'WORKSHOP_REQUEST' => '车间申请',
  _ => '',
};

String wmCostBasisLabel(AppLocalizations l10n, String? basis) =>
    switch (basis) {
      'OWN' => l10n.wmCostBasisOwn,
      'SHARED' => l10n.wmCostBasisShared,
      'EXPENSE' => l10n.wmCostBasisExpense,
      _ => '',
    };

/// 其它耗用原因 (服务端码 → 文案)。
const wmOtherIssueReasons = <String>[
  'TRIAL_MOULD',
  'PURGE',
  'SCRAP_MATERIAL',
  'OTHER',
];

String wmOtherIssueReasonLabel(AppLocalizations l10n, String reason) =>
    switch (reason) {
      'TRIAL_MOULD' => l10n.wmOtherReasonTrial,
      'PURGE' => l10n.wmOtherReasonPurge,
      'SCRAP_MATERIAL' => l10n.wmOtherReasonScrap,
      _ => l10n.wmOtherReasonOther,
    };

String wmFillLevelLabel(AppLocalizations l10n, String? level) =>
    switch (level) {
      WmFillLevel.full => l10n.wmFillFull,
      WmFillLevel.half => l10n.wmFillHalf,
      WmFillLevel.empty => l10n.wmFillEmpty,
      WmFillLevel.weighed => l10n.wmFillWeighed,
      _ => '',
    };

String wmWeighNoteLabel(AppLocalizations l10n, String? note) => switch (note) {
  WmWeighNote.openBag => l10n.wmWeighOpenBag,
  WmWeighNote.mixed => l10n.wmWeighMixed,
  WmWeighNote.loose => l10n.wmWeighLoose,
  _ => l10n.wmFillWeighed,
};

/// 一项结算拦截的说明 (差什么 + 谁来补 + 前几个样例)。
String wmBlockerText(AppLocalizations l10n, WmBlocker blocker) {
  String withSamples(String head, String sampleLabel) {
    if (blocker.samples.isEmpty) return head;
    final more = blocker.count > blocker.samples.length ? ' 等' : '';
    return '$head\n$sampleLabel: ${blocker.samples.join('、')}$more';
  }

  return switch (blocker.kind) {
    'PREVIOUS_PERIOD_OPEN' => l10n.wmCloseWaitingPrevious,
    'DRAFT_REPORT' => withSamples(
      l10n.wmCloseBlockedReport(blocker.count),
      '报工单号',
    ),
    'MISSING_WEIGHT' => withSamples(
      l10n.wmCloseBlockedWeight(blocker.count),
      '产品',
    ),
    'THEORY_WITHOUT_STOCK' =>
      blocker.samples.isEmpty
          ? l10n.wmCloseBlockedStock('${blocker.count} 种料')
          : blocker.samples.map(l10n.wmCloseBlockedStock).join('\n'),
    _ => '还有 ${blocker.count} 项资料没补齐, 补完后系统会自动结算',
  };
}
