import 'package:intl/intl.dart';
// 访客申请状态 → UI（文案/徽章/颜色/图标）映射，访客端与审批/保安端共用。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/data_display/uten_status_cell_color.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/utils/china_datetime.dart';
import '../models/visitor_application.dart';

String visitorStatusLabel(VisitorApplicationStatus s, AppLocalizations l10n) =>
    switch (s) {
      VisitorApplicationStatus.pending => l10n.visitorStatusPending,
      VisitorApplicationStatus.hostReviewing => l10n.visitorStatusHostReviewing,
      VisitorApplicationStatus.approved => l10n.visitorStatusApproved,
      VisitorApplicationStatus.rejected => l10n.visitorStatusRejected,
      VisitorApplicationStatus.checkedIn => l10n.visitorStatusCheckedIn,
      VisitorApplicationStatus.cancelled => l10n.visitorStatusCancelled,
    };

/// 状态 → 档位（ADR-169 锚定，访客端/审批端共用一份，两端同状态同色）：
/// 申请中=黄（等审批的排队，无异常；「轮到我审」由分段红数表达，绿会误读为
/// 已通过） · 待接待人确认=蓝（已流转到接待人环节、正在处理） · 已批准=绿
/// （通过=放行，对申请人就是「可以来访」的绿灯） · 已拒绝=红（驳回族，对申请
/// 人是否定结果，与中性终态「已取消」区分） · 已签到=青绿（来访进行中，
/// accent 档，与通过绿拉开） · 已取消=灰（中性终态）。
UtenStatusBadgeType visitorBadgeType(VisitorApplicationStatus s) => switch (s) {
  VisitorApplicationStatus.pending => UtenStatusBadgeType.warning,
  VisitorApplicationStatus.hostReviewing => UtenStatusBadgeType.info,
  VisitorApplicationStatus.approved => UtenStatusBadgeType.success,
  VisitorApplicationStatus.rejected => UtenStatusBadgeType.danger,
  VisitorApplicationStatus.checkedIn => UtenStatusBadgeType.accent,
  VisitorApplicationStatus.cancelled => UtenStatusBadgeType.neutral,
};

/// 状态图标底色/前景：与 [visitorBadgeType] 同一档位实底（ADR-169 状态
/// 实底色板），不再使用控件级 success/warning/error 浅色组。
Color visitorStatusColor(VisitorApplicationStatus s) =>
    resolveStatusBadgeColors(visitorBadgeType(s)).$1;

IconData visitorStatusIcon(VisitorApplicationStatus s) => switch (s) {
  VisitorApplicationStatus.pending => Icons.hourglass_top_rounded,
  VisitorApplicationStatus.hostReviewing => Icons.person_search_rounded,
  VisitorApplicationStatus.approved => Icons.check_circle_rounded,
  VisitorApplicationStatus.rejected => Icons.cancel_rounded,
  VisitorApplicationStatus.checkedIn => Icons.login_rounded,
  VisitorApplicationStatus.cancelled => Icons.block_rounded,
};

/// 按北京时间格式化真实时间点并带「（北京）」后缀，默认使用中国大陆区域规则。
String fmtDateTime(DateTime d, [String locale = 'zh_CN']) {
  final chinaTime = d.isUtc
      ? ChinaDateTime.fromInstant(d)
      : ChinaDateTime.asWallTime(d);
  try {
    return '${DateFormat.yMd(locale).add_Hm().format(chinaTime)}(北京)';
  } catch (_) {
    // locale 数据未初始化时降级为 ISO 格式
    return '${ChinaDateTime.formatDateTime(chinaTime)}(北京)';
  }
}
