// 登录庆典弹窗（生日/周年/新婚/新生儿）。每日一次由 dashboard 的 CelebrationPopupGate 守卫。
// 文档：docs/00-项目准则/06-动画规范.md（粒子循环按性能档关闭；控制器 dispose）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/effects/celebration_particles.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/performance/performance_tier.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/performance_provider.dart';
import '../models/notice.dart';
import 'celebration_mascot.dart';

/// 弹出登录庆典弹窗。[celebration] 取自 myCelebrationTodayProvider 的一条。
Future<void> showCelebrationLoginDialog(
  BuildContext context,
  WidgetRef ref,
  MyCelebrationToday celebration,
) {
  return showDialog(
    context: context,
    builder: (_) => _CelebrationLoginDialog(celebration: celebration),
  );
}

class _CelebrationLoginDialog extends ConsumerWidget {
  const _CelebrationLoginDialog({required this.celebration});

  final MyCelebrationToday celebration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tier = ref.watch(performanceProvider);
    final accent = celebration.type.color;
    final lines = _message(l10n, celebration).split('\n');

    return Dialog(
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s24,
        vertical: UtenSpacing.s24,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          UtenSpacing.s20,
          UtenSpacing.s20,
          UtenSpacing.s20,
          UtenSpacing.s16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 200,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(
                    child: CelebrationParticleField(animated: !tier.isLite),
                  ),
                  CelebrationMascot(type: celebration.type, size: 150),
                ],
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            if (lines.isNotEmpty)
              Text(
                lines.first,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: accent,
                ),
              ),
            if (lines.length > 1) ...[
              const SizedBox(height: UtenSpacing.s4),
              Text(
                lines.last,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
            ],
            const SizedBox(height: UtenSpacing.s20),
            UtenButton(
              isExpanded: true,
              onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
              child: Text(l10n.celebrationDismiss),
            ),
          ],
        ),
      ),
    );
  }

  String _message(AppLocalizations l10n, MyCelebrationToday c) => switch (c.type) {
    NoticeType.birthday =>
      l10n.celebrationPopupBirthday(c.subjectName),
    NoticeType.anniversary =>
      l10n.celebrationPopupAnniversary(c.subjectName, c.eventLabel),
    NoticeType.wedding =>
      l10n.celebrationPopupWedding(c.subjectName),
    NoticeType.newborn =>
      l10n.celebrationPopupNewborn(c.subjectName),
    _ => l10n.celebrationPopupBirthday(c.subjectName),
  };
}
