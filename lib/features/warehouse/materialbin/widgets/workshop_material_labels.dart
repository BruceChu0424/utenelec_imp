// 车间内料仓界面文案与数字格式 (ADR-131)。
//
// 面向员工的文案一律傻瓜化中文, 不出现代号、表名、英文标识; 括号一律半角。
// 服务端状态码只在这里翻成中文, 页面不直接显示状态码。
import '../../../../core/l10n/gen/app_localizations.dart';
import '../models/workshop_material_models.dart';

/// 数量显示: 最多 [maxDecimals] 位小数, 去掉末尾的 0。
String wmQty(num? value, {int maxDecimals = 2}) {
  if (value == null) return '';
  var text = value.toStringAsFixed(maxDecimals);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  }
  return text == '-0' ? '0' : text;
}

/// 输入框文本 → 数量; 空或非法为 null。
double? wmParseQty(String text) {
  final raw = text.trim().replaceAll(',', '');
  if (raw.isEmpty) return null;
  return double.tryParse(raw);
}

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
