import 'package:flutter/material.dart';

import '../../components/data_display/uten_status_badge.dart';
import '../../core/l10n/gen/app_localizations.dart';

/// AI 识别结果的把握程度(服务端 `confidenceLevel`: HIGH / MEDIUM / LOW)。
///
/// 面向业务人员只分三档, 不显示分数。
enum AiConfidence {
  high,
  medium,
  low;

  /// 不认识的值返回 null(调用方不显示药丸即可)。
  static AiConfidence? parse(Object? raw) =>
      switch ('${raw ?? ''}'.trim().toUpperCase()) {
        'HIGH' => AiConfidence.high,
        'MEDIUM' => AiConfidence.medium,
        'LOW' => AiConfidence.low,
        _ => null,
      };
}

/// 把握程度药丸: 高 = 绿、中 = 琥珀、低 = 红(语义色 token, 自动适配深色模式)。
///
/// 颜色不是唯一表达: 同时有文字「把握高/中/低」与图标。
class AiConfidencePill extends StatelessWidget {
  const AiConfidencePill({
    super.key,
    required this.confidence,
    this.size = UtenStatusBadgeSize.small,
  });

  final AiConfidence confidence;
  final UtenStatusBadgeSize size;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (label, type, icon) = switch (confidence) {
      AiConfidence.high => (
        l10n.aiJobConfidenceHigh,
        UtenStatusBadgeType.success,
        Icons.check_circle_rounded,
      ),
      AiConfidence.medium => (
        l10n.aiJobConfidenceMedium,
        UtenStatusBadgeType.warning,
        Icons.help_rounded,
      ),
      AiConfidence.low => (
        l10n.aiJobConfidenceLow,
        UtenStatusBadgeType.danger,
        Icons.error_rounded,
      ),
    };
    return Semantics(
      label: l10n.aiJobConfidenceSemantics(label),
      child: ExcludeSemantics(
        child: UtenStatusBadge(
          label: label,
          type: type,
          icon: icon,
          size: size,
        ),
      ),
    );
  }
}
