import 'package:intl/intl.dart';
// 访客申请状态 → UI（文案/徽章/颜色/图标）映射，访客端与审批/保安端共用。
import 'package:flutter/material.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/visitor_application.dart';

String visitorStatusLabel(VisitorApplicationStatus s, AppLocalizations l10n) => switch (s) {
      VisitorApplicationStatus.pending => l10n.visitorStatusPending,
      VisitorApplicationStatus.hostReviewing => l10n.visitorStatusHostReviewing,
      VisitorApplicationStatus.approved => l10n.visitorStatusApproved,
      VisitorApplicationStatus.rejected => l10n.visitorStatusRejected,
      VisitorApplicationStatus.checkedIn => l10n.visitorStatusCheckedIn,
      VisitorApplicationStatus.cancelled => l10n.visitorStatusCancelled,
    };

UtenStatusBadgeType visitorBadgeType(VisitorApplicationStatus s) => switch (s) {
      VisitorApplicationStatus.pending => UtenStatusBadgeType.warning,
      VisitorApplicationStatus.hostReviewing => UtenStatusBadgeType.info,
      VisitorApplicationStatus.approved => UtenStatusBadgeType.success,
      VisitorApplicationStatus.rejected => UtenStatusBadgeType.danger,
      VisitorApplicationStatus.checkedIn => UtenStatusBadgeType.accent,
      VisitorApplicationStatus.cancelled => UtenStatusBadgeType.neutral,
    };

Color visitorStatusColor(VisitorApplicationStatus s) => switch (s) {
      VisitorApplicationStatus.pending => UtenColors.warning,
      VisitorApplicationStatus.hostReviewing => UtenColors.info,
      VisitorApplicationStatus.approved => UtenColors.success,
      VisitorApplicationStatus.rejected => UtenColors.error,
      VisitorApplicationStatus.checkedIn => UtenColors.teal600,
      VisitorApplicationStatus.cancelled => UtenColors.slate500,
    };

IconData visitorStatusIcon(VisitorApplicationStatus s) => switch (s) {
      VisitorApplicationStatus.pending => Icons.hourglass_top_rounded,
      VisitorApplicationStatus.hostReviewing => Icons.person_search_rounded,
      VisitorApplicationStatus.approved => Icons.check_circle_rounded,
      VisitorApplicationStatus.rejected => Icons.cancel_rounded,
      VisitorApplicationStatus.checkedIn => Icons.login_rounded,
      VisitorApplicationStatus.cancelled => Icons.block_rounded,
    };

/// 格式化日期时间（I-5：走 intl，按 locale 输出）。
/// 调用方传 `Localizations.localeOf(context).languageCode`；不传默认 'zh'。
String fmtDateTime(DateTime d, [String locale = 'zh']) {
  try {
    return DateFormat.yMd(locale).add_Hm().format(d);
  } catch (_) {
    // locale 数据未初始化时降级为 ISO 格式
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
