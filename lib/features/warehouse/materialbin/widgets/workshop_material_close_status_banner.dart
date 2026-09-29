// 车间内料仓顶部"盘点 / 结算状态"提示 (ADR-131 §5.8)。
//
// 只有三种情况拦结算 (未审报工、缺单个重量、有理论没进过料), 这里把"差什么、谁来补"
// 写成员工看得懂的话; 撤销结算后的 24 小时保留、连续失败改为每天重试也在这里说明。
// "立即重试 / 重新结算"按钮只在服务端下发 CLOSE_RETRY 时出现。
import 'package:flutter/material.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_inline_notice.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/utils/china_datetime.dart';
import '../models/workshop_material_models.dart';
import 'workshop_material_labels.dart';

class WmCloseStatusBanner extends StatelessWidget {
  const WmCloseStatusBanner({
    super.key,
    required this.status,
    this.periodLabel,
    this.onRetry,
    this.retrying = false,
  });

  final WmCloseStatus status;

  /// 这条状态说的是哪一期 (第 N 期 (起 至 止))。
  final String? periodLabel;

  /// 立即重试 / 重新结算; 为空或服务端没给 CLOSE_RETRY 时不显示按钮。
  final VoidCallback? onRetry;
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = status;
    final title = periodLabel == null || periodLabel!.isEmpty
        ? l10n.wmCloseState
        : '${l10n.wmCloseState}: $periodLabel';

    Widget? retryButton(String label) {
      if (onRetry == null || !s.can(WmAction.closeRetry)) return null;
      return UtenButton(
        key: const Key('wm-close-retry'),
        type: UtenButtonType.tonal,
        size: UtenButtonSize.small,
        isLoading: retrying,
        onPressed: retrying ? null : onRetry,
        child: Text(label),
      );
    }

    UtenInlineNotice notice(
      String message, {
      UtenInlineNoticeLevel level = UtenInlineNoticeLevel.info,
      Widget? trailing,
    }) => UtenInlineNotice(
      key: const Key('wm-close-status-banner'),
      level: level,
      title: title,
      message: message,
      trailing: trailing,
    );

    switch (s.status) {
      case WmPeriodStatus.counting:
        return notice('正在盘点。盘完点"${l10n.wmSubmitCount}", 系统会自动结算。');
      case WmPeriodStatus.closed:
        final last = s.lastClose;
        final when = ChinaDateTime.formatIsoInstant(last?.closedAt);
        final who = last?.closedByName;
        return notice(
          [
            '这一期已经结算。',
            if (when.isNotEmpty) '结算时间: $when',
            if (who != null && who.isNotEmpty) '经办: $who',
          ].join(' '),
        );
      case WmPeriodStatus.counted:
        break;
      default:
        return const SizedBox.shrink();
    }

    switch (s.closeState) {
      case WmCloseState.queued:
        return notice('已盘点, 系统正在自动结算, 稍等片刻就好。');
      case WmCloseState.blocked:
        final lines = [for (final b in s.blockers) wmBlockerText(l10n, b)];
        return notice(
          lines.isEmpty
              ? wmCloseStateLabel(WmCloseState.blocked)
              : '${lines.join('\n')}\n补完后系统会自动结算。',
          level: UtenInlineNoticeLevel.warning,
          trailing: retryButton(l10n.wmCloseRetry),
        );
      case WmCloseState.held:
        final time = ChinaDateTime.formatIsoInstant(s.heldUntil);
        return notice(
          l10n.wmReopenHeld(time.isEmpty ? '24 小时后' : time),
          level: UtenInlineNoticeLevel.warning,
          trailing: retryButton(l10n.wmSettleAgain),
        );
      case WmCloseState.failed:
        final reason = s.lastErrorMessage;
        final head = s.failures >= 3 ? l10n.wmCloseFailing : '结算没成功, 系统会自动再试。';
        return notice(
          reason == null || reason.isEmpty ? head : '$head\n原因: $reason',
          level: UtenInlineNoticeLevel.error,
          trailing: retryButton(l10n.wmCloseRetry),
        );
      default:
        return notice('已盘点, 等待结算。', trailing: retryButton(l10n.wmCloseRetry));
    }
  }
}
