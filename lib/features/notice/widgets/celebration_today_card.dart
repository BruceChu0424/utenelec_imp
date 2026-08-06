// 今日概览置顶庆典卡片（当前用户本人的今日庆典，常驻动画；当日结束自动消失）。
// 文档：docs/00-项目准则/06-动画规范.md（粒子循环按性能档关闭；控制器随粒子场 dispose）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/effects/celebration_particles.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/performance/performance_tier.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/performance_provider.dart';
import '../models/notice.dart';
import '../providers/notice_providers.dart';
import 'celebration_mascot.dart';

/// 今日概览顶部庆典卡片：仅当当前用户今日有庆典时渲染。
/// 点击跳转对应庆典通知详情（祝福墙）。数据来自 [myCelebrationTodayProvider]，
/// 当天结束接口返回空 → 自然消失。
class CelebrationTodayCard extends ConsumerWidget {
  const CelebrationTodayCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myCelebrationTodayProvider);
    final items = async.valueOrNull;
    // 加载中或无庆典：不占位、不闪（骨架层另有占位）。
    if (items == null || items.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final tier = ref.watch(performanceProvider);
    final c = items.first;
    final accent = c.type.color;

    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: Material(
        color: accent.withValues(alpha: 0.10),
        borderRadius: UtenRadius.xlAll,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: c.noticeId == null
              ? null
              : () => context.push('${RouteName.notice}/${c.noticeId}'),
          child: Stack(
            children: [
              if (!tier.isLite)
                const Positioned.fill(
                  child: CelebrationParticleField(particleCount: 12),
                ),
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Row(
                  children: [
                    CelebrationMascot(type: c.type, size: 64),
                    const SizedBox(width: UtenSpacing.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(c.type.icon, color: accent, size: 18),
                              const SizedBox(width: UtenSpacing.s4),
                              Flexible(
                                child: Text(
                                  _cardLine(l10n, c),
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          if (c.noticeId != null) ...[
                            const SizedBox(height: UtenSpacing.s4),
                            Text(
                              l10n.celebrationCardWall,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: accent,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _cardLine(AppLocalizations l10n, MyCelebrationToday c) => switch (c.type) {
    NoticeType.birthday => l10n.celebrationCardBirthday(c.subjectName),
    NoticeType.anniversary =>
      l10n.celebrationCardAnniversary(c.subjectName, c.eventLabel),
    NoticeType.wedding => l10n.celebrationCardWedding(c.subjectName),
    NoticeType.newborn => l10n.celebrationCardNewborn(c.subjectName),
    _ => l10n.celebrationCardBirthday(c.subjectName),
  };
}
